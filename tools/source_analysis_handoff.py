"""Freeze a read-only completed whole-source input for batch analysis tooling.

No execution permission, source mutation or benchmark qualification is granted.
"""
import argparse
from contextlib import closing
import json
import os
import re
from pathlib import Path
import signal
import sqlite3
import sys

import partition_stream as T
from matched_reference_sql import Reference,PROFILE_PATH

M=T.M
S=T.S
F=T.F
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())
REFERENCE_PATH=Path(sys.modules[Reference.__module__].__file__)
REFERENCE_SHA=S.BASE.sha(REFERENCE_PATH.read_bytes())
MAX_REFERENCE=4*1024**2
FIELDS={'kind','version','stream_dir','stream_request_sha256','partition_plan_sha256','audit_sha256','source_schema','source_marker',
    'cdm_version','source_plan','table_rows','columns','database','measurement','profile_sha256','code','consistency','live_checks',
    'analysis_execution_authorized','qualifying','reference_sha256','handoff_sha256','source_id'}


def sql_type(value):
    value=value.lower()
    return re.sub(r'^varchar','character varying',{'timestamp':'timestamp without time zone','int':'integer'}.get(value,value))


def pins():
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA:raise ValueError('Handoff code changed after import')
    if S.BASE.sha(REFERENCE_PATH.read_bytes())!=REFERENCE_SHA:raise ValueError('Reference compiler changed after import')
    return dict(handoff=SOURCE_SHA,stream=T.pins(),reference=REFERENCE_SHA,profile=S.BASE.sha(PROFILE_PATH.read_bytes()))


def completed(root,guard):
    guard.check(disk=True)
    req=T.saved_request(root)
    if req['kind']!='whole_source_partition_stream' or req['version']!=2:raise ValueError('Handoff requires a complete admitted whole-source stream')
    if any((root/name).exists() or (root/name).is_symlink() for name in ('active','active.json','dropped.json')):raise ValueError('Stream is active or dropped')
    plan=T.P.verify(req['schedule_dir'],stop=guard.callback)
    settings=req['limits'];expected=T.request(req['schedule_dir'],plan,req['first'],req['count'],
        T.A.controls(settings['database_bytes'],settings['bins'],settings['seconds'],settings['min_free_bytes']),req['schema'],req['admission'],req['postgres_bytes'],req['postgres_initial_bytes'])
    if req!=expected:raise ValueError('Stream request/source/code changed')
    audit=T.V.run(root/'audit',verify_only=True,stop=guard.callback)
    if audit['scope']!='whole_source' or audit['whole_source_audited'] is not True:raise ValueError('Handoff requires whole-source audit coverage')
    digest=S.BASE.sha(S.BASE.canonical(audit))
    receipt=dict(kind='whole_source_partition_stream_complete',version=2,status='complete',request_sha256=req['request_sha256'],
        schema=req['schema'],partitions=req['count'],rows=audit['rows'],audit_sha256=digest,coverage='whole_source',
        whole_source_loaded=True,full_tier_generated=True,resource_registration_sha256=req['admission']['registration_sha256'],qualifying=False)
    if M.read_json(root/'complete.json')!=receipt:raise ValueError('Stream completion receipt differs')
    resource=T.Z.read_registration(req['admission']['directory'])
    if resource['registration_sha256']!=req['admission']['registration_sha256']:raise ValueError('Frozen resource registration differs')
    return req,plan,audit,receipt,resource['allocation']['database']


