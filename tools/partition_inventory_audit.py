"""Resume an independent indexed-workload audit of a partition accumulator."""
import argparse
import base64
from contextlib import closing,contextmanager
import csv
from decimal import Decimal,InvalidOperation
import hashlib
import json
import os
from pathlib import Path
import signal
import sqlite3
import sys

import partition_inventory as A

M=A.M
S=A.S
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())
META='achillesnext_audit_state'
SCHEMA={
 'expected_rows':'CREATE TABLE expected_rows (table_name TEXT NOT NULL, row_bytes BLOB NOT NULL, n INTEGER NOT NULL CHECK(n>0), PRIMARY KEY(table_name,row_bytes)) WITHOUT ROWID',
 'expected_bins':'CREATE TABLE expected_bins (table_name TEXT NOT NULL, dimension TEXT NOT NULL, value_json TEXT NOT NULL, n INTEGER NOT NULL CHECK(n>0), PRIMARY KEY(table_name,dimension,value_json)) WITHOUT ROWID',
 META:f'CREATE TABLE {META} (id INTEGER PRIMARY KEY CHECK(id=1), document TEXT NOT NULL CHECK(length(CAST(document AS BLOB))<=1048576))'}
ZERO='0'*64
FILE_CHUNK=8*1024**2
BUFFER_KEYS=2048
BUFFER_BYTES=1024**2


def pins():
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA:raise ValueError('Audit implementation changed after import')
    return dict(auditor=SOURCE_SHA,reducer=A.pins())


def fingerprint(root):
    st=M.regular(root/'inventory.sqlite',A.MAX_DB)
    return dict(device=st.st_dev,inode=st.st_ino,bytes=st.st_size,mtime_ns=st.st_mtime_ns,ctime_ns=st.st_ctime_ns)


class Guard(A.Guard):
    def __init__(self,root,source,settings,stop=None):
        super().__init__(root,settings,stop);self.source=source;self.paths=[root,source]
    def check(self,disk=False):
        super().check(disk)
        path=self.source/'STOP'
        if path.exists() or path.is_symlink():M.regular(path,0);raise M.Stopped('source_stop_file')


def isolated(output,source,plan,stop,schedule_dir):
    output=A.separate(output,plan,[source,schedule_dir],stop)
    return output


def empty(req):
    return dict(request_sha256=req['request_sha256'],phase='generate',last_partition=-1,active=None,
        expected=dict(request_sha256=req['source_request_sha256'],partitions=0,rows=0,csv_bytes=0,bins=0,row_keys=0,tables={}),
        cursor=None,row_keys_compared=0,bin_keys_compared=0,row_chain=ZERO,bin_chain=ZERO,receipt_chain=ZERO,
        file_bytes=0,file_chain=ZERO,receipt=None)


def write_state(db,value):db.execute('UPDATE '+META+' SET document=? WHERE id=1',(S.BASE.canonical(value).decode(),))


def schema_check(db,schema):
    actual=dict(db.execute("SELECT name,sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' LIMIT 5"))
    if actual!=schema or db.execute('PRAGMA user_version').fetchone()[0]!=1:raise ValueError('Audit/source SQLite schema differs')


