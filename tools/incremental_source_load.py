"""Checkpoint bounded fixture loads with transactional PostgreSQL chunk receipts."""
import argparse
import json
from pathlib import Path
import re
import secrets
import signal
import sqlite3
import sys

import bounded_source_loader as L

R=L.R
I=L.I
M=L.M
S=L.S
F=L.F
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())
JOURNAL='achillesnext_load_checkpoint'


class Guard(L.Guard):
    def __init__(self,root,seconds=120,stop=None):
        super().__init__([root],seconds,stop=stop);self.root=root
    def check(self,disk=False):
        super().check(disk)
        path=self.root/'STOP'
        if path.exists() or path.is_symlink():M.regular(path,0);raise M.Stopped('operator_stop_file')


def pins():
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA:raise ValueError('Incremental loader changed after import')
    return dict(incremental_loader=SOURCE_SHA,loader=L.pins())


def make_request(directory,registration,plan,complete,schema):
    value=dict(kind='bounded_incremental_load_request',version=1,schema=schema,
        registration_dir=str(Path(directory).resolve()),registration_sha256=registration['registration_sha256'],
        source_binding=I.binding(plan,complete),plan_sha256=plan['plan_sha256'],chunks=complete['chunks'],code=pins(),
        whole_source_loaded=False,full_tier_generated=False,qualifying=False)
    digest=S.BASE.sha(S.BASE.canonical(value))
    return dict(value,request_sha256=digest,marker=F.MARKER+': incremental-selection:'+digest)


def prepare(registration_dir,output,seconds=120,stop=None):
    output=L.output_path(output,registration_dir);guard=L.Guard([output.parent],seconds,stop=stop);guard.check(disk=True)
    registration=R.verify(registration_dir,stop=guard.callback)
    if registration['sample'] is None:raise ValueError('Incremental load requires a verified bounded witness')
    with M.locked(Path(registration['sample']['source_dir'])) as source:
        plan,complete,_=I.verified_source(source,guard)
        if I.binding(plan,complete)!=registration['sample']['source_binding']:raise ValueError('Registered source binding changed')
        request=make_request(registration_dir,registration,plan,complete,'cdm_incremental_'+secrets.token_hex(8))
    guard.check(disk=True);output.mkdir(mode=0o700);M.sync_directory(output.parent)
    with M.open_file(output/'.lock',True):pass
    with M.locked(output):M.atomic_json(output,'request.json',request,exclusive=True)
    return request


def saved_request(root):
    value=M.read_json(root/'request.json')
    if type(value) is not dict:raise ValueError('Invalid incremental request')
    unsigned={k:v for k,v in value.items() if k not in ('request_sha256','marker')}
    digest=S.BASE.sha(S.BASE.canonical(unsigned))
    if (value.get('kind')!='bounded_incremental_load_request' or type(value.get('version')) is not int or value['version']!=1 or
        type(value.get('schema')) is not str or not re.fullmatch('cdm_incremental_[0-9a-f]{16}',value['schema']) or
        value.get('request_sha256')!=digest or value.get('marker')!=F.MARKER+': incremental-selection:'+digest):
        raise ValueError('Invalid incremental request identity')
    return value


def ledger(request):return F.identifier(request['schema'])+'.'+F.identifier(JOURNAL)
def literal_json(value):return F.literal(S.BASE.canonical(value).decode().strip())+'::jsonb'


def transaction_lock(request):
    number=int(request['schema'][-16:],16)
    if number>=2**63:number-=2**64
    return f'SELECT pg_advisory_xact_lock({number});'


def owner_guard(request):
    return ("DO $incremental_owner$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname="+F.literal(request['schema'])+
        " AND nspowner=(SELECT oid FROM pg_roles WHERE rolname=current_user) AND obj_description(oid,'pg_namespace')="+F.literal(request['marker'])+
        ") THEN RAISE EXCEPTION 'Incremental namespace owner/marker differs'; END IF; END; $incremental_owner$;")


def header(request):return dict(kind='bounded_incremental_load_header',request_sha256=request['request_sha256'])