def source_snapshot(client,req,plan,audit):
    """One read-only repeatable-read measurement; counts are batch source scans.

    Journal/header and physical structure/count/null checks are bounded metadata,
    not a live cryptographic row-bag audit against a hostile source owner.
    """
    columns=S.Source(plan['source']['tier'],plan['source']['parameters']['cdm_version']).columns
    q=F.literal(req['schema']);tables=[]
    for name,cols in columns.items():
        nulls=','.join(F.literal(c['name'])+',count(*) FILTER(WHERE '+F.identifier(c['name'])+' IS NULL)' for c in cols)
        tables.append('SELECT '+F.literal(name)+' AS name,jsonb_build_object(\'rows\',count(*),\'nulls\',jsonb_build_object('+nulls+')) AS facts FROM '+T.table(req,name))
    catalog="SELECT c.relname AS name,a.attname AS column_name,format_type(a.atttypid,a.atttypmod) AS type,a.attnotnull AS not_null,a.attnum AS ordinal FROM pg_namespace n JOIN pg_class c ON c.relnamespace=n.oid JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped WHERE n.nspname="+q+" AND c.relkind='r' AND c.relname NOT IN ("+F.literal(T.HEADER)+','+F.literal(T.PARTS)+') ORDER BY c.relname,a.attnum'
    relations="SELECT jsonb_object_agg(c.relname,c.relkind::text) FROM pg_namespace n JOIN pg_class c ON c.relnamespace=n.oid WHERE n.nspname="+q+" AND c.relkind IN ('r','p','v','m','f','S')"
    sql='\n'.join(['BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;',T.L.target_guard_sql(),T.lock_sql(req),T.owner_sql(req),
        "SELECT jsonb_build_object('state',("+T.state_sql(req).removesuffix(';')+"),'relations',("+relations+"),'columns',(SELECT jsonb_agg(row_to_json(x)) FROM ("+catalog+") x),'tables',(SELECT jsonb_object_agg(name,facts) FROM ("+' UNION ALL '.join(tables)+") x),'journal_count',(SELECT count(*) FROM "+T.table(req,T.PARTS)+"),'runner_usage',has_schema_privilege("+F.literal(F.RUNNER)+','+q+",'USAGE'),'runner_create',has_schema_privilege("+F.literal(F.RUNNER)+','+q+",'CREATE'),'runner_select',(SELECT bool_and(has_table_privilege("+F.literal(F.RUNNER)+",c.oid,'SELECT')) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname="+q+" AND c.relkind='r'));",'ROLLBACK;'])
    # The advisory lock statement produces an empty psql output line.
    measured=json.loads(client.run(sql).stdout)
    expected_state=dict(T.initial(req),phase='complete',next_partition=req['count'],chain=audit['receipt_chain'],audit_sha256=S.BASE.sha(S.BASE.canonical(audit)))
    if measured['state']!=expected_state or measured['journal_count']!=req['count']:raise ValueError('Completed SQL stream journal/header differs')
    if measured['relations']!={name:'r' for name in [*columns,T.HEADER,T.PARTS]}:raise ValueError('Physical source relation inventory differs')
    expected_columns=[dict(name=t,column_name=c['name'],type=sql_type(c['type']),not_null=c['required'],ordinal=i+1) for t,cols in sorted(columns.items()) for i,c in enumerate(cols)]
    if measured['columns']!=expected_columns:raise ValueError('Physical source columns/types differ')
    with closing(sqlite3.connect((Path(plan['_stream_dir'])/'reduction/inventory.sqlite').as_uri()+'?mode=ro',uri=True)) as db:
        db.execute('PRAGMA query_only=ON');header=json.loads(db.execute('SELECT document FROM '+T.A.META+' WHERE id=1').fetchone()[0])
    expected_tables={name:dict(rows=plan['source']['table_rows'][name],nulls=header['tables'][name]['null_counts']) for name in columns}
    if measured['tables']!=expected_tables:raise ValueError('Live source row/null counts differ from audited input')
    if measured['runner_usage'] is not True or measured['runner_create'] is not False or measured['runner_select'] is not True:raise ValueError('Completed source reader grants differ')
    return measured,columns