def read_state(db,req):
    rows=db.execute('SELECT id,document FROM '+META+' LIMIT 2').fetchall()
    if len(rows)!=1 or rows[0][0]!=1:raise ValueError('Audit checkpoint missing')
    value=json.loads(rows[0][1])
    if (type(value) is not dict or set(value)!=set(empty(req)) or value['request_sha256']!=req['request_sha256'] or
        value['phase'] not in ('generate','rows','bins','bytes','finalize','complete') or type(value['last_partition']) is not int or value['last_partition']< -1 or
        type(value['expected']) is not dict or set(value['expected'])!=set(empty(req)['expected']) or
        any(type(value[k]) is not int or value[k]<0 for k in ['row_keys_compared','bin_keys_compared','file_bytes']) or
        value['file_bytes']>req['source_fingerprint']['bytes'] or (value['file_bytes']%FILE_CHUNK and value['file_bytes']!=req['source_fingerprint']['bytes']) or
        any(type(value[k]) is not str or len(value[k])!=64 or any(c not in '0123456789abcdef' for c in value[k]) for k in ['row_chain','bin_chain','receipt_chain','file_chain'])):
        raise ValueError('Invalid audit checkpoint')
    active=value['active']
    if active is not None and (type(active) is not dict or set(active)!={'partition','chunks'} or
        type(active['partition']) is not int or active['partition']<=value['last_partition'] or type(active['chunks']) is not list or len(active['chunks'])>M.MAX_CHUNKS):raise ValueError('Invalid active audit partition')
    cursor=value['cursor']
    if cursor is not None and (type(cursor) is not list or any(type(v) is not str for v in cursor) or
        len(cursor)!=(2 if value['phase']=='rows' else 3 if value['phase']=='bins' else 0)):raise ValueError('Invalid audit comparison cursor')
    if value['phase']!='generate' and active is not None:raise ValueError('Audit comparison has an unfinished partition')
    if (value['phase']=='complete')!=(type(value['receipt']) is dict):raise ValueError('Audit completion checkpoint differs')
    return value


def prepare(source,output,require_whole_source=False,seconds=120,database_bytes=None,bins=None,stop=None):
    if type(require_whole_source) is not bool:raise ValueError('Whole-source scope must be boolean')
    with M.locked(source) as source:
        original,plan,source_guard=A.load(source,seconds,stop)
        output=isolated(output,source,plan,source_guard.callback,schedule_dir=original['schedule_dir'])
        settings=A.controls(database_bytes if database_bytes is not None else original['limits']['database_bytes'],
            bins if bins is not None else original['limits']['bins'],seconds)
        guard=Guard(output,source,settings,stop);guard.began=source_guard.began
        guard.paths=[output.parent,source];guard.check(disk=True)
        # Recovery belongs to the reducer; auditing never writes the source.
        if (source/'inventory.sqlite-journal').exists():raise ValueError('Recover the source journal with reducer status before auditing')
        with closing(sqlite3.connect((source/'inventory.sqlite').as_uri()+'?mode=ro',uri=True)) as db,A.I.guarded_sql(guard):
            db.execute('PRAGMA trusted_schema=OFF');db.execute('PRAGMA query_only=ON');db.execute('PRAGMA cache_size=-4096')
            db.set_progress_handler(guard.progress,1000)
            schema_check(db,A.SCHEMA)
            header=A.state(db,original,plan);header_sha=S.BASE.sha(S.BASE.canonical(header))
        body=dict(kind='partition_inventory_audit_request',version=1,source_dir=str(source),source_request_sha256=original['request_sha256'],
            partition_plan_sha256=plan['partition_plan_sha256'],source_fingerprint=fingerprint(source),source_header_sha256=header_sha,
            scope='whole_source' if require_whole_source else 'selected_partitions',limits=settings,code=pins(),qualifying=False)
        req=dict(body,request_sha256=S.BASE.sha(S.BASE.canonical(body)))
        output.mkdir(mode=0o700);M.sync_directory(output.parent)
        with M.open_file(output/'.lock',True):pass
        with M.locked(output) as root:
            M.atomic_json(root,'request.json',req,exclusive=True)
            with M.open_file(root/'audit.sqlite',True):pass
            with closing(sqlite3.connect(root/'audit.sqlite',isolation_level=None)) as db:
                A.configure(db,settings);db.execute('PRAGMA user_version=1');db.execute('BEGIN IMMEDIATE')
                for sql in SCHEMA.values():db.execute(sql)
                db.execute('INSERT INTO '+META+' VALUES(1,?)',(S.BASE.canonical(empty(req)).decode(),))
                guard.check(disk=True);unchanged(source,req);db.execute('COMMIT')
    return req