def journal_guard(request):
    table=ledger(request);expected=literal_json(request['chunks']);base=literal_json(header(request))
    return (f'DO $incremental_journal$ DECLARE expected jsonb := {expected}; saved jsonb; n bigint; last_no integer; unique_n bigint; BEGIN '+
        f'SELECT manifest INTO saved FROM {table} WHERE chunk_no=-1; '+
        f"IF (SELECT count(*) FROM {table} WHERE chunk_no<0)<>1 OR saved-'phase' IS DISTINCT FROM {base} OR coalesce(saved->>'phase','') NOT IN ('loading','complete') "+
        "THEN RAISE EXCEPTION 'Incremental header differs'; END IF; "+
        f"IF EXISTS(SELECT 1 FROM {table} WHERE chunk_no>=0 AND manifest IS DISTINCT FROM expected->chunk_no) THEN RAISE EXCEPTION 'Incremental chunk identity differs'; END IF; "+
        f'SELECT count(*),coalesce(max(chunk_no),-1),count(DISTINCT chunk_no) INTO n,last_no,unique_n FROM {table} WHERE chunk_no>=0; '+
        "IF n<>last_no+1 OR n<>unique_n THEN RAISE EXCEPTION 'Incremental journal is not a prefix'; END IF; "+
        "IF saved->>'phase'='complete' AND n<>jsonb_array_length(expected) THEN RAISE EXCEPTION 'Incremental completion has missing chunks'; END IF; END; $incremental_journal$;")


def begin(request):return ['BEGIN;',L.target_guard_sql(),transaction_lock(request),owner_guard(request),f'LOCK TABLE {ledger(request)} IN EXCLUSIVE MODE;',journal_guard(request)]


def state_sql(request):
    table=ledger(request)
    return (f"SELECT json_build_object('phase',(SELECT manifest->>'phase' FROM {table} WHERE chunk_no=-1),"+
        f"'chunks',coalesce((SELECT json_agg(manifest ORDER BY chunk_no) FROM {table} WHERE chunk_no>=0),'[]'::json));")


def initialize_script(request,plan):
    schema=F.identifier(request['schema']);version=plan['source']['parameters']['cdm_version'];ddl=(S.BASE.DDL/(version+'.sql')).read_bytes()
    if S.BASE.sha(ddl)!=plan['source']['pins']['DDL']:raise ValueError('Pinned DDL changed')
    commands=['BEGIN;',L.target_guard_sql(),transaction_lock(request),
        "SELECT (to_regnamespace("+F.literal(request['schema'])+") IS NULL) AS achillesnext_init \\gset",'\\if :achillesnext_init',
        f'CREATE SCHEMA {schema}; REVOKE ALL ON SCHEMA {schema} FROM PUBLIC;',
        f'COMMENT ON SCHEMA {schema} IS {F.literal(request["marker"])};',ddl.decode().replace('@cdmDatabaseSchema',schema),
        f'CREATE TABLE {ledger(request)} (chunk_no integer PRIMARY KEY CHECK(chunk_no>=-1),manifest jsonb NOT NULL);',
        f"INSERT INTO {ledger(request)} VALUES(-1,{literal_json(dict(header(request),phase='loading'))});",'\\endif',
        owner_guard(request),f'LOCK TABLE {ledger(request)} IN EXCLUSIVE MODE;',journal_guard(request),state_sql(request),'COMMIT;']
    return '\n'.join(commands)


def chunk_script(request,plan,frozen,index):
    chunk=request['chunks'][index];schema=F.identifier(request['schema']);table=F.identifier(chunk['table'])
    columns=','.join(F.identifier(c['name']) for c in S.Source(plan['source']['tier'],plan['source']['parameters']['cdm_version']).columns[chunk['table']])
    commands=begin(request)+[
        f'SELECT NOT EXISTS(SELECT 1 FROM {ledger(request)} WHERE chunk_no={index}) AS achillesnext_copy \\gset','\\if :achillesnext_copy',
        f"DO $incremental_order$ BEGIN IF (SELECT count(*) FROM {ledger(request)} WHERE chunk_no>=0)<>{index} THEN RAISE EXCEPTION 'Chunk is not next in prefix'; END IF; END; $incremental_order$;",
        f'CREATE TEMP TABLE achillesnext_chunk (LIKE {schema}.{table}) ON COMMIT DROP;',
        f"\\copy pg_temp.achillesnext_chunk ({columns}) FROM '{frozen/chunk['file']}' WITH (FORMAT csv, HEADER true, NULL '\\N')"]
    commands.extend(L.fact_checks({'achillesnext_chunk':dict(rows=chunk['rows'],nulls=chunk['null_counts'])},'pg_temp'))
    commands.extend([f'INSERT INTO {schema}.{table} ({columns}) SELECT {columns} FROM pg_temp.achillesnext_chunk;',
        f'INSERT INTO {ledger(request)} VALUES({index},{literal_json(chunk)});','\\endif',journal_guard(request),state_sql(request),'COMMIT;'])
    return '\n'.join(commands)