def capture(stream,state_dir,seconds=120,stop=None,output=None):
    with M.locked(stream) as root:
        guard=T.Guard(root,seconds,stop);req,plan,audit,receipt,target=completed(root,guard)
        if output is not None:T.A.separate(output,plan,[stream,root/'reduction',root/'audit',state_dir,req['schedule_dir'],req['admission']['directory']],guard.callback)
        client=T.L.Client(state_dir,guard,'achillesnext-source-handoff');T.L.check_target(client)
        actual=T.Z.target_identity(client)
        if {k:v for k,v in actual.items() if k!='initial_database_bytes'}!={k:v for k,v in target.items() if k!='initial_database_bytes'}:raise ValueError('Handoff database identity/settings changed')
        # Audit owns the reducer lock during verification; retain it during SQL
        # capture so the corresponding cached summary cannot change underneath.
        with M.locked(root/'reduction'):
            plan=dict(plan,_stream_dir=str(root.resolve()))
            measured,columns=source_snapshot(client,req,plan,audit)
            T.V.unchanged(root/'reduction',M.read_json(root/'audit/request.json'))
        after=T.Z.target_identity(client)
        if {k:v for k,v in actual.items() if k!='initial_database_bytes'}!={k:v for k,v in after.items() if k!='initial_database_bytes'}:raise ValueError('Database identity changed during handoff capture')
        guard.check(disk=True)
        body=dict(kind='whole_source_analysis_handoff',version=1,stream_dir=str(root.resolve()),stream_request_sha256=req['request_sha256'],
            partition_plan_sha256=plan['partition_plan_sha256'],audit_sha256=receipt['audit_sha256'],source_schema=req['schema'],source_marker=req['marker'],
            cdm_version=plan['source']['parameters']['cdm_version'],source_plan=plan['source'],table_rows=plan['source']['table_rows'],
            columns={t:{c['name']:c['type'] for c in cs} for t,cs in columns.items()},database={k:v for k,v in actual.items() if k!='initial_database_bytes'},
            measurement=measured,profile_sha256=S.BASE.sha(PROFILE_PATH.read_bytes()),code=pins(),
            consistency='read_only_repeatable_read_at_capture; analysis must capture its own shared snapshot',
            live_checks='owner,physical schema,header,journal count,row/null counts,reader grants; no live row-bag rehash',
            analysis_execution_authorized=False,qualifying=False)
        return body,plan


def prepare(stream,state_dir,output,seconds=120,stop=None):
    guard=T.Guard(Path(stream),seconds,stop);guard.paths.append(Path(output).parent);guard.check(disk=True)
    body,plan=capture(stream,state_dir,seconds,guard.callback,output)
    output=T.A.separate(output,plan,[stream,Path(stream)/'reduction',Path(stream)/'audit',state_dir],guard.callback)
    compiled=Reference(body['source_schema'],body['columns']).manifest()
    body['reference_sha256']=S.BASE.sha(S.BASE.canonical(compiled));digest=S.BASE.sha(S.BASE.canonical(body))
    result=dict(body,handoff_sha256=digest,source_id='fixture:stream:'+digest)
    guard.check(disk=True)
    if body['code']!=pins():raise ValueError('Handoff code changed before writing')
    output.mkdir(mode=0o700);M.sync_directory(output.parent)
    raw=S.BASE.canonical(compiled)
    if len(raw)>MAX_REFERENCE:raise ValueError('Reference compiler byte budget exceeded')
    with M.open_file(output/'reference.json',True) as f:f.write(raw);f.flush();os.fsync(f.fileno())
    M.sync_directory(output);guard.check(disk=True);M.atomic_json(output,'handoff.json',result,exclusive=True)
    return result