def load(root,source,seconds,stop):
    req=M.read_json(root/'request.json')
    if type(req) is not dict:raise ValueError('Invalid audit request')
    raw={k:v for k,v in req.items() if k!='request_sha256'}
    c=req['limits'];settings=A.controls(c['database_bytes'],c['bins'],c['seconds'],c['min_free_bytes'])
    if (req.get('kind')!='partition_inventory_audit_request' or type(req.get('version')) is not int or req['version']!=1 or
        req.get('scope') not in ('selected_partitions','whole_source') or req.get('request_sha256')!=S.BASE.sha(S.BASE.canonical(raw)) or
        req.get('code')!=pins() or req['source_dir']!=str(source) or req['limits']!=settings):raise ValueError('Audit request/code identity differs')
    settings=dict(settings,seconds=A.controls(seconds=seconds)['seconds']);guard=Guard(root,source,settings,stop);guard.check(disk=True)
    original,plan,_=A.load(source,seconds,guard.callback);isolated(root,source,plan,guard.callback,schedule_dir=original['schedule_dir'])
    if original['request_sha256']!=req['source_request_sha256'] or plan['partition_plan_sha256']!=req['partition_plan_sha256']:raise ValueError('Audit source request changed')
    unchanged(source,req)
    allowed={'.lock','request.json','audit.sqlite','audit.sqlite-journal','progress.json','complete.json','attempt.json','STOP',
        'progress.json.next','complete.json.next','attempt.json.next'}
    linked={}
    with os.scandir(root) as entries:
        for entry in entries:
            if entry.name not in allowed:raise ValueError('Unexpected audit artifact')
            maximum=2*c['database_bytes']+65536 if entry.name=='audit.sqlite-journal' else c['database_bytes'] if entry.name=='audit.sqlite' else 0 if entry.name in ('.lock','STOP') else M.JSON_BYTES
            completion=entry.name in ('complete.json','complete.json.next')
            st=M.regular(root/entry.name,maximum,(1,2) if completion else (1,))
            if completion and st.st_nlink==2:linked[entry.name]=(st.st_dev,st.st_ino)
    if linked:
        if set(linked)!={'complete.json','complete.json.next'} or len(set(linked.values()))!=1:raise ValueError('External audit completion hard link')
        # Exclusive atomic_json can die between linking its published name and
        # unlinking this internal scratch name. Keep the published bytes intact.
        (root/'complete.json.next').unlink();M.sync_directory(root)
    return req,original,plan,guard


def unchanged(source,req):
    if (source/'inventory.sqlite-journal').exists() or fingerprint(source)!=req['source_fingerprint']:raise ValueError('Source inventory changed or has a pending journal; prepare a new audit')


@contextmanager
def databases(root,source,req,guard):
    with closing(sqlite3.connect((source/'inventory.sqlite').as_uri()+'?mode=ro',uri=True)) as original,closing(sqlite3.connect((root/'audit.sqlite').as_uri()+'?mode=rw',uri=True,isolation_level=None,timeout=1)) as expected:
        original.execute('PRAGMA trusted_schema=OFF');original.execute('PRAGMA query_only=ON');original.execute('PRAGMA cache_size=-4096')
        A.configure(expected,req['limits'])
        for db,schema in [(original,A.SCHEMA),(expected,SCHEMA)]:
            db.set_progress_handler(guard.progress,1000)
            with A.I.guarded_sql(guard):schema_check(db,schema)
        header=original.execute('SELECT document FROM '+A.META+' WHERE id=1').fetchone()
        if header is None or S.BASE.sha(S.BASE.canonical(json.loads(header[0])))!=req['source_header_sha256']:raise ValueError('Source header differs from audit binding')
        with A.I.guarded_sql(guard):yield original,expected,json.loads(header[0])


def encoded(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False)
def chain(previous,value):return hashlib.sha256(bytes.fromhex(previous)+S.BASE.canonical(value)).hexdigest()


