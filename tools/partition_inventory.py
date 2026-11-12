"""Transactionally reduce verified partition inventories without retaining CSVs.

This is an accumulating development inventory, not execution admission or a
whole-source audit. It never generates a partition or connects to PostgreSQL.
"""
import argparse
from contextlib import closing,contextmanager
import json
import os
from pathlib import Path
import re
import signal
import shutil
import sqlite3
import sys
import tempfile

import source_partition_plan as P

R=P.R
I=R.I
M=P.M
S=P.S
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())
MAX_DB=512*1024**3
META='achillesnext_inventory_meta'
PARTS='achillesnext_inventory_partition'
SCHEMA=dict(I.SCHEMA,**{
    META:f'CREATE TABLE {META} (id INTEGER PRIMARY KEY CHECK(id=1), document TEXT NOT NULL CHECK(length(CAST(document AS BLOB))<=1048576))',
    PARTS:f'CREATE TABLE {PARTS} (partition_no INTEGER PRIMARY KEY CHECK(partition_no>=0), document TEXT NOT NULL CHECK(length(CAST(document AS BLOB))<=1048576))'})


def controls(database_bytes=I.MAX_DB,bins=I.MAX_BINS,seconds=120,min_free=64*1024**2):
    base=I.limits(seconds=seconds,min_free=min_free)
    if type(database_bytes) is not int or not 65536<=database_bytes<=MAX_DB:raise ValueError('Reducer database budget outside 64 KiB..512 GiB')
    if type(bins) is not int or not 1<=bins<=2**31-1:raise ValueError('Reducer key budget outside 1..2147483647')
    return dict(base,database_bytes=database_bytes//4096*4096,bins=bins)


class Guard(I.Guard):
    def __init__(self,root,settings,stop=None):super().__init__([root],settings,stop);self.root=root
    def check(self,disk=False):
        super().check(disk)
        path=self.root/'STOP'
        if path.exists() or path.is_symlink():M.regular(path,0);raise M.Stopped('operator_stop_file')
    def callback(self):self.check();return None


def pins():
    for module in [P,R,I,M,S]:
        if S.BASE.sha(Path(module.__file__).read_bytes())!=module.SOURCE_SHA:raise ValueError('Reducer dependency changed after import')
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA:raise ValueError('Reducer changed after import')
    return dict(reducer=SOURCE_SHA,planner=P.SOURCE_SHA,registration=R.SOURCE_SHA,inventory=I.SOURCE_SHA,materializer=M.SOURCE_SHA,generator=S.SOURCE_SHA)


def request(schedule,plan,settings):
    body=dict(kind='partition_inventory_reduction',version=1,schedule_dir=str(Path(schedule).resolve()),
              partition_plan_sha256=plan['partition_plan_sha256'],limits=settings,code=pins(),
              whole_source_audited=False,full_tier_generated=False,qualifying=False)
    return dict(body,request_sha256=S.BASE.sha(S.BASE.canonical(body)))


def separate(output,plan,paths,stop=None):
    registration=R.verify(plan['registration_dir'],stop=stop)
    output=P.isolated_output(output,plan['registration_dir'],registration)
    for raw in paths:
        path=Path(raw).resolve()
        if output.is_relative_to(path) or path.is_relative_to(output):raise ValueError('Keep reducer separate from schedule/source/inventory')
    return output


def configure(db,settings):
    db.execute('PRAGMA page_size=4096')
    if db.execute('PRAGMA page_size').fetchone()[0]!=4096:raise ValueError('Reducer page size differs')
    db.execute('PRAGMA trusted_schema=OFF');db.execute('PRAGMA cache_size=-4096')
    db.execute('PRAGMA temp_store=FILE');db.execute('PRAGMA journal_mode=DELETE');db.execute('PRAGMA synchronous=FULL')
    ceiling=settings['database_bytes']//4096
    if db.execute('PRAGMA max_page_count='+str(ceiling)).fetchone()[0]!=ceiling:raise ValueError('Reducer page ceiling not applied')


def prepare(schedule,output,stop=None,**options):
    settings=controls(**options);guard=Guard(Path(output),settings,stop);guard.paths=[Path(output).parent];guard.check(disk=True)
    plan=P.verify(schedule,stop=guard.callback);output=separate(output,plan,[schedule],guard.callback);value=request(schedule,plan,settings)
    output.mkdir(mode=0o700);M.sync_directory(output.parent)
    with M.open_file(output/'.lock',True):pass
    with M.locked(output) as root:
        M.atomic_json(root,'request.json',value,exclusive=True)
        with M.open_file(root/'inventory.sqlite',True):pass
        with closing(sqlite3.connect(root/'inventory.sqlite',isolation_level=None)) as db:
            configure(db,settings);db.execute('PRAGMA user_version=1');db.execute('BEGIN IMMEDIATE')
            for sql in SCHEMA.values():db.execute(sql)
            state=dict(request_sha256=value['request_sha256'],partitions=0,rows=0,csv_bytes=0,bins=0,row_keys=0,tables={})
            db.execute('INSERT INTO '+META+' VALUES(1,?)',(S.BASE.canonical(state).decode(),));db.execute('COMMIT')
    return value


def load(root,seconds,stop):
    saved=M.read_json(root/'request.json')
    if type(saved) is not dict:raise ValueError('Invalid reducer request')
    c=saved['limits'];settings=controls(c['database_bytes'],c['bins'],c['seconds'],c['min_free_bytes'])
    live=controls(c['database_bytes'],c['bins'],seconds,c['min_free_bytes']);guard=Guard(root,live,stop);guard.check(disk=True)
    plan=P.verify(saved['schedule_dir'],stop=guard.callback)
    if S.BASE.canonical(saved)!=S.BASE.canonical(request(saved['schedule_dir'],plan,settings)):raise ValueError('Reducer request/source/code differs')
    separate(root,plan,[saved['schedule_dir']],guard.callback)
    allowed={'.lock','request.json','inventory.sqlite','inventory.sqlite-journal','progress.json','attempt.json','STOP','progress.json.next','attempt.json.next'}
    with os.scandir(root) as entries:
        for entry in entries:
            if entry.name not in allowed:raise ValueError('Unexpected reducer artifact')
            # Rollback journals include page numbers/checksums and repeated
            # spill headers; allow that overhead when recovering near the cap.
            limit=2*c['database_bytes']+65536 if entry.name=='inventory.sqlite-journal' else c['database_bytes'] if entry.name=='inventory.sqlite' else 0 if entry.name in ('.lock','STOP') else M.JSON_BYTES
            M.regular(root/entry.name,limit)
    return saved,plan,guard


@contextmanager
def connection(root,req,guard):
    # mode=rw refuses missing databases. Opening may recover a retained hot
    # rollback journal; the operation lock excludes cooperating writers.
    db=sqlite3.connect((root/'inventory.sqlite').as_uri()+'?mode=rw',uri=True,isolation_level=None,timeout=1)
    try:
        configure(db,req['limits']);db.set_progress_handler(guard.progress,1000)
        actual=dict(db.execute("SELECT name,sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' LIMIT 5"))
        if actual!=SCHEMA or db.execute('PRAGMA user_version').fetchone()[0]!=1:raise ValueError('Reducer SQLite schema differs')
        with I.guarded_sql(guard):yield db
    finally:db.set_progress_handler(None,0);db.close()


def state(db,req,plan):
    rows=db.execute('SELECT id,document FROM '+META+' LIMIT 2').fetchall()
    if len(rows)!=1 or rows[0][0]!=1:raise ValueError('Reducer header missing')
    value=json.loads(rows[0][1]);keys={'request_sha256','partitions','rows','csv_bytes','bins','row_keys','tables'}
    if (type(value) is not dict or set(value)!=keys or value['request_sha256']!=req['request_sha256'] or
        any(type(value[k]) is not int or value[k]<0 for k in keys-{'request_sha256','tables'}) or
        value['partitions']>plan['partition_count'] or value['rows']>plan['total_rows'] or
        value['bins']>req['limits']['bins'] or value['row_keys']>min(value['bins'],value['rows']) or type(value['tables']) is not dict or
        not set(value['tables'])<=set(plan['source']['table_rows'])):raise ValueError('Invalid reducer header')
    source=S.Source(plan['source']['tier'],plan['source']['parameters']['cdm_version'])
    total=dict(partitions=0,rows=0,csv_bytes=0,bins=0,row_keys=0)
    table_parts={t['table']:t['partitions'] for t in plan['tables']}
    for table,info in value['tables'].items():
        fields={'logical_rows','selected_rows','partitions','csv_bytes','row_bytes_min','row_bytes_max','null_counts','distinct_rows','duplicate_rows','histograms'}
        if type(info) is not dict or set(info)!=fields:raise ValueError('Invalid reducer table summary')
        for key in fields-{'row_bytes_min','row_bytes_max','null_counts','histograms'}:
            if type(info[key]) is not int or info[key]<0:raise ValueError('Invalid reducer table count')
        n=info['selected_rows'];distinct=info['distinct_rows']
        if (info['logical_rows']!=source.counts[table] or n>info['logical_rows'] or distinct>n or
            info['duplicate_rows']!=n-distinct or not 1<=info['partitions']<=table_parts[table]):raise ValueError('Reducer table counts do not conserve rows')
        nulls=info['null_counts'];names={c['name'] for c in source.columns[table]}
        if type(nulls) is not dict or set(nulls)!=names or any(type(v) is not int or not 0<=v<=n for v in nulls.values()):raise ValueError('Invalid reducer null counts')
        lo,hi=info['row_bytes_min'],info['row_bytes_max']
        if (n==0 and (lo is not None or hi is not None)) or (n>0 and (type(lo) is not int or type(hi) is not int or not 1<=lo<=hi<=I.MAX_ROW)):
            raise ValueError('Invalid reducer row widths')
        hist=info['histograms'];dimensions={'encoded_row_bytes'}|{'column:'+c for c in I.histogram_columns(source,table)}
        if table in ('measurement','observation'):dimensions.add('joint:representation')
        if type(hist) is not dict or set(hist)!=(dimensions if n else set()):raise ValueError('Invalid reducer histogram dimensions')
        hist_bins=0
        for counts in hist.values():
            if (type(counts) is not dict or set(counts)!={'bins','observations'} or type(counts['bins']) is not int or
                not 1<=counts['bins']<=n or type(counts['observations']) is not int or counts['observations']!=n):raise ValueError('Invalid reducer histogram counts')
            hist_bins+=counts['bins']
        total['partitions']+=info['partitions'];total['rows']+=n;total['csv_bytes']+=info['csv_bytes'];total['row_keys']+=distinct;total['bins']+=distinct+hist_bins
    if any(value[k]!=v for k,v in total.items()):raise ValueError('Reducer summary totals differ')
    return value


def progress(req,plan,value):
    return dict(kind='partition_inventory_progress',request_sha256=req['request_sha256'],status='accumulating',
        committed_partitions=value['partitions'],scheduled_partitions=plan['partition_count'],selected_rows=value['rows'],
        source_csv_bytes=value['csv_bytes'],keys=value['bins'],distinct_rows=value['row_keys'],tables=value['tables'],
        all_scheduled_partitions_accumulated=value['partitions']==plan['partition_count'],
        whole_source_audited=False,full_tier_generated=False,qualifying=False)


def checked_receipt(raw,req,index,expected):
    value=json.loads(raw);fields={'request_sha256','partition','materialization_plan_sha256','inventory_sha256','source_binding','selected_rows','source_csv_bytes'}
    if (type(value) is not dict or set(value)!=fields or value['request_sha256']!=req['request_sha256'] or
        type(value['partition']) is not int or value['partition']!=index or value['materialization_plan_sha256']!=expected['plan_sha256'] or
        type(value['selected_rows']) is not int or value['selected_rows']!=expected['windows'][0]['rows'] or
        type(value['source_csv_bytes']) is not int or not 1<=value['source_csv_bytes']<=M.MAX_BYTES or
        type(value['inventory_sha256']) is not str or not re.fullmatch('[0-9a-f]{64}',value['inventory_sha256'])):
        raise ValueError('Committed partition identity differs')
    identity=value['source_binding'];pins=dict(plan_sha256=expected['plan_sha256'],materializer_sha256=M.SOURCE_SHA,indexed_generator_sha256=S.SOURCE_SHA,collector_sha256=I.SOURCE_SHA)
    if (type(identity) is not dict or set(identity)!=set(pins)|{'completion_sha256'} or
        any(identity[k]!=v for k,v in pins.items()) or type(identity['completion_sha256']) is not str or
        not re.fullmatch('[0-9a-f]{64}',identity['completion_sha256'])):raise ValueError('Committed partition binding differs')
    return value


def status(output,seconds=120,stop=None):
    with M.locked(output) as root:
        req,plan,guard=load(root,seconds,stop)
        with connection(root,req,guard) as db:return progress(req,plan,state(db,req,plan))


@contextmanager
def snapshot(source,inventory,expected,guard):
    record=I.verify(source,inventory,stop=guard.callback)
    with M.locked(source) as source:
        plan,complete,_=I.verified_source(source,guard)
        if S.BASE.canonical(plan)!=S.BASE.canonical(expected) or record['binding']!=I.binding(plan,complete):raise ValueError('Inventory does not match scheduled partition')
        with tempfile.TemporaryDirectory(prefix='achillesnext-reduction-') as temporary:
            folder=Path(temporary);guard.paths.append(folder)
            try:
                guard.check(disk=True)
                if shutil.disk_usage(folder).free<record['database']['bytes']+guard.controls['min_free_bytes']:raise ValueError('Reducer snapshot space insufficient')
                frozen=folder/'inventory.sqlite';size=0
                M.regular(Path(inventory)/'inventory.sqlite',I.MAX_DB)
                with M.open_file(Path(inventory)/'inventory.sqlite') as reader,M.open_file(frozen,True) as writer:
                    while True:
                        guard.check(disk=True);raw=reader.read(min(65536,record['database']['bytes']-size+1))
                        if not raw:break
                        size+=len(raw)
                        if size>record['database']['bytes']:raise ValueError('Inventory grew during snapshot')
                        writer.write(raw)
                if I.hash_file(frozen,I.MAX_DB,guard)!=record['database']:raise ValueError('Inventory snapshot differs from verified input')
                with closing(sqlite3.connect(frozen.as_uri()+'?mode=ro&immutable=1',uri=True)) as db:
                    I.configure(db,record['limits']);db.set_progress_handler(guard.progress,1000)
                    I.schema_check(db);yield record,db
            finally:guard.paths.remove(folder)


class Sink(I.Sink):
    def __init__(self,db,settings,guard,value,table,info):
        super().__init__(db,settings,guard);self.used=value['bins'];self.value=value;self.table=table;self.info=info
    def apply(self,key,n):
        if key[1]!=self.table or type(n) is not int or n<=0:raise ValueError('Unexpected input inventory key/count')
        before=self.used;super().apply(key,n);added=self.used-before
        if key[0]=='row':self.value['row_keys']+=added;self.info['distinct_rows']+=added
        else:
            hist=self.info['histograms'].setdefault(key[2],dict(bins=0,observations=0))
            hist['bins']+=added;hist['observations']+=n


def merge(db,original,req,plan,value,index,record,expected,guard):
    table=expected['windows'][0]['table'];incoming=record['tables'][table]
    info=value['tables'].setdefault(table,dict(logical_rows=plan['source']['table_rows'][table],selected_rows=0,
        partitions=0,csv_bytes=0,row_bytes_min=None,row_bytes_max=None,null_counts={c:0 for c in incoming['null_counts']},distinct_rows=0,duplicate_rows=0,histograms={}))
    sink=Sink(db,req['limits'],guard,value,table,info)
    for t,raw,n in original.execute('SELECT table_name,row_bytes,n FROM row_bag'):sink.apply(('row',t,'',raw),n)
    for t,dimension,raw,n in original.execute('SELECT table_name,dimension,value_json,n FROM bins'):sink.apply(('bin',t,dimension,raw),n)
    info['selected_rows']+=incoming['selected_rows'];info['csv_bytes']+=incoming['csv_bytes'];info['partitions']+=1
    for column,n in incoming['null_counts'].items():info['null_counts'][column]+=n
    for name,op in [('row_bytes_min',min),('row_bytes_max',max)]:
        if incoming[name] is not None:info[name]=incoming[name] if info[name] is None else op(info[name],incoming[name])
    info['duplicate_rows']=info['selected_rows']-info['distinct_rows']
    value['partitions']+=1;value['rows']+=record['selected_rows'];value['csv_bytes']+=record['source_csv_bytes'];value['bins']=sink.used
    receipt=dict(request_sha256=req['request_sha256'],partition=index,materialization_plan_sha256=expected['plan_sha256'],
        inventory_sha256=S.BASE.sha(S.BASE.canonical(record)),source_binding=record['binding'],selected_rows=record['selected_rows'],source_csv_bytes=record['source_csv_bytes'])
    db.execute('INSERT INTO '+PARTS+' VALUES(?,?)',(index,S.BASE.canonical(receipt).decode()))
    db.execute('UPDATE '+META+' SET document=? WHERE id=1',(S.BASE.canonical(value).decode(),))
    return receipt


def append(output,index,source,inventory,seconds=120,stop=None):
    with M.locked(output) as root:
        attempted=False
        try:
            req,plan,guard=load(root,seconds,stop);expected=P.materialization_plan(plan,index)
            separate(root,plan,[req['schedule_dir'],source,inventory],guard.callback)
            with connection(root,req,guard) as db:
                value=state(db,req,plan);saved=db.execute('SELECT document FROM '+PARTS+' WHERE partition_no=?',(index,)).fetchone()
                if saved:
                    receipt=checked_receipt(saved[0],req,index,expected)
                    reused=True
                else:
                    with snapshot(source,inventory,expected,guard) as (record,original):
                        guard.check(disk=True);attempted=True;db.execute('BEGIN IMMEDIATE')
                        receipt=merge(db,original,req,plan,value,index,record,expected,guard)
                        if req['code']!=pins():raise ValueError('Reducer code changed during merge')
                        guard.check(disk=True);db.execute('COMMIT')
                    reused=False
                current=progress(req,plan,value);guard.check(disk=True)
                M.atomic_json(root,'progress.json',current)
                return dict(status='already_committed' if reused else 'committed',partition=receipt,progress=current)
        except (Exception,KeyboardInterrupt) as error:
            M.atomic_json(root,'attempt.json',dict(status='stopped' if isinstance(error,(M.Stopped,KeyboardInterrupt)) else 'failed',
                reason=str(error) or 'KeyboardInterrupt',database_state='inspect_partition_journal' if attempted else 'not_attempted',qualifying=False))
            raise


def main():
    parser=argparse.ArgumentParser(description=__doc__);commands=parser.add_subparsers(dest='action',required=True)
    create=commands.add_parser('prepare');create.add_argument('--schedule-dir',type=Path,required=True)
    create.add_argument('--database-bytes',type=int,default=I.MAX_DB);create.add_argument('--bins',type=int,default=I.MAX_BINS)
    add=commands.add_parser('append');add.add_argument('--partition',type=int,required=True)
    add.add_argument('--source-dir',type=Path,required=True);add.add_argument('--inventory-dir',type=Path,required=True)
    for command in [create,add,commands.add_parser('status')]:
        command.add_argument('--output-dir',type=Path,required=True);command.add_argument('--seconds',type=float,default=120)
    args=parser.parse_args();interrupted=[None]
    def interrupt(signum,frame):interrupted[0]=signal.Signals(signum).name
    previous={n:signal.signal(n,interrupt) for n in [signal.SIGINT,signal.SIGTERM]}
    try:
        if args.action=='prepare':result=prepare(args.schedule_dir,args.output_dir,stop=lambda:interrupted[0],database_bytes=args.database_bytes,bins=args.bins,seconds=args.seconds)
        elif args.action=='append':result=append(args.output_dir,args.partition,args.source_dir,args.inventory_dir,args.seconds,lambda:interrupted[0])
        else:result=status(args.output_dir,args.seconds,lambda:interrupted[0])
        print(json.dumps(result,sort_keys=True));return 0
    except M.Stopped as error:print('Inventory reduction stopped: '+str(error),file=sys.stderr);return error.code
    except KeyboardInterrupt:print('Inventory reduction interrupted',file=sys.stderr);return 130
    except (ValueError,OSError,KeyError,TypeError,sqlite3.Error) as error:print('Inventory reduction refused: '+str(error),file=sys.stderr);return 1
    finally:
        for n,handler in previous.items():signal.signal(n,handler)


if __name__=='__main__':raise SystemExit(main())