def finish_script(request,plan,complete):
    commands=begin(request)+[f"DO $incremental_finish$ BEGIN IF (SELECT count(*) FROM {ledger(request)} WHERE chunk_no>=0)<>{len(request['chunks'])} THEN RAISE EXCEPTION 'Chunks still missing'; END IF; END; $incremental_finish$;"]
    commands.extend(L.fact_checks(L.facts(plan,complete),request['schema']))
    commands.extend([f"UPDATE {ledger(request)} SET manifest=jsonb_set(manifest,'{{phase}}','\"complete\"'::jsonb) WHERE chunk_no=-1;",
                     F.grants_sql(request['schema']),state_sql(request),'COMMIT;'])
    return '\n'.join(commands)


def execute(client,sql,request):
    value=json.loads(client.run(sql).stdout)
    if (type(value) is not dict or set(value)!={'phase','chunks'} or value['phase'] not in ('loading','complete') or
        type(value['chunks']) is not list or len(value['chunks'])>len(request['chunks']) or
        S.BASE.canonical(value['chunks'])!=S.BASE.canonical(request['chunks'][:len(value['chunks'])]) or
        (value['phase']=='complete' and len(value['chunks'])!=len(request['chunks']))):
        raise ValueError('Database journal snapshot differs from request')
    return value


def run(output,state_dir,seconds=120,max_chunks=M.MAX_CHUNKS,stop=None):
    if type(max_chunks) is not int or not 1<=max_chunks<=M.MAX_CHUNKS:raise ValueError('Use 1..128 chunk transactions per invocation')
    with M.locked(output) as root:
        guard=Guard(root,seconds,stop);client=None;stage='verify';submitted=False
        try:
            guard.check(disk=True)
            if (root/'dropped.json').exists():raise ValueError('Job was cleaned up; prepare a fresh output')
            request=saved_request(root);registration=R.verify(request['registration_dir'],stop=guard.callback)
            L.output_path(root,request['registration_dir'])
            with L.freeze(registration,guard) as (frozen,plan,complete):
                expected=make_request(request['registration_dir'],registration,plan,complete,request['schema'])
                if S.BASE.canonical(expected)!=S.BASE.canonical(request):raise ValueError('Incremental source or code binding changed')
                client=L.Client(state_dir,guard,'achillesnext-incremental-'+request['schema'][-16:]);L.check_target(client)
                if client.value("SELECT has_database_privilege(current_user,current_database(),'TEMP')")!='t':raise ValueError('Fixture owner needs TEMP for bounded staging')
                if (root/'complete.json').exists() and not client.rows('SELECT nspname FROM pg_namespace WHERE nspname='+F.literal(request['schema'])):
                    raise ValueError('Completed schema is missing; prepare a new output')
                stage='initialize';submitted=True;state=execute(client,initialize_script(request,plan),request);transactions=0
                while len(state['chunks'])<len(request['chunks']):
                    guard.check(disk=True)
                    if transactions>=max_chunks:raise M.Stopped('invocation_chunk_limit')
                    stage='chunk';state=execute(client,chunk_script(request,plan,frozen,len(state['chunks'])),request);transactions+=1
                    M.atomic_json(root,'progress.json',dict(request_sha256=request['request_sha256'],committed_chunks=len(state['chunks']),phase=state['phase'],qualifying=False))
                stage='finalize';state=execute(client,finish_script(request,plan,complete),request);guard.check(disk=True)
                if pins()!=request['code']:raise ValueError('Incremental code changed during database work')
                receipt=dict(kind='bounded_incremental_load_complete',version=1,status='complete',request_sha256=request['request_sha256'],
                    schema=request['schema'],registration_sha256=request['registration_sha256'],chunks=len(state['chunks']),rows=complete['rows'],
                    coverage='bounded_selection_only',whole_source_loaded=False,full_tier_generated=False,qualifying=False)
                if (root/'complete.json').exists():
                    if S.BASE.canonical(M.read_json(root/'complete.json'))!=S.BASE.canonical(receipt):raise ValueError('Local completion receipt differs')
                else:M.atomic_json(root,'complete.json',receipt,exclusive=True)
                return receipt
        except (Exception,KeyboardInterrupt) as error:
            M.atomic_json(root,'attempt.json',dict(status='stopped' if isinstance(error,(M.Stopped,KeyboardInterrupt)) else 'failed',stage=stage,
                reason=str(error) or 'KeyboardInterrupt',database_state='inspect_journal' if submitted else 'not_attempted',
                database_error=None if client is None else client.last_error,whole_source_loaded=False,full_tier_generated=False,qualifying=False))
            raise


