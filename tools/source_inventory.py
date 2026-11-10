"""Measured, disk-backed inventories of completed bounded source selections."""
import argparse
from collections import Counter
from contextlib import closing, contextmanager
import csv
from decimal import Decimal, InvalidOperation
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import sys
import tempfile
import time

import scale_materialization as M

S = M.SCALE
SOURCE_SHA = S.BASE.sha(Path(__file__).read_bytes())
MAX_DB = 128 * 1024**2
MAX_BINS = 1000000
MAX_ROW = 65536
BUFFER_KEYS = 4096
BUFFER_BYTES = 2 * 1024**2
SCHEMA = {
    'bins': 'CREATE TABLE bins (table_name TEXT NOT NULL, dimension TEXT NOT NULL, value_json TEXT NOT NULL, n INTEGER NOT NULL CHECK(n>=0), PRIMARY KEY(table_name,dimension,value_json)) WITHOUT ROWID',
    'row_bag': 'CREATE TABLE row_bag (table_name TEXT NOT NULL, row_bytes BLOB NOT NULL, n INTEGER NOT NULL CHECK(n>=0), PRIMARY KEY(table_name,row_bytes)) WITHOUT ROWID'}


def limits(database_bytes=MAX_DB, bins=MAX_BINS, seconds=120, min_free=16*1024**2):
    for value,lo,hi in [(database_bytes,65536,MAX_DB),(bins,1,MAX_BINS),(min_free,16*1024**2,1024**3)]:
        if type(value) is not int or not lo <= value <= hi: raise ValueError('Inventory control outside hard bounds')
    if type(seconds) not in (int,float) or not math.isfinite(seconds) or not 1 <= seconds <= 120:
        raise ValueError('Inventory needs a finite 1..120 second budget')
    return dict(database_bytes=database_bytes//4096*4096,bins=bins,seconds=float(seconds),min_free_bytes=min_free)


class Guard:
    def __init__(self, paths, controls, stop=None):
        self.paths, self.controls, self.stop = paths, controls, stop
        self.began=time.monotonic(); self.frames=0; self.failure=None

    def check(self, disk=False):
        if self.failure is not None: raise self.failure
        reason=self.stop() if self.stop else None
        if reason: raise M.Stopped(reason,130 if reason=='SIGINT' else 143)
        if time.monotonic()-self.began > self.controls['seconds']: raise M.Stopped('inventory_deadline')
        if disk:
            for path in self.paths:
                if shutil.disk_usage(path).free < self.controls['min_free_bytes']:
                    raise ValueError('Inventory free-space floor reached')

    def emit(self):
        self.check(disk=self.frames%64==0); self.frames+=1

    def progress(self):
        # SQLite replaces callback exceptions with OperationalError. Preserve
        # the original stop/deadline cause and its exit code for the caller.
        try: self.check()
        except (M.Stopped,ValueError) as error:
            self.failure=error; return 1
        return 0


@contextmanager
def guarded_sql(guard):
    try: yield
    except sqlite3.Error:
        guard.check()
        raise


def binding(plan, complete):
    if S.BASE.sha(Path(__file__).read_bytes()) != SOURCE_SHA: raise ValueError('Inventory code changed after import')
    return dict(plan_sha256=plan['plan_sha256'],completion_sha256=S.BASE.sha(S.BASE.canonical(complete)),
                materializer_sha256=M.SOURCE_SHA,indexed_generator_sha256=S.SOURCE_SHA,collector_sha256=SOURCE_SHA)


def verified_source(root, guard):
    plan=M.load_plan(root); cp,descriptions,names,source=M.checked_prefix(root,plan,guard)
    if len(cp['committed'])!=len(descriptions) or names & M.SCRATCH or any(n.endswith('.part') for n in names):
        raise ValueError('Inventory requires a completed source selection')
    complete=M.read_json(root/'complete.json')
    if S.BASE.canonical(complete)!=S.BASE.canonical(M.receipt(plan,cp)):
        raise ValueError('Source completion receipt differs')
    return plan,complete,source


def histogram_columns(source, table):
    other={'person_id','concept_id','domain_id','vocabulary_id','concept_class_id','standard_concept',
           'year_of_birth','value_as_number','range_low','range_high','quantity','days_supply','refills','value_as_string'}
    return [c['name'] for c in source.columns[table] if c['name'].endswith(('_concept_id','source_value','_date')) or c['name'] in other]


def tag(row, name):
    if name not in row: return dict(kind='not_in_schema')
    return dict(kind='null') if row[name] is None else dict(kind='value',value=row[name])


def numeric_state(value):
    if value is None: return 'missing'
    try: return 'finite' if Decimal(value).is_finite() else 'non_finite'
    except InvalidOperation: return 'invalid'


def row_keys(source, table, row, raw):
    yield ('row',table,'',raw)
    yield ('bin',table,'encoded_row_bytes',S.BASE.canonical(len(raw)).decode().strip())
    for name in histogram_columns(source,table):
        yield ('bin',table,'column:'+name,S.BASE.canonical(tag(row,name)).decode().strip())
    if table in ('measurement','observation'):
        value=row.get('person_id'); people=source.parameters['people']
        bucket='missing_person' if value is None else 'hot_person' if int(value)<=max(1,people//5) else 'other_person'
        joint=dict(concept=tag(row,table+'_concept_id'),unit=tag(row,'unit_concept_id'),
                   operator=tag(row,'operator_concept_id'),numeric_state=numeric_state(row.get('value_as_number')),
                   person_bucket=bucket)
        yield ('bin',table,'joint:representation',S.BASE.canonical(joint).decode().strip())


def scan(root, plan, complete, source, guard):
    selected={w['table'] for w in plan['windows']}
    stats={table:dict(logical_rows=source.counts[table],coverage='not_selected',selected_rows=0,csv_bytes=0,
                      row_bytes_min=None,row_bytes_max=None,null_counts=None) for table in source.columns}
    for table in selected:
        stats[table]['coverage']='selected_windows'
        stats[table]['null_counts']={c['name']:0 for c in source.columns[table]}
    def rows():
        for chunk in complete['chunks']:
            table=chunk['table']; columns=[c['name'] for c in source.columns[table]]
            count=0; size=0; lo=None; hi=None; nulls={name:0 for name in columns}; digest=hashlib.sha256()
            # checked_prefix already verified that all CSV hard links are internal.
            path=root/chunk['file']; M.regular(path,S.MAX_BYTES,(1,2))
            with M.open_file(path) as stream:
                header=stream.readline(MAX_ROW+1)
                if header!=(','.join(columns)+'\n').encode(): raise ValueError('Inventory CSV header mismatch')
                size+=len(header); digest.update(header)
                while True:
                    guard.emit(); raw=stream.readline(MAX_ROW+1)
                    if not raw: break
                    if len(raw)>MAX_ROW or count>=chunk['rows']: raise ValueError('Inventory CSV row budget exceeded')
                    values=next(csv.reader([raw.decode('utf-8')],strict=True))
                    if len(values)!=len(columns): raise ValueError('Inventory CSV column count mismatch')
                    row={name:None if value=='\\N' else value for name,value in zip(columns,values)}
                    for name in columns:
                        if row[name] is None: nulls[name]+=1
                    count+=1; size+=len(raw); digest.update(raw)
                    lo=len(raw) if lo is None else min(lo,len(raw)); hi=max(hi or 0,len(raw))
                    if size>chunk['bytes']: raise ValueError('Inventory CSV grew while reading')
                    yield table,row,raw
            if (count!=chunk['rows'] or size!=chunk['bytes'] or digest.hexdigest()!=chunk['sha256'] or
                    nulls!=chunk['null_counts'] or lo!=chunk['row_bytes_min'] or (hi or 0)!=chunk['row_bytes_max']):
                raise ValueError('Independent CSV facts differ from source checkpoint')
            info=stats[table]; info['selected_rows']+=count; info['csv_bytes']+=size
            if lo is not None: info['row_bytes_min']=lo if info['row_bytes_min'] is None else min(info['row_bytes_min'],lo)
            if hi is not None: info['row_bytes_max']=hi if info['row_bytes_max'] is None else max(info['row_bytes_max'],hi)
            for name in nulls: info['null_counts'][name]+=nulls[name]
        for table in selected:
            if stats[table]['selected_rows']==source.counts[table]: stats[table]['coverage']='full_table'
    return stats,rows()


class Buffer:
    def __init__(self, apply):
        self.apply=apply; self.counts=Counter(); self.bytes=0
        self.peak_keys=0; self.peak_key_bytes=0; self.flushes=0

    def add(self, key):
        raw=key[3]; length=len(raw.encode('utf-8')) if isinstance(raw,str) else len(raw)
        if length>MAX_ROW or (key[0]=='bin' and length>4096): raise ValueError('Inventory key byte budget exceeded')
        if key not in self.counts:
            cost=length+len(key[1])+len(key[2])+8
            if len(self.counts)>=BUFFER_KEYS or self.bytes+cost>BUFFER_BYTES: self.flush()
            self.bytes+=cost
        self.counts[key]+=1
        self.peak_keys=max(self.peak_keys,len(self.counts)); self.peak_key_bytes=max(self.peak_key_bytes,self.bytes)

    def flush(self):
        if self.counts:
            for key,count in self.counts.items(): self.apply(key,count)
            self.flushes+=1; self.counts.clear(); self.bytes=0

    def facts(self):
        return dict(peak_keys=self.peak_keys,peak_key_bytes=self.peak_key_bytes,flushes=self.flushes)


def configure(connection, controls, new=False, shadow=False):
    connection.execute('PRAGMA trusted_schema=OFF'); connection.execute('PRAGMA cache_size=-4096')
    connection.execute('PRAGMA temp_store=MEMORY')
    if new:
        connection.execute('PRAGMA page_size=4096'); connection.execute('PRAGMA journal_mode=DELETE')
        connection.execute('PRAGMA synchronous=FULL'); connection.execute('PRAGMA user_version=1')
        maximum=controls['database_bytes']//4096
        if connection.execute('PRAGMA max_page_count='+str(maximum)).fetchone()[0]!=maximum:
            raise ValueError('SQLite page ceiling was not applied')
        for statement in SCHEMA.values(): connection.execute(statement)
    elif shadow:
        connection.execute('PRAGMA journal_mode=OFF'); connection.execute('PRAGMA synchronous=OFF')
    else: connection.execute('PRAGMA query_only=ON')


def schema_check(connection):
    actual=dict(connection.execute("SELECT name,sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' LIMIT 3"))
    if actual!=SCHEMA or connection.execute('PRAGMA user_version').fetchone()[0]!=1:
        raise ValueError('Inventory SQLite schema differs')
    for table in SCHEMA:
        if connection.execute('SELECT 1 FROM '+table+" WHERE typeof(n)!='integer' OR n<=0 LIMIT 1").fetchone():
            raise ValueError('Invalid inventory count')


class Sink:
    def __init__(self, connection, controls, guard, inverse=False):
        self.connection,self.controls,self.guard,self.inverse=connection,controls,guard,inverse
        self.used=0; self.steps=0

    def apply(self, key, count):
        self.steps+=1
        if self.steps%128==0: self.guard.check(disk=True)
        kind,table,dimension,value=key
        target='row_bag' if kind=='row' else 'bins'
        where='table_name=? AND row_bytes=?' if kind=='row' else 'table_name=? AND dimension=? AND value_json=?'
        args=(table,value) if kind=='row' else (table,dimension,value)
        if self.inverse:
            changed=self.connection.execute('UPDATE '+target+' SET n=n-? WHERE '+where+' AND n>=?',(count,*args,count)).rowcount
            if changed!=1: raise ValueError('Inventory bin/count differs from replayed source')
            return
        if self.used>=self.controls['bins'] and not self.connection.execute('SELECT 1 FROM '+target+' WHERE '+where,args).fetchone():
            raise ValueError('Inventory bin budget exceeded')
        marks=','.join('?' for _ in args)
        self.used+=self.connection.execute('INSERT OR IGNORE INTO '+target+' VALUES('+marks+',0)',args).rowcount
        self.connection.execute('UPDATE '+target+' SET n=n+? WHERE '+where,(count,*args))


def derive(connection, stats, source):
    counts={table:(unique,rows) for table,unique,rows in connection.execute('SELECT table_name,count(*),sum(n) FROM row_bag GROUP BY table_name')}
    histograms={}
    for table,dimension,bins,observations in connection.execute('SELECT table_name,dimension,count(*),sum(n) FROM bins GROUP BY table_name,dimension'):
        histograms.setdefault(table,{})[dimension]=dict(bins=bins,observations=observations)
    for table,info in stats.items():
        if info['coverage']=='not_selected':
            info.update(distinct_rows=None,duplicate_rows=None,histograms=None)
        else:
            unique,rows=counts.get(table,(0,0))
            if rows!=info['selected_rows']: raise ValueError('Row bag does not conserve selected rows')
            info.update(distinct_rows=unique,duplicate_rows=rows-unique,histograms=histograms.get(table,{}),
                        histogram_columns=histogram_columns(source,table))
    return stats


def stream_counts(root, plan, complete, source, guard, sink):
    stats,rows=scan(root,plan,complete,source,guard); buffer=Buffer(sink.apply)
    for table,row,raw in rows:
        for key in row_keys(source,table,row,raw): buffer.add(key)
    buffer.flush()
    return stats,buffer.facts()


def hash_file(path, maximum, guard):
    M.regular(path,maximum); digest=hashlib.sha256(); size=0
    with M.open_file(path) as stream:
        while True:
            guard.check(); raw=stream.read(min(65536,maximum-size+1))
            if not raw: break
            size+=len(raw)
            if size>maximum: raise ValueError('Inventory file byte budget exceeded')
            digest.update(raw)
    return dict(bytes=size,sha256=digest.hexdigest())


def output_path(root, output):
    output=Path(output)
    if output.is_symlink(): raise ValueError('Inventory output must not be a symlink')
    output=S.outside(output).resolve()
    if output.is_relative_to(root) or root.is_relative_to(output):
        raise ValueError('Keep inventory output separate from source materialization')
    return output


def collect(root, output, stop=None, **options):
    controls=limits(**options); output=output_path(Path(root).resolve(),output)
    guard=Guard([output.parent],controls,stop); connection=None; created=False
    with M.locked(root) as root:
        try:
            plan,complete,source=verified_source(root,guard); identity=binding(plan,complete); guard.check(disk=True)
            output.mkdir(mode=0o700); created=True
            db=output/'inventory.sqlite'
            with M.open_file(db,True): pass
            connection=sqlite3.connect(db,isolation_level=None)
            configure(connection,controls,new=True)
            connection.set_progress_handler(guard.progress,1000)
            connection.execute('BEGIN')
            sink=Sink(connection,controls,guard); stats,buffer=stream_counts(root,plan,complete,source,guard,sink)
            stats=derive(connection,stats,source); schema_check(connection)
            if sink.used>controls['bins']: raise ValueError('Inventory bin budget exceeded')
            if binding(M.load_plan(root),M.read_json(root/'complete.json'))!=identity:
                raise ValueError('Source identity changed during inventory')
            guard.check(); connection.execute('COMMIT'); connection.close(); connection=None
            with M.open_file(db) as stream: os.fsync(stream.fileno())
            physical=hash_file(db,controls['database_bytes'],guard)
            record=dict(kind='bounded_source_inventory',version=1,status='complete',binding=identity,limits=controls,
                        selected_rows=complete['rows'],source_csv_bytes=complete['csv_bytes'],tables=stats,
                        database=physical,bins=sink.used,collector_buffer=buffer,sqlite_version=sqlite3.sqlite_version,
                        full_tier_generated=False,qualifying=False)
            guard.check(); M.atomic_json(output,'inventory.json',record,exclusive=True)
            return record
        except (Exception,KeyboardInterrupt) as error:
            error=guard.failure or error
            if connection is not None:
                connection.set_progress_handler(None,0); connection.close()
            if created:
                M.atomic_json(output,'failed.json',dict(status='failed',reason=str(error) or 'KeyboardInterrupt',
                                                       full_tier_generated=False,qualifying=False))
            raise error


def verify(root, output, stop=None):
    output=output_path(Path(root).resolve(),output)
    with os.scandir(output) as entries:
        names=[]
        for entry in entries:
            names.append(entry.name)
            if len(names)>2: break
    if set(names)!={'inventory.json','inventory.sqlite'} or len(names)!=2:
        raise ValueError('Inventory is incomplete or contains unexpected files')
    record=M.read_json(output/'inventory.json'); controls=limits(**dict(database_bytes=record['limits']['database_bytes'],
        bins=record['limits']['bins'],seconds=record['limits']['seconds'],min_free=record['limits']['min_free_bytes']))
    guard=Guard([output],controls,stop)
    with M.locked(root) as root,guarded_sql(guard):
        plan,complete,source=verified_source(root,guard)
        identity=binding(plan,complete)
        if S.BASE.canonical(record['binding'])!=S.BASE.canonical(identity): raise ValueError('Inventory source/code binding differs')
        db=output/'inventory.sqlite'
        if hash_file(db,controls['database_bytes'],guard)!=record['database']: raise ValueError('Inventory database hash differs')
        with closing(sqlite3.connect(db.as_uri()+'?mode=ro',uri=True)) as original:
            configure(original,controls); original.set_progress_handler(guard.progress,1000); schema_check(original)
            bins=sum(original.execute('SELECT count(*) FROM '+table).fetchone()[0] for table in SCHEMA)
            if bins>controls['bins']: raise ValueError('Inventory bin budget exceeded')
            with tempfile.TemporaryDirectory(prefix='achillesnext-inventory-') as folder:
                temp=Path(folder); guard.paths.append(temp); guard.check(disk=True); shadow=temp/'replay.sqlite'
                with M.open_file(db) as reader,M.open_file(shadow,True) as writer:
                    remaining=record['database']['bytes']
                    while remaining:
                        guard.check(disk=True); raw=reader.read(min(65536,remaining))
                        if not raw: raise ValueError('Inventory database shrank during replay copy')
                        writer.write(raw); remaining-=len(raw)
                    if reader.read(1): raise ValueError('Inventory database grew during replay copy')
                with closing(sqlite3.connect(shadow,isolation_level=None)) as replay:
                    configure(replay,controls,shadow=True); replay.set_progress_handler(guard.progress,1000)
                    replay.execute('BEGIN'); sink=Sink(replay,controls,guard,inverse=True)
                    stats,buffer=stream_counts(root,plan,complete,source,guard,sink)
                    for table in SCHEMA:
                        if replay.execute('SELECT 1 FROM '+table+' WHERE n!=0 LIMIT 1').fetchone():
                            raise ValueError('Inventory contains bins not explained by source')
                    replay.execute('ROLLBACK')
                guard.paths.remove(temp)
            stats=derive(original,stats,source)
        if hash_file(db,controls['database_bytes'],guard)!=record['database'] or binding(M.load_plan(root),M.read_json(root/'complete.json'))!=identity:
            raise ValueError('Inventory/source changed during verification')
        guard.check(disk=True)
        expected=dict(kind='bounded_source_inventory',version=1,status='complete',binding=binding(plan,complete),limits=controls,
                      selected_rows=complete['rows'],source_csv_bytes=complete['csv_bytes'],tables=stats,database=record['database'],
                      bins=bins,collector_buffer=buffer,sqlite_version=record['sqlite_version'],full_tier_generated=False,qualifying=False)
        if S.BASE.canonical(expected)!=S.BASE.canonical(record): raise ValueError('Inventory summary differs from replay')
        return record


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['collect','verify']); parser.add_argument('--source-dir',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True); parser.add_argument('--database-bytes',type=int)
    parser.add_argument('--bins',type=int); parser.add_argument('--seconds',type=float)
    parser.add_argument('--min-free-bytes',type=int)
    args=parser.parse_args(); interrupted=[None]; old={}
    options={name:value for name,value in dict(database_bytes=args.database_bytes,bins=args.bins,
              seconds=args.seconds,min_free=args.min_free_bytes).items() if value is not None}
    if args.action=='verify' and options: parser.error('verify uses the limits recorded by collect')
    def interrupt(signum,frame): interrupted[0]=signal.Signals(signum).name
    try:
        for signum in [signal.SIGINT,signal.SIGTERM]: old[signum]=signal.signal(signum,interrupt)
        if args.action=='collect':
            record=collect(args.source_dir,args.output_dir,lambda:interrupted[0],**options)
        else: record=verify(args.source_dir,args.output_dir,lambda:interrupted[0])
        print(args.action+' complete: '+str(record['selected_rows'])+' selected rows; qualifying=false'); return 0
    except M.Stopped as error:
        print(str(error),file=sys.stderr); return error.code
    except (ValueError,OSError,KeyError,TypeError,sqlite3.Error,UnicodeError) as error:
        print('Inventory refused: '+str(error),file=sys.stderr); return 1
    finally:
        for signum,handler in old.items(): signal.signal(signum,handler)


if __name__=='__main__': raise SystemExit(main())