class Writer:
    """Independent CSV decoder/histogram oracle; no collector key or sink calls."""
    EXTRA={'person_id','concept_id','domain_id','vocabulary_id','concept_class_id','standard_concept','year_of_birth',
        'value_as_number','range_low','range_high','quantity','days_supply','refills','value_as_string'}
    def __init__(self,db,value,source,table,settings,guard):
        self.db,self.value,self.source,self.table,self.settings,self.guard=db,value,source,table,settings,guard
        self.columns=[c['name'] for c in source.columns[table]];self.first=True;self.pending={};self.pending_bytes=0
        self.info=value['expected']['tables'].setdefault(table,dict(logical_rows=source.counts[table],selected_rows=0,partitions=0,csv_bytes=0,
            row_bytes_min=None,row_bytes_max=None,null_counts={c:0 for c in self.columns},distinct_rows=0,duplicate_rows=0,histograms={}))
    def add(self,table,columns,key,count=1):
        self.guard.emit()
        marks=','.join('?' for _ in key);where=' AND '.join(c+'=?' for c in columns)
        new=self.db.execute('INSERT OR IGNORE INTO '+table+' VALUES('+marks+',?)',(*key,count)).rowcount
        if not new:self.db.execute('UPDATE '+table+' SET n=n+? WHERE '+where,(count,*key))
        if new:
            self.value['expected']['bins']+=1
            if self.value['expected']['bins']>self.settings['bins']:raise ValueError('Audit expected-key budget exceeded')
        return new
    def observe(self,key):
        if key not in self.pending:
            cost=sum(len(k) if type(k) is bytes else len(k.encode()) for k in key)+16
            if len(self.pending)>=BUFFER_KEYS or self.pending_bytes+cost>BUFFER_BYTES:self.flush()
            self.pending_bytes+=cost
        self.pending[key]=self.pending.get(key,0)+1
    def flush(self):
        for key,n in self.pending.items():
            if key[0]=='row':
                added=self.add('expected_rows',['table_name','row_bytes'],(self.table,key[1]),n)
                self.info['distinct_rows']+=added;self.value['expected']['row_keys']+=added
            else:
                added=self.add('expected_bins',['table_name','dimension','value_json'],(self.table,key[1],key[2]),n)
                self.info['histograms'][key[1]]['bins']+=added
        self.info['duplicate_rows']=self.info['selected_rows']-self.info['distinct_rows']
        self.pending.clear();self.pending_bytes=0
    def write(self,raw):
        self.guard.check()
        if self.first:
            if raw!=(','.join(self.columns)+'\n').encode():raise ValueError('Unexpected regenerated header')
            self.first=False;return len(raw)
        if len(raw)>65536:raise ValueError('Regenerated row exceeds audit width budget')
        values=next(csv.reader([raw.decode('utf-8')],strict=True))
        if len(values)!=len(self.columns):raise ValueError('Regenerated CSV width differs')
        row={k:None if v=='\\N' else v for k,v in zip(self.columns,values)};info=self.info
        self.observe(('row',raw))
        info['selected_rows']+=1;self.value['expected']['rows']+=1
        for name,v in row.items():info['null_counts'][name]+=v is None
        info['row_bytes_min']=len(raw) if info['row_bytes_min'] is None else min(info['row_bytes_min'],len(raw))
        info['row_bytes_max']=max(info['row_bytes_max'] or 0,len(raw))
        def tag(name):return {'kind':'not_in_schema'} if name not in row else {'kind':'null'} if row[name] is None else {'kind':'value','value':row[name]}
        keys=[('encoded_row_bytes',encoded(len(raw)))]+[('column:'+name,encoded(tag(name))) for name in self.columns if name.endswith(('_concept_id','source_value','_date')) or name in self.EXTRA]
        if self.table in ('measurement','observation'):
            number=row.get('value_as_number')
            try:numeric='missing' if number is None else 'finite' if Decimal(number).is_finite() else 'non_finite'
            except InvalidOperation:numeric='invalid'
            person=row.get('person_id');bucket='missing_person' if person is None else 'hot_person' if int(person)<=max(1,self.source.parameters['people']//5) else 'other_person'
            keys.append(('joint:representation',encoded(dict(concept=tag(self.table+'_concept_id'),unit=tag('unit_concept_id'),operator=tag('operator_concept_id'),numeric_state=numeric,person_bucket=bucket))))
        for dimension,key in keys:
            counts=info['histograms'].setdefault(dimension,dict(bins=0,observations=0));counts['observations']+=1
            self.observe(('bin',dimension,key))
        return len(raw)


def generate(original,db,req,plan,value,guard):
    active=value['active']
    if active is None:
        row=original.execute('SELECT partition_no,document FROM '+A.PARTS+' WHERE partition_no>? ORDER BY partition_no LIMIT 1',(value['last_partition'],)).fetchone()
        if row is None:
            if req['scope']=='whole_source' and value['expected']['partitions']!=plan['partition_count']:raise ValueError('Whole-source audit has missing partitions')
            value['phase']='rows';return
        index,raw=row
        if req['scope']=='whole_source' and index!=value['last_partition']+1:raise ValueError('Whole-source audit has a partition gap')
        active=value['active']=dict(partition=index,chunks=[])
    index=active['partition'];materialization=A.P.materialization_plan(plan,index)
    raw=original.execute('SELECT document FROM '+A.PARTS+' WHERE partition_no=?',(index,)).fetchone()
    if raw is None:raise ValueError('Audit partition receipt disappeared')
    receipt=A.checked_receipt(raw[0],dict(request_sha256=req['source_request_sha256']),index,materialization)
    descriptions=M.layout(materialization);ordinal=len(active['chunks'])
    if ordinal>=len(descriptions):raise ValueError('Audit chunk checkpoint outside partition')
    desc=descriptions[ordinal];source=S.Source(plan['source']['tier'],plan['source']['parameters']['cdm_version'])
    writer=Writer(db,value,source,desc['table'],req['limits'],guard)
    rendered=S.render(source,desc['table'],desc['start'],desc['rows'],writer)
    writer.flush()
    active['chunks'].append(dict(desc,**{k:rendered[k] for k in ['bytes','sha256','row_bytes_min','row_bytes_max','null_counts']}))
    writer.info['csv_bytes']+=rendered['bytes'];value['expected']['csv_bytes']+=rendered['bytes']
    if len(active['chunks'])==len(descriptions):
        complete=M.receipt(materialization,M.checkpoint(materialization,active['chunks']))
        if S.BASE.sha(S.BASE.canonical(complete))!=receipt['source_binding']['completion_sha256'] or complete['csv_bytes']!=receipt['source_csv_bytes']:raise ValueError('Regenerated partition completion differs')
        writer.info['partitions']+=1;value['expected']['partitions']+=1;value['last_partition']=index;value['active']=None
        value['receipt_chain']=chain(value['receipt_chain'],[index,receipt])


def scan(db,table,kind,cursor,limit):
    if kind=='rows':
        fields="CASE WHEN typeof(table_name)='text' AND length(table_name)<=128 THEN table_name ELSE NULL END,CASE WHEN typeof(row_bytes)='blob' AND length(row_bytes)<=65536 THEN row_bytes ELSE NULL END,n"
        columns='table_name,row_bytes';where='' if cursor is None else ' WHERE (table_name,row_bytes)>(?,?)'
        args=[] if cursor is None else [cursor[0],base64.b64decode(cursor[1],validate=True)]
    else:
        fields="CASE WHEN typeof(table_name)='text' AND length(table_name)<=128 THEN table_name ELSE NULL END,CASE WHEN typeof(dimension)='text' AND length(dimension)<=256 THEN dimension ELSE NULL END,CASE WHEN typeof(value_json)='text' AND length(CAST(value_json AS BLOB))<=4096 THEN value_json ELSE NULL END,n"
        columns='table_name,dimension,value_json';where='' if cursor is None else ' WHERE (table_name,dimension,value_json)>(?,?,?)';args=cursor or []
    return iter(db.execute('SELECT '+fields+' FROM '+table+where+' ORDER BY '+columns+' LIMIT ?',(*args,limit)))


def compare(original,db,value,keys,guard):
    kind=value['phase'];actual=scan(original,'row_bag' if kind=='rows' else 'bins',kind,value['cursor'],keys)
    expected=scan(db,'expected_rows' if kind=='rows' else 'expected_bins',kind,value['cursor'],keys);size=0
    for _ in range(keys):
        guard.emit();a=next(actual,None);e=next(expected,None)
        if a is None and e is None:value['phase']='bins' if kind=='rows' else 'bytes';value['cursor']=None;return
        if (a!=e or a is None or type(a[-1]) is not int or a[-1]<=0 or
            any(type(k) is not str for k in a[:-2]) or a[-2] is None or (kind=='rows' and type(a[-2]) is not bytes)):
            raise ValueError('Global '+kind+' inventory differs from independently regenerated source')
        if kind=='rows':
            cursor=[a[0],base64.b64encode(a[1]).decode()];payload=[a[0],cursor[1],a[2]];size+=len(a[1]);value['row_keys_compared']+=1;value['row_chain']=chain(value['row_chain'],payload)
        else:
            cursor=list(a[:3]);size+=len(a[2].encode());value['bin_keys_compared']+=1;value['bin_chain']=chain(value['bin_chain'],list(a))
        value['cursor']=cursor
        if size>=2*1024**2:return


def file_step(source,req,value,guard):
    offset=value['file_bytes'];remaining=min(FILE_CHUNK,req['source_fingerprint']['bytes']-offset)
    if remaining==0:value['phase']='finalize';return
    digest=hashlib.sha256();count=0
    with M.open_file(source/'inventory.sqlite') as stream:
        stream.seek(offset)
        while count<remaining:
            guard.emit();raw=stream.read(min(65536,remaining-count))
            if not raw:raise ValueError('Source inventory truncated during byte audit')
            count+=len(raw);digest.update(raw)
    value['file_chain']=chain(value['file_chain'],dict(offset=offset,bytes=count,sha256=digest.hexdigest()))
    value['file_bytes']+=count


def finish(req,plan,value,header):
    if S.BASE.canonical(value['expected'])!=S.BASE.canonical(header):raise ValueError('Global cached summary/journal differs from regenerated source')
    if value['row_keys_compared']!=header['row_keys'] or value['bin_keys_compared']!=header['bins']-header['row_keys']:raise ValueError('Audit comparisons do not conserve global keys')
    if value['file_bytes']!=req['source_fingerprint']['bytes']:raise ValueError('Source byte audit is incomplete')
    whole=value['expected']['partitions']==plan['partition_count']
    if req['scope']=='whole_source' and not whole:raise ValueError('Whole-source audit coverage incomplete')
    if whole and any(value['expected']['tables'].get(t,{}).get('selected_rows')!=n for t,n in plan['source']['table_rows'].items()):raise ValueError('Whole-source table coverage differs')
    value['receipt']=dict(kind='partition_inventory_audit_complete',version=1,status='complete',request_sha256=req['request_sha256'],
        scope=req['scope'],source_request_sha256=req['source_request_sha256'],source_fingerprint=req['source_fingerprint'],
        source_header_sha256=req['source_header_sha256'],partition_plan_sha256=req['partition_plan_sha256'],partitions=header['partitions'],
        rows=header['rows'],row_keys=header['row_keys'],histogram_keys=header['bins']-header['row_keys'],digest_algorithm='ordered-sha256-chain-v1',
        row_chain=value['row_chain'],bin_chain=value['bin_chain'],receipt_chain=value['receipt_chain'],
        source_file_digest_algorithm='sha256-chain-8MiB-v1',source_file_chain=value['file_chain'],source_file_bytes=value['file_bytes'],
        whole_source_audited=whole,full_tier_generated=False,qualifying=False)
    value['phase']='complete'


def run(output,seconds=120,max_steps=32,page_keys=256,stop=None,verify_only=False):
    if type(max_steps) is not int or not 1<=max_steps<=128 or type(page_keys) is not int or not 1<=page_keys<=1024 or type(verify_only) is not bool:raise ValueError('Use 1..128 steps and 1..1024 comparison keys')
    initial=M.read_json(Path(output)/'request.json')
    if type(initial) is not dict:raise ValueError('Invalid audit request')
    with M.locked(Path(initial['source_dir'])) as source,M.locked(output) as root:
        attempted=False
        try:
            req,_,plan,guard=load(root,source,seconds,stop)
            with databases(root,source,req,guard) as (original,db,header):
                value=read_state(db,req)
                if value['phase']=='complete':
                    saved=value['receipt'];finish(req,plan,value,header)
                    if S.BASE.canonical(saved)!=S.BASE.canonical(value['receipt']):raise ValueError('Audit completion checkpoint differs')
                if verify_only:
                    if value['phase']!='complete':raise ValueError('Audit is not complete')
                    if S.BASE.canonical(M.read_json(root/'complete.json'))!=S.BASE.canonical(value['receipt']):raise ValueError('Audit completion file differs')
                    unchanged(source,req);guard.check();return value['receipt']
                for _ in range(max_steps):
                    if value['phase']=='complete':break
                    guard.check(disk=True);unchanged(source,req);attempted=True;db.execute('BEGIN IMMEDIATE')
                    if value['phase']=='generate':generate(original,db,req,plan,value,guard)
                    elif value['phase'] in ('rows','bins'):compare(original,db,value,page_keys,guard)
                    elif value['phase']=='bytes':file_step(source,req,value,guard)
                    elif value['phase']=='finalize':finish(req,plan,value,header)
                    else:raise ValueError('Invalid audit phase')
                    guard.check(disk=True);unchanged(source,req)
                    if pins()!=req['code']:raise ValueError('Audit code changed during work')
                    write_state(db,value);db.execute('COMMIT')
                unchanged(source,req);guard.check(disk=True)
                result=dict(status=value['phase'],partitions_regenerated=value['expected']['partitions'],rows_regenerated=value['expected']['rows'],
                    row_keys_compared=value['row_keys_compared'],histogram_keys_compared=value['bin_keys_compared'],source_bytes_verified=value['file_bytes'],qualifying=False)
                if value['phase']=='complete':
                    if (root/'complete.json').exists():
                        if S.BASE.canonical(M.read_json(root/'complete.json'))!=S.BASE.canonical(value['receipt']):raise ValueError('Audit completion file differs')
                    else:M.atomic_json(root,'complete.json',value['receipt'],exclusive=True)
                    result['receipt']=value['receipt']
                M.atomic_json(root,'progress.json',result);return result
        except (Exception,KeyboardInterrupt) as error:
            M.atomic_json(root,'attempt.json',dict(status='stopped' if isinstance(error,(M.Stopped,KeyboardInterrupt)) else 'failed',reason=str(error) or 'KeyboardInterrupt',
                database_state='inspect_audit_checkpoint' if attempted else 'not_attempted',qualifying=False));raise


def main():
    parser=argparse.ArgumentParser(description=__doc__);commands=parser.add_subparsers(dest='action',required=True)
    create=commands.add_parser('prepare');create.add_argument('--source-dir',type=Path,required=True);create.add_argument('--require-whole-source',action='store_true')
    create.add_argument('--database-bytes',type=int);create.add_argument('--bins',type=int)
    execute=commands.add_parser('run');execute.add_argument('--max-steps',type=int,default=32);execute.add_argument('--page-keys',type=int,default=256)
    for command in [create,execute,commands.add_parser('verify')]:command.add_argument('--output-dir',type=Path,required=True);command.add_argument('--seconds',type=float,default=120)
    args=parser.parse_args();interrupted=[None]
    def interrupt(signum,frame):interrupted[0]=signal.Signals(signum).name
    previous={n:signal.signal(n,interrupt) for n in [signal.SIGINT,signal.SIGTERM]}
    try:
        if args.action=='prepare':result=prepare(args.source_dir,args.output_dir,args.require_whole_source,args.seconds,args.database_bytes,args.bins,lambda:interrupted[0])
        elif args.action=='run':result=run(args.output_dir,args.seconds,args.max_steps,args.page_keys,lambda:interrupted[0])
        else:result=run(args.output_dir,args.seconds,stop=lambda:interrupted[0],verify_only=True)
        print(json.dumps(result,sort_keys=True));return 0 if args.action=='prepare' or result['status']=='complete' else 3
    except M.Stopped as error:print('Inventory audit stopped: '+str(error),file=sys.stderr);return error.code
    except KeyboardInterrupt:print('Inventory audit interrupted',file=sys.stderr);return 130
    except (ValueError,OSError,KeyError,TypeError,sqlite3.Error) as error:print('Inventory audit refused: '+str(error),file=sys.stderr);return 1
    finally:
        for n,handler in previous.items():signal.signal(n,handler)


if __name__=='__main__':raise SystemExit(main())