def drop(output,state_dir,seconds=30,stop=None):
    with M.locked(output) as root:
        request=saved_request(root);guard=L.Guard([root],seconds,stop=stop)
        client=L.Client(state_dir,guard,'achillesnext-incremental-cleanup');L.check_target(client)
        sql='\n'.join(['BEGIN;',L.target_guard_sql(),transaction_lock(request),
            "SELECT (to_regnamespace("+F.literal(request['schema'])+") IS NOT NULL) AS achillesnext_drop \\gset",
            L.drop_guard_sql(request['schema'],request['marker']),'\\if :achillesnext_drop','\\echo dropped','\\else','\\echo absent','\\endif','COMMIT;'])
        status=client.run(sql).stdout.strip()
        if status not in ('dropped','absent'):raise ValueError('Cleanup outcome unavailable; inspect database')
        value=dict(status=status,schema=request['schema'],request_sha256=request['request_sha256'],qualifying=False)
        M.atomic_json(root,'dropped.json',value);return value


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('action',choices=['prepare','run','drop'])
    parser.add_argument('--registration-dir',type=Path);parser.add_argument('--output-dir',type=Path,required=True)
    parser.add_argument('--state-dir',type=Path);parser.add_argument('--seconds',type=float,default=120);parser.add_argument('--max-chunks',type=int,default=M.MAX_CHUNKS)
    args=parser.parse_args()
    if args.action=='prepare' and args.registration_dir is None:parser.error('prepare requires registration-dir')
    if args.action!='prepare' and (args.state_dir is None or args.registration_dir is not None):parser.error('run/drop require state-dir and use the saved registration')
    interrupted=[None]
    def interrupt(signum,frame):interrupted[0]=signal.Signals(signum).name
    old={n:signal.signal(n,interrupt) for n in [signal.SIGINT,signal.SIGTERM]}
    try:
        if args.action=='prepare':result=prepare(args.registration_dir,args.output_dir,args.seconds,lambda:interrupted[0]);status='prepared'
        elif args.action=='run':result=run(args.output_dir,args.state_dir,args.seconds,args.max_chunks,lambda:interrupted[0]);status=result['status']
        else:result=drop(args.output_dir,args.state_dir,args.seconds,lambda:interrupted[0]);status=result['status']
        print(json.dumps(dict(status=status,schema=result['schema'],qualifying=False)));return 0
    except M.Stopped as error:print('Incremental load stopped: '+str(error),file=sys.stderr);return error.code
    except KeyboardInterrupt:print('Incremental load interrupted',file=sys.stderr);return 130
    except (ValueError,OSError,RuntimeError,KeyError,TypeError,sqlite3.Error,L.subprocess.SubprocessError) as error:
        print('Incremental load refused: '+str(error),file=sys.stderr);return 1
    finally:
        for n,handler in old.items():signal.signal(n,handler)


if __name__=='__main__':raise SystemExit(main())
