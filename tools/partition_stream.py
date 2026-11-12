"""Stream a selected schedule into one private fixture candidate and audit it.

Only the current bounded partition's CSV/inventory files are retained. This local
development path does not admit full-source S1/S2 or publish analytical results.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import sqlite3
import sys

import partition_inventory_audit as V
import bounded_source_loader as L

A=V.A
P=A.P
R=P.R
I=A.I
M=A.M
S=A.S
F=L.F
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())
HEADER='achillesnext_stream_state'
PARTS='achillesnext_stream_partition'


def pins():
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA:raise ValueError('Stream implementation changed after import')
    return dict(stream=SOURCE_SHA,auditor=V.pins(),loader=L.pins())


class Guard(L.Guard):
    def __init__(self,root,seconds=120,stop=None):
        super().__init__([root],seconds,stop=stop);self.root=root
    def check(self,disk=False):
        super().check(disk)
        path=self.root/'STOP'
        if path.exists() or path.is_symlink():M.regular(path,0);raise M.Stopped('operator_stop_file')


def request(schedule,plan,first,count,settings,schema):
    if (type(first) is not int or type(count) is not int or first<0 or count<1 or first+count>plan['partition_count']):
        raise ValueError('Choose a positive contiguous range within the schedule')
    if count==plan['partition_count']:raise ValueError('Whole-source execution needs resource admission; development selections only')
    if type(schema) is not str or not re.fullmatch('cdm_stream_[0-9a-f]{16}',schema):raise ValueError('Invalid stream schema')
    body=dict(kind='selected_partition_stream',version=1,schedule_dir=str(Path(schedule).resolve()),
        partition_plan_sha256=plan['partition_plan_sha256'],first=first,count=count,schema=schema,
        limits=settings,code=pins(),whole_source_loaded=False,full_tier_generated=False,qualifying=False)
    digest=S.BASE.sha(S.BASE.canonical(body))
    return dict(body,request_sha256=digest,marker=F.MARKER+': partition-stream:'+digest)


def saved_request(root):
    req=M.read_json(root/'request.json')
    if type(req) is not dict:raise ValueError('Invalid stream request')
    body={k:v for k,v in req.items() if k not in ('request_sha256','marker')}
    digest=S.BASE.sha(S.BASE.canonical(body))
    if (req.get('kind')!='selected_partition_stream' or type(req.get('version')) is not int or req['version']!=1 or
        type(req.get('schema')) is not str or not re.fullmatch('cdm_stream_[0-9a-f]{16}',req['schema']) or
        req.get('request_sha256')!=digest or req.get('marker')!=F.MARKER+': partition-stream:'+digest):raise ValueError('Invalid stream request identity')
    return req


def prepare(schedule,output,first,count,seconds=120,database_bytes=I.MAX_DB,bins=I.MAX_BINS,stop=None):
    guard=Guard(Path(output),seconds,stop);guard.paths=[Path(output).parent];guard.check(disk=True)
    plan=P.verify(schedule,stop=guard.callback);output=A.separate(output,plan,[schedule],guard.callback)
    req=request(schedule,plan,first,count,A.controls(database_bytes,bins), 'cdm_stream_'+secrets.token_hex(8))
    output.mkdir(mode=0o700);M.sync_directory(output.parent)
    with M.open_file(output/'.lock',True):pass
    M.atomic_json(output,'request.json',req,exclusive=True)
    return req


def prune(path,guard):
    """Delete only a bounded, nonsymlink owned work tree; restart after partial removal."""
    if path.is_symlink():raise ValueError('Stream work directory must not be a symlink')
    if not path.exists():return
    files=0
    for root,dirs,names in os.walk(path,followlinks=False):
        guard.check(disk=True)
        for name in dirs:
            if (Path(root)/name).is_symlink():raise ValueError('Symlink in stream work directory')
        files+=len(dirs)+len(names)
        if files>1024:raise ValueError('Stream work file budget exceeded')
        for name in names:M.regular(Path(root)/name,2*I.MAX_DB+65536,(1,2))
    guard.check();shutil.rmtree(path);M.sync_directory(path.parent)


def child(root,name,create,guard):
    """Publish initialized child metadata only after preparation succeeds."""
    target=root/name;pending=root/(name+'.creating')
    if target.is_symlink() or pending.is_symlink():raise ValueError('Symlink stream child')
    if not target.exists():
        prune(pending,guard);guard.check(disk=True);create(pending)
        guard.check();os.rename(pending,target);M.sync_directory(root)
    return target


def table(req,name):return F.identifier(req['schema'])+'.'+F.identifier(name)
def literal(value):return F.literal(S.BASE.canonical(value).decode().strip())+'::jsonb'
def initial(req):return dict(request_sha256=req['request_sha256'],phase='loading',next_partition=req['first'],chain=V.ZERO,audit_sha256=None)


def lock_sql(req):
    number=int(req['schema'][-16:],16)
    if number>=2**63:number-=2**64
    return f'SELECT pg_advisory_xact_lock({number});'


def owner_sql(req):
    return ("DO $stream_owner$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname="+F.literal(req['schema'])+
        " AND nspowner=(SELECT oid FROM pg_roles WHERE rolname=current_user) AND obj_description(oid,'pg_namespace')="+F.literal(req['marker'])+
        ") THEN RAISE EXCEPTION 'Stream namespace owner/marker differs'; END IF; END; $stream_owner$;")


def state_sql(req):return f'SELECT document FROM {table(req,HEADER)} WHERE id=1;'
def begin(req):return ['BEGIN;',L.target_guard_sql(),lock_sql(req),owner_sql(req),f'LOCK TABLE {table(req,HEADER)} IN EXCLUSIVE MODE;']


def execute(client,sql,req):
    state=json.loads(client.run(sql).stdout)
    if (type(state) is not dict or set(state)!=set(initial(req)) or state['request_sha256']!=req['request_sha256'] or
        state['phase'] not in ('loading','complete') or type(state['next_partition']) is not int or
        not req['first']<=state['next_partition']<=req['first']+req['count'] or type(state['chain']) is not str or
        not re.fullmatch('[0-9a-f]{64}',state['chain']) or
        (state['phase']=='loading' and state['audit_sha256'] is not None) or
        (state['phase']=='complete' and (state['next_partition']!=req['first']+req['count'] or
            type(state['audit_sha256']) is not str or not re.fullmatch('[0-9a-f]{64}',state['audit_sha256'])))):
        raise ValueError('Stream database checkpoint differs')
    return state


def initialize_script(req,plan):
    schema=F.identifier(req['schema']);ddl=(S.BASE.DDL/(plan['source']['parameters']['cdm_version']+'.sql')).read_bytes()
    if S.BASE.sha(ddl)!=plan['source']['pins']['DDL']:raise ValueError('Pinned DDL changed')
    return '\n'.join(['BEGIN;',L.target_guard_sql(),lock_sql(req),
        "SELECT (to_regnamespace("+F.literal(req['schema'])+") IS NULL) AS stream_create \\gset",'\\if :stream_create',
        f'CREATE SCHEMA {schema}; REVOKE ALL ON SCHEMA {schema} FROM PUBLIC;',f'COMMENT ON SCHEMA {schema} IS {F.literal(req["marker"])};',
        ddl.decode().replace('@cdmDatabaseSchema',schema),
        f'CREATE TABLE {table(req,HEADER)} (id integer PRIMARY KEY CHECK(id=1),document jsonb NOT NULL);',
        f'CREATE TABLE {table(req,PARTS)} (partition_no integer PRIMARY KEY,manifest jsonb NOT NULL);',
        f'INSERT INTO {table(req,HEADER)} VALUES(1,{literal(initial(req))});','\\endif',owner_sql(req),state_sql(req),'COMMIT;'])


def partition_script(req,plan,complete,frozen,index,manifest,state):
    commands=begin(req)+[f'DO $stream_prefix$ BEGIN IF (SELECT document FROM {table(req,HEADER)} WHERE id=1) IS DISTINCT FROM {literal(state)} THEN RAISE EXCEPTION \'Stream prefix changed\'; END IF; END; $stream_prefix$;']
    source=S.Source(plan['source']['tier'],plan['source']['parameters']['cdm_version']);name=plan['windows'][0]['table']
    columns=','.join(F.identifier(c['name']) for c in source.columns[name]);target=table(req,name)
    commands.append(f'CREATE TEMP TABLE achillesnext_stream_chunk (LIKE {target}) ON COMMIT DROP;')
    for chunk in complete['chunks']:
        commands.append(f"\\copy pg_temp.achillesnext_stream_chunk ({columns}) FROM '{frozen/chunk['file']}' WITH (FORMAT csv, HEADER true, NULL '\\N')")
    commands.extend(L.fact_checks({'achillesnext_stream_chunk':L.facts(plan,complete)[name]},'pg_temp'))
    commands.extend([f'INSERT INTO {target} ({columns}) SELECT {columns} FROM pg_temp.achillesnext_stream_chunk;',
        f'INSERT INTO {table(req,PARTS)} VALUES({index},{literal(manifest)});',
        f'UPDATE {table(req,HEADER)} SET document={literal(dict(state,next_partition=index+1,chain=V.chain(state["chain"],[index,manifest])))} WHERE id=1;',
        state_sql(req),'COMMIT;'])
    return '\n'.join(commands)


def reducer_receipt(reduction,req,plan,index,guard):
    with M.locked(reduction) as root:
        original,_,nested=A.load(root,guard.controls['seconds'],guard.callback)
        with A.connection(root,original,nested) as db:
            row=db.execute('SELECT document FROM '+A.PARTS+' WHERE partition_no=?',(index,)).fetchone()
            if row is None:raise ValueError('Missing committed stream inventory partition')
            return A.checked_receipt(row[0],original,index,P.materialization_plan(plan,index))


def source_ready(active,plan,index,guard):
    expected=P.materialization_plan(plan,index);c=plan['controls']
    source=child(active,'source',lambda p:M.prepare(p,plan['source']['tier'],plan['source']['parameters']['cdm_version'],
        expected['windows'],chunk_rows=c['chunk_rows'],byte_limit=c['csv_bytes'],seconds=c['invocation_seconds'],min_free=c['min_free_bytes']),guard)
    if M.load_plan(source)!=expected:raise ValueError('Active stream source differs')
    result=M.run(source,stop=guard.callback)
    if result['status']!='complete':
        if result['status']=='stopped':raise M.Stopped(result['reason'],result['code'])
        raise RuntimeError('Stream generation failed: '+result['reason'])
    inventory=child(active,'inventory',lambda p:I.collect(source,p,stop=guard.callback),guard)
    record=I.verify(source,inventory,stop=guard.callback)
    return source,inventory,record


def journal_step(root,req,audit,state,client,guard,max_steps):
    digest=S.BASE.sha(S.BASE.canonical(audit));path=root/'journal.json'
    value=M.read_json(path) if path.exists() else dict(audit_sha256=digest,next_partition=req['first'],chain=V.ZERO)
    if (type(value) is not dict or set(value)!={'audit_sha256','next_partition','chain'} or value['audit_sha256']!=digest or
        type(value['next_partition']) is not int or not req['first']<=value['next_partition']<=req['first']+req['count'] or
        type(value['chain']) is not str or not re.fullmatch('[0-9a-f]{64}',value['chain'])):raise ValueError('Stream journal validation checkpoint differs')
    for _ in range(max_steps):
        guard.check(disk=True);index=value['next_partition']
        if index==req['first']+req['count']:break
        row=client.rows('SELECT partition_no,manifest FROM '+table(req,PARTS)+' WHERE partition_no='+str(index))
        if len(row)!=1 or row[0]['partition_no']!=index:raise ValueError('Stream database partition journal differs')
        value=dict(value,next_partition=index+1,chain=V.chain(value['chain'],[index,row[0]['manifest']]))
        M.atomic_json(root,'journal.json',value)
    if value['next_partition']!=req['first']+req['count']:return False
    if value['chain']!=audit['receipt_chain'] or state['chain']!=value['chain']:raise ValueError('Stream database journal does not match independently audited inventory')
    return True


def finish_script(req,audit,state,header,plan):
    digest=S.BASE.sha(S.BASE.canonical(audit));end=req['first']+req['count']
    commands=begin(req)+[f'DO $stream_finish$ BEGIN IF (SELECT document FROM {table(req,HEADER)} WHERE id=1) IS DISTINCT FROM {literal(state)} OR (SELECT count(*) FROM {table(req,PARTS)})<>{req["count"]} OR EXISTS(SELECT 1 FROM {table(req,PARTS)} WHERE partition_no<{req["first"]} OR partition_no>={end}) THEN RAISE EXCEPTION \'Stream final journal differs\'; END IF; END; $stream_finish$;']
    columns=S.Source(plan['source']['tier'],plan['source']['parameters']['cdm_version']).columns
    facts={name:dict(rows=header['tables'].get(name,{}).get('selected_rows',0),nulls=header['tables'].get(name,{}).get('null_counts',{c['name']:0 for c in cols})) for name,cols in columns.items()}
    commands.extend(L.fact_checks(facts,req['schema']))
    commands.extend([f'UPDATE {table(req,HEADER)} SET document={literal(dict(state,phase="complete",audit_sha256=digest))} WHERE id=1;',
        F.grants_sql(req['schema']),state_sql(req),'COMMIT;'])
    return '\n'.join(commands)


def run(output,state_dir,seconds=120,max_partitions=1,max_steps=32,stop=None):
    if type(max_partitions) is not int or not 1<=max_partitions<=128 or type(max_steps) is not int or not 1<=max_steps<=128:raise ValueError('Use 1..128 partitions and audit/journal steps per invocation')
    with M.locked(output) as root:
        guard=Guard(root,seconds,stop);client=None;stage='verify'
        try:
            guard.check(disk=True);req=saved_request(root)
            if (root/'dropped.json').exists():raise ValueError('Stream candidate was cleaned up')
            plan=P.verify(req['schedule_dir'],stop=guard.callback);A.separate(root,plan,[req['schedule_dir']],guard.callback)
            c=req['limits'];settings=A.controls(c['database_bytes'],c['bins'],c['seconds'],c['min_free_bytes'])
            if req!=request(req['schedule_dir'],plan,req['first'],req['count'],settings,req['schema']):raise ValueError('Stream request/source/code changed')
            reduction=child(root,'reduction',lambda p:A.prepare(req['schedule_dir'],p,stop=guard.callback,**dict(database_bytes=c['database_bytes'],bins=c['bins'])),guard)
            header=A.status(reduction,stop=guard.callback)
            client=L.Client(state_dir,guard,'achillesnext-stream-'+req['schema'][-16:]);L.check_target(client)
            if client.value("SELECT has_database_privilege(current_user,current_database(),'TEMP')")!='t':raise ValueError('Stream owner needs TEMP')
            if (header['committed_partitions'] or (root/'audit').exists() or (root/'complete.json').exists()) and not client.rows('SELECT nspname FROM pg_namespace WHERE nspname='+F.literal(req['schema'])):
                raise ValueError('Stream candidate schema is missing')
            stage='initialize';state=execute(client,initialize_script(req,plan),req);end=req['first']+req['count'];done=0
            while True:
                guard.check(disk=True);active=root/'active';binding=root/'active.json';index=state['next_partition']
                if binding.exists():
                    saved=M.read_json(binding)
                    if type(saved) is not dict or set(saved)!={'partition'} or type(saved['partition']) is not int or saved['partition'] not in (index,index-1):raise ValueError('Active stream partition differs')
                    if saved['partition']==index-1:
                        committed=reducer_receipt(reduction,req,plan,index-1,guard)
                        if client.rows('SELECT manifest FROM '+table(req,PARTS)+' WHERE partition_no='+str(index-1))!=[dict(manifest=committed)]:raise ValueError('Committed database/inventory receipt differs')
                        stage='cleanup_partition';prune(active,guard);binding.unlink();M.sync_directory(root)
                elif active.exists() or active.is_symlink():raise ValueError('Unbound stream active directory')
                if index==end:break
                if done>=max_partitions:return dict(status='incomplete',phase='loading',next_partition=index,schema=req['schema'],qualifying=False)
                if not binding.exists():M.atomic_json(root,'active.json',dict(partition=index))
                if active.is_symlink():raise ValueError('Symlink stream active directory')
                if not active.exists():active.mkdir(mode=0o700);M.sync_directory(root)
                stage='source_inventory';source,inventory,record=source_ready(active,plan,index,guard)
                stage='reduce';result=A.append(reduction,index,source,inventory,stop=guard.callback)
                manifest=result['partition']
                if manifest['source_binding']!=record['binding'] or manifest['inventory_sha256']!=S.BASE.sha(S.BASE.canonical(record)):raise ValueError('Active inventory differs from committed receipt')
                stage='copy_partition'
                with L.freeze(dict(sample=dict(source_dir=str(source),source_binding=record['binding'])),guard) as (frozen,unit,complete):
                    state=execute(client,partition_script(req,unit,complete,frozen,index,manifest,state),req)
                done+=1
            stage='audit';A.status(reduction,stop=guard.callback)
            audit_dir=child(root,'audit',lambda p:V.prepare(reduction,p,stop=guard.callback),guard)
            audited=V.run(audit_dir,max_steps=max_steps,stop=guard.callback)
            if audited['status']!='complete':return dict(status='incomplete',phase='audit',schema=req['schema'],qualifying=False)
            audit=audited['receipt'];audit=V.run(audit_dir,verify_only=True,stop=guard.callback)
            if audit['partitions']!=req['count']:raise ValueError('Audited stream partition count differs')
            # Keep the independently audited source stable through the SQL
            # publication transaction, including between resumed journal pages.
            with M.locked(reduction):
                audit_request=M.read_json(audit_dir/'request.json');V.unchanged(reduction,audit_request)
                with closing(sqlite3.connect((reduction/'inventory.sqlite').as_uri()+'?mode=ro',uri=True)) as db:
                    db.execute('PRAGMA query_only=ON');db.execute('PRAGMA cache_size=-4096');db.set_progress_handler(guard.progress,1000)
                    with I.guarded_sql(guard):
                        header=A.state(db,M.read_json(reduction/'request.json'),plan)
                        if S.BASE.sha(S.BASE.canonical(header))!=audit['source_header_sha256']:raise ValueError('Audited stream header changed')
                stage='journal'
                if not journal_step(root,req,audit,state,client,guard,max_steps):return dict(status='incomplete',phase='journal',schema=req['schema'],qualifying=False)
                stage='finalize'
                if state['phase']=='complete' and state['audit_sha256']!=S.BASE.sha(S.BASE.canonical(audit)):raise ValueError('Published stream audit differs')
                if req['code']!=pins():raise ValueError('Stream code changed before finalization')
                V.unchanged(reduction,audit_request)
                state=execute(client,finish_script(req,audit,state,header,plan),req);guard.check(disk=True)
            receipt=dict(kind='selected_partition_stream_complete',version=1,status='complete',request_sha256=req['request_sha256'],
                schema=req['schema'],partitions=req['count'],rows=audit['rows'],audit_sha256=state['audit_sha256'],
                coverage='selected_partitions_only',whole_source_loaded=False,full_tier_generated=False,qualifying=False)
            if (root/'complete.json').exists() and M.read_json(root/'complete.json')!=receipt:raise ValueError('Stream completion receipt differs')
            M.atomic_json(root,'complete.json',receipt);return receipt
        except (Exception,KeyboardInterrupt) as error:
            M.atomic_json(root,'attempt.json',dict(status='stopped' if isinstance(error,(M.Stopped,KeyboardInterrupt)) else 'failed',stage=stage,
                reason=str(error) or 'KeyboardInterrupt',database_state='inspect_stream_journal',database_error=None if client is None else client.last_error,qualifying=False))
            raise


def drop(output,state_dir,seconds=30,stop=None):
    with M.locked(output) as root:
        req=saved_request(root);guard=Guard(root,seconds,stop);guard.check(disk=True)
        client=L.Client(state_dir,guard,'achillesnext-stream-cleanup');L.check_target(client)
        sql='\n'.join(['BEGIN;',L.target_guard_sql(),lock_sql(req),L.drop_guard_sql(req['schema'],req['marker']),'COMMIT;'])
        client.run(sql);value=dict(status='dropped',schema=req['schema'],request_sha256=req['request_sha256'],qualifying=False)
        M.atomic_json(root,'dropped.json',value);return value


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('action',choices=['prepare','run','drop'])
    parser.add_argument('--output-dir',type=Path,required=True);parser.add_argument('--schedule-dir',type=Path);parser.add_argument('--state-dir',type=Path)
    parser.add_argument('--first',type=int);parser.add_argument('--count',type=int);parser.add_argument('--seconds',type=float,default=120)
    parser.add_argument('--database-bytes',type=int,default=I.MAX_DB);parser.add_argument('--bins',type=int,default=I.MAX_BINS)
    parser.add_argument('--max-partitions',type=int,default=1);parser.add_argument('--max-steps',type=int,default=32)
    args=parser.parse_args()
    if args.action=='prepare' and None in (args.schedule_dir,args.first,args.count):parser.error('prepare needs schedule-dir, first and count')
    if args.action!='prepare' and (args.state_dir is None or any(v is not None for v in [args.schedule_dir,args.first,args.count])):parser.error('run/drop need state-dir and use the frozen selection')
    interrupted=[None]
    def interrupt(signum,frame):interrupted[0]=signal.Signals(signum).name
    previous={n:signal.signal(n,interrupt) for n in (signal.SIGINT,signal.SIGTERM)}
    try:
        if args.action=='prepare':value=prepare(args.schedule_dir,args.output_dir,args.first,args.count,args.seconds,args.database_bytes,args.bins,lambda:interrupted[0])
        elif args.action=='run':value=run(args.output_dir,args.state_dir,args.seconds,args.max_partitions,args.max_steps,lambda:interrupted[0])
        else:value=drop(args.output_dir,args.state_dir,args.seconds,lambda:interrupted[0])
        print(json.dumps(value,sort_keys=True));return 3 if value.get('status')=='incomplete' else 0
    except M.Stopped as error:print('Partition stream stopped: '+str(error),file=sys.stderr);return error.code
    except KeyboardInterrupt:print('Partition stream interrupted',file=sys.stderr);return 130
    except (ValueError,OSError,KeyError,TypeError,RuntimeError,sqlite3.Error,L.subprocess.SubprocessError) as error:print('Partition stream refused: '+str(error),file=sys.stderr);return 1
    finally:
        for n,handler in previous.items():signal.signal(n,handler)


if __name__=='__main__':raise SystemExit(main())