def inspect(output):
    output=Path(output)
    if output.is_symlink():raise ValueError('Handoff cannot be a symlink')
    saved=M.read_json(output/'handoff.json')
    M.regular(output/'reference.json',MAX_REFERENCE)
    with M.open_file(output/'reference.json') as f:raw=f.read(MAX_REFERENCE+1)
    compiled=json.loads(raw)
    if raw!=S.BASE.canonical(compiled):raise ValueError('Noncanonical reference input')
    if type(saved) is not dict or set(saved)!=FIELDS or saved.get('kind')!='whole_source_analysis_handoff' or type(saved.get('version')) is not int or saved['version']!=1:raise ValueError('Invalid handoff format')
    if (any(type(saved[k]) is not dict for k in ('source_plan','table_rows','columns','database','measurement')) or
        type(saved['source_plan'].get('parameters')) is not dict or
        any(type(saved[k]) is not str or not re.fullmatch('[0-9a-f]{64}',saved[k]) for k in ('stream_request_sha256','partition_plan_sha256','audit_sha256','profile_sha256','reference_sha256')) or
        saved['profile_sha256']!=S.BASE.sha(PROFILE_PATH.read_bytes()) or
        any(type(saved[k]) is not str or not 1<=len(saved[k])<=512 for k in ('consistency','live_checks'))):raise ValueError('Invalid handoff metadata shape')
    T.Z.path(saved['stream_dir'])
    if (type(saved['source_schema']) is not str or not re.fullmatch('cdm_stream_[0-9a-f]{16}',saved['source_schema']) or
        type(saved['stream_request_sha256']) is not str or not re.fullmatch('[0-9a-f]{64}',saved['stream_request_sha256']) or
        saved['source_marker']!=F.MARKER+': partition-stream:'+saved['stream_request_sha256'] or saved['cdm_version'] not in F.VERSIONS or
        type(saved['table_rows']) is not dict or not 1<=len(saved['table_rows'])<=64 or set(saved['table_rows'])!=set(saved['columns']) or
        any(type(n) is not int or not 0<=n<=2**63-1 for n in saved['table_rows'].values()) or
        any(type(cols) is not dict or not 1<=len(cols)<=128 or any(type(t) is not str or not 1<=len(t)<=128 for t in cols.values()) for cols in saved['columns'].values()) or
        saved['source_plan'].get('table_rows')!=saved['table_rows'] or saved['source_plan']['parameters'].get('cdm_version')!=saved['cdm_version']):raise ValueError('Invalid handoff source shape')
    body={k:v for k,v in saved.items() if k not in ('handoff_sha256','source_id')}
    digest=S.BASE.sha(S.BASE.canonical(body))
    if (saved.get('handoff_sha256')!=digest or saved.get('source_id')!='fixture:stream:'+digest or saved.get('code')!=pins() or
        saved.get('analysis_execution_authorized') is not False or saved.get('qualifying') is not False or
        saved.get('reference_sha256')!=S.BASE.sha(raw) or compiled!=Reference(saved['source_schema'],saved['columns']).manifest()):raise ValueError('Handoff/reference/code identity differs')
    return saved


def verify(output,state_dir,seconds=120,stop=None):
    saved=inspect(output)
    guard=T.Guard(Path(saved['stream_dir']),seconds,stop);guard.check(disk=True)
    body,plan=capture(saved['stream_dir'],state_dir,seconds,guard.callback,output)
    T.A.separate(output,plan,[saved['stream_dir'],state_dir],stop)
    expected=Reference(body['source_schema'],body['columns']).manifest()
    body['reference_sha256']=S.BASE.sha(S.BASE.canonical(expected));digest=S.BASE.sha(S.BASE.canonical(body))
    guard.check()
    if saved!=dict(body,handoff_sha256=digest,source_id='fixture:stream:'+digest):raise ValueError('Handoff/source/reference identity changed')
    return saved


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['prepare','verify','inspect']);p.add_argument('--output-dir',type=Path,required=True);p.add_argument('--state-dir',type=Path);p.add_argument('--stream-dir',type=Path);p.add_argument('--seconds',type=float,default=120)
    a=p.parse_args()
    if (a.action=='prepare')!=(a.stream_dir is not None):p.error('Only prepare requires stream-dir')
    if a.action!='inspect' and a.state_dir is None:p.error('prepare/verify require state-dir')
    stopped=[None]
    def signal_stop(signum,frame):stopped[0]=signal.Signals(signum).name
    old={n:signal.signal(n,signal_stop) for n in (signal.SIGINT,signal.SIGTERM)}
    try:
        value=prepare(a.stream_dir,a.state_dir,a.output_dir,a.seconds,lambda:stopped[0]) if a.action=='prepare' else inspect(a.output_dir) if a.action=='inspect' else verify(a.output_dir,a.state_dir,a.seconds,lambda:stopped[0])
        print(json.dumps(value,sort_keys=True));return 0
    except M.Stopped as error:print('Source handoff stopped: '+str(error),file=sys.stderr);return error.code
    except (ValueError,OSError,KeyError,TypeError,RuntimeError,sqlite3.Error,T.L.subprocess.SubprocessError) as error:print('Source handoff refused: '+str(error),file=sys.stderr);return 1
    finally:
        for n,handler in old.items():signal.signal(n,handler)


if __name__=='__main__':raise SystemExit(main())
