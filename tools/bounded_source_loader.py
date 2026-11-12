"""Load only verified bounded source chunks into a new marked fixture schema."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time

import postgresql_fixtures as F
import source_run_registration as R

I=R.I
M=R.M
S=R.S
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())
MAX_IO=1024**2


class Guard(I.Guard):
    def __init__(self,paths,seconds=120,min_free=64*1024**2,stop=None):
        checked=I.limits(seconds=seconds,min_free=min_free)
        super().__init__(paths,dict(seconds=checked['seconds'],min_free_bytes=checked['min_free_bytes']),stop)

    def callback(self):
        self.check(); return None


def stop_process(process):
    for signum,seconds in [(signal.SIGINT,3),(signal.SIGTERM,2),(signal.SIGKILL,2)]:
        if process.poll() is not None: return
        try: os.killpg(process.pid,signum)
        except ProcessLookupError: pass
        try: process.wait(timeout=seconds); return
        except subprocess.TimeoutExpired: pass
    raise RuntimeError('Owned psql process did not exit')


class Client(F.Postgres):
    def __init__(self,state,guard,application):
        super().__init__(Path(state)); self.guard=guard; self.last_error=None
        self.env.update(PGCONNECT_TIMEOUT='5',PGAPPNAME=application)
        self.env['PGOPTIONS']+=' -c statement_timeout=30000 -c lock_timeout=2000 -c idle_in_transaction_session_timeout=10000'

    def run(self,sql,role='owner',allow_failure=False):
        if role not in ('owner','runner'): raise ValueError('Only fixture owner/runner services allowed')
        raw=sql.encode('utf-8')
        if len(raw)>MAX_IO: raise ValueError('Loader SQL byte budget exceeded')
        self.guard.check(disk=True)
        with tempfile.TemporaryFile() as script,tempfile.TemporaryFile() as out,tempfile.TemporaryFile() as err:
            script.write(raw); script.seek(0)
            process=subprocess.Popen(self.args+['-d','service=achilles_next_'+role],stdin=script,stdout=out,stderr=err,
                                     env=self.env,start_new_session=True)
            try:
                while process.poll() is None:
                    self.guard.check(disk=True)
                    if max(os.fstat(out.fileno()).st_size,os.fstat(err.fileno()).st_size)>MAX_IO:
                        raise ValueError('Loader psql output byte budget exceeded')
                    time.sleep(.02)
                self.guard.check()
                if max(os.fstat(out.fileno()).st_size,os.fstat(err.fileno()).st_size)>MAX_IO:
                    raise ValueError('Loader psql output byte budget exceeded')
                out.seek(0); err.seek(0); stdout=out.read(MAX_IO+1).decode('utf-8'); stderr=err.read(MAX_IO+1).decode('utf-8')
            finally:
                if process.poll() is None: stop_process(process)
        # Retained diagnostics stay private and redact the known fixture secrets.
        password_file=self.state/'pgpass'
        if password_file.exists() and password_file.stat().st_size<=65536:
            for line in password_file.read_text().splitlines():
                secret=line.rsplit(':',1)[-1]
                if secret: stderr=stderr.replace(secret,'[redacted]')
        result=subprocess.CompletedProcess(self.args,process.returncode,stdout,stderr)
        if result.returncode:
            self.last_error=stderr[:65536]
            if not allow_failure: raise RuntimeError('psql failed; see private attempt diagnostics')
        return result

    def versions(self):
        server=self.value('SHOW server_version;').split()[0]
        probe=subprocess.run(['psql','--version'],capture_output=True,text=True,env=self.env,timeout=5,check=False)
        self.guard.check()
        probe.check_returncode()
        client=probe.stdout.strip()
        if server!=F.LOCK['postgresql_server'] or not re.search(r'PostgreSQL\) '+re.escape(F.LOCK['psql_client'])+r'(?:\s|$)',client):
            raise ValueError('Loader requires the locked PostgreSQL server/native psql tuple')
        return dict(server=server,client=client)


def pins():
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA: raise ValueError('Loader changed after import')
    return dict(loader=SOURCE_SHA,registrar=R.SOURCE_SHA,inventory=I.SOURCE_SHA,materializer=M.SOURCE_SHA,
                fixture_client=S.BASE.sha(Path(F.__file__).read_bytes()))


def check_target(client):
    F.guard_database(client)
    addresses=client.rows('SELECT host(inet_server_addr()) AS address')
    if len(addresses)!=1 or addresses[0]['address'] not in (None,'127.0.0.1','::1'):
        raise ValueError('Loader requires a local marked fixture server')
    return client.versions()


def target_guard_sql():
    return ("DO $selection_target$ BEGIN IF current_database()<>"+F.literal(F.DB)+
            " OR current_user<>"+F.literal(F.OWNER)+
            " OR (SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname=current_database()) IS DISTINCT FROM "+F.literal(F.MARKER)+
            " OR (inet_server_addr() IS NOT NULL AND inet_server_addr() NOT IN ('127.0.0.1'::inet,'::1'::inet)) "
            "OR split_part(current_setting('server_version'),' ',1)<>"+F.literal(F.LOCK['postgresql_server'])+' '+
            "THEN RAISE EXCEPTION 'Not the local marked fixture owner connection'; END IF; END; $selection_target$;")


def facts(plan,complete):
    source=S.Source(plan['source']['tier'],plan['source']['parameters']['cdm_version'])
    expected={t:dict(rows=0,nulls={c['name']:0 for c in columns}) for t,columns in source.columns.items()}
    for chunk in complete['chunks']:
        info=expected[chunk['table']]; info['rows']+=chunk['rows']
        for column,count in chunk['null_counts'].items(): info['nulls'][column]+=count
    return expected


@contextmanager
def freeze(registration,guard):
    sample=registration['sample']; source=Path(sample['source_dir'])
    with tempfile.TemporaryDirectory(prefix='achillesnext-selection-load-') as directory:
        frozen=Path(directory); guard.paths.append(frozen)
        try:
            if any(c in str(frozen) for c in "'\\\r\n"): raise ValueError('Unsafe frontend COPY path')
            with M.locked(source) as source:
                plan,complete,_=I.verified_source(source,guard)
                if S.BASE.canonical(I.binding(plan,complete))!=S.BASE.canonical(sample['source_binding']):
                    raise ValueError('Source binding changed after registration verification')
                guard.check(disk=True)
                if shutil.disk_usage(frozen).free<complete['csv_bytes']+guard.controls['min_free_bytes']:
                    raise ValueError('Insufficient temporary space for frozen source plus floor')
                with M.open_file(frozen/'.lock',True): pass
                for name,value in [('plan.json',plan),('checkpoint.json',M.checkpoint(plan,complete['chunks'])),('complete.json',complete)]:
                    M.atomic_json(frozen,name,value,exclusive=True)
                copied_inodes={}
                for chunk in complete['chunks']:
                    st=M.regular(source/chunk['file'],S.MAX_BYTES,(1,2)); inode=(st.st_dev,st.st_ino)
                    if inode in copied_inodes:
                        guard.check(disk=True); os.link(frozen/copied_inodes[inode],frozen/chunk['file'],follow_symlinks=False)
                        continue
                    copied=0
                    with M.open_file(source/chunk['file']) as reader,M.open_file(frozen/chunk['file'],True) as writer:
                        while True:
                            guard.check(disk=True); raw=reader.read(min(65536,chunk['bytes']-copied+1))
                            if not raw: break
                            copied+=len(raw)
                            if copied>chunk['bytes']: raise ValueError('Source grew during freeze')
                            writer.write(raw)
                        writer.flush(); os.fsync(writer.fileno())
                    if copied!=chunk['bytes']: raise ValueError('Source shrank during freeze')
                    copied_inodes[inode]=chunk['file']
            checked,_,_=I.verified_source(frozen,guard)
            if S.BASE.canonical(checked)!=S.BASE.canonical(plan): raise ValueError('Frozen plan differs')
            for chunk in complete['chunks']: (frozen/chunk['file']).chmod(0o400)
            yield frozen,plan,complete
        finally: guard.paths.remove(frozen)


def fact_checks(expected,schema):
    """Generate read-only aggregate assertions for the specified tables."""
    q=F.identifier(schema);commands=[]
    for table,info in expected.items():
        nulls=','.join(F.literal(c)+',count(*) FILTER (WHERE '+F.identifier(c)+' IS NULL)' for c in info['nulls'])
        expression="jsonb_build_object('rows',count(*),'nulls',jsonb_build_object("+nulls+'))'
        value=F.literal(S.BASE.canonical(info).decode().strip())+'::jsonb'
        commands.append(f"DO $selection_check$ BEGIN IF (SELECT {expression} FROM {q}.{F.identifier(table)}) IS DISTINCT FROM {value} THEN RAISE EXCEPTION 'Loaded selection facts differ'; END IF; END; $selection_check$;")
    return commands


def build_script(frozen,plan,complete,schema,marker):
    q=F.identifier(schema); version=plan['source']['parameters']['cdm_version']
    ddl=(S.BASE.DDL/(version+'.sql')).read_bytes()
    if S.BASE.sha(ddl)!=plan['source']['pins']['DDL']: raise ValueError('Locked DDL changed before COPY')
    commands=['BEGIN;',target_guard_sql(),f'CREATE SCHEMA {q}; REVOKE ALL ON SCHEMA {q} FROM PUBLIC;',
              f'COMMENT ON SCHEMA {q} IS {F.literal(marker)};',ddl.decode().replace('@cdmDatabaseSchema',q)]
    columns=S.Source(plan['source']['tier'],version).columns
    for chunk in complete['chunks']:
        table=chunk['table']; names=','.join(F.identifier(c['name']) for c in columns[table])
        commands.append(f"\\copy {q}.{F.identifier(table)} ({names}) FROM '{frozen/chunk['file']}' WITH (FORMAT csv, HEADER true, NULL '\\N')")
    commands.extend(fact_checks(facts(plan,complete),schema))
    commands.extend([F.grants_sql(schema),'COMMIT;'])
    script='\n'.join(commands)
    if len(script.encode())>MAX_IO: raise ValueError('Loader SQL byte budget exceeded')
    return script


def output_path(output,registration):
    output=Path(output)
    if output.is_symlink(): raise ValueError('Loader output must not be a symlink')
    output=S.outside(output).resolve()
    for raw in [registration,*registration_sample_paths(registration)]:
        path=Path(raw).resolve()
        if output.is_relative_to(path) or path.is_relative_to(output): raise ValueError('Keep load output separate from registration/source/inventory')
    return output


def registration_sample_paths(directory):
    request=M.read_json(Path(directory)/'registration.json')['request']
    return [p for p in [request['sample_source'],request['sample_inventory']] if p is not None]


def load(registration_dir,output,state,seconds=120,min_free=64*1024**2,stop=None):
    output=output_path(output,registration_dir); guard=Guard([output.parent],seconds,min_free,stop)
    guard.check(disk=True); registration=R.verify(registration_dir,stop=guard.callback)
    if registration['sample'] is None: raise ValueError('Loader requires a verified bounded witness')
    identity=pins(); load_id=secrets.token_hex(8); schema='cdm_selection_'+load_id
    marker=F.MARKER+': bounded-selection:'+registration['registration_sha256']
    request=dict(kind='bounded_selection_database_load_request',version=1,schema=schema,marker=marker,
                 registration_sha256=registration['registration_sha256'],code=identity,limits=guard.controls,
                 source_binding=registration['sample']['source_binding'],qualifying=False,whole_source_loaded=False)
    client=None; attempted=False; committed=False; created=False
    try:
        output.mkdir(mode=0o700); created=True; M.sync_directory(output.parent)
        with M.open_file(output/'.lock',True): pass
        with M.locked(output):
            M.atomic_json(output,'request.json',request,exclusive=True)
            with freeze(registration,guard) as (frozen,plan,complete):
                client=Client(state,guard,'achillesnext-selection-'+load_id); versions=check_target(client)
                script=build_script(frozen,plan,complete,schema,marker)
                if pins()!=identity: raise ValueError('Loader code changed before database work')
                guard.check(disk=True); attempted=True; client.run(script); committed=True
                if pins()!=identity: raise ValueError('Loader code changed during database work')
                guard.check(disk=True)
                receipt=dict(kind='bounded_selection_database_load',version=1,status='complete',request=request,
                             server=versions,rows=complete['rows'],csv_bytes=complete['csv_bytes'],tables=facts(plan,complete),
                             source_coverage='bounded_selection_only',full_tier_generated=False,whole_source_loaded=False,qualifying=False)
                M.atomic_json(output,'complete.json',receipt,exclusive=True)
                return receipt
    except (Exception,KeyboardInterrupt) as error:
        if created:
            M.atomic_json(output,'attempt.json',dict(status='stopped' if isinstance(error,(M.Stopped,KeyboardInterrupt)) else 'failed',
                reason=str(error) or 'KeyboardInterrupt',commit_outcome='committed' if committed else 'unknown' if attempted else 'not_attempted',
                database_error=None if client is None else client.last_error,qualifying=False,whole_source_loaded=False))
        raise


def drop(state,output,seconds=30,stop=None):
    with M.locked(output) as output: return drop_locked(state,output,seconds,stop)


def drop_locked(state,output,seconds,stop):
    request=M.read_json(Path(output)/'request.json'); schema=request['schema']; marker=request['marker']
    digest=request['registration_sha256']
    if (request.get('kind')!='bounded_selection_database_load_request' or type(request.get('version')) is not int or request['version']!=1 or
        type(schema) is not str or not re.fullmatch('cdm_selection_[0-9a-f]{16}',schema) or
        type(digest) is not str or not re.fullmatch('[0-9a-f]{64}',digest) or marker!=F.MARKER+': bounded-selection:'+digest):
        raise ValueError('Invalid owned selection identity')
    guard=Guard([Path(output)],seconds,stop=stop); client=Client(state,guard,'achillesnext-selection-cleanup'); check_target(client)
    rows=client.rows("SELECT obj_description(oid,'pg_namespace') AS marker,nspowner=(SELECT oid FROM pg_roles WHERE rolname=current_user) AS owned FROM pg_namespace WHERE nspname="+F.literal(schema))
    if not rows: return dict(status='absent',schema=schema)
    if rows!=[dict(marker=marker,owned=True)]: raise ValueError('Refusing cleanup of an unowned or differently marked schema')
    # Recheck in the same transaction that performs the drop; a stale client-side
    # owner/marker observation is never the sole cleanup authority.
    client.run('BEGIN;\n'+target_guard_sql()+'\n'+drop_guard_sql(schema,marker)+'\nCOMMIT;')
    return dict(status='dropped',schema=schema)


def drop_guard_sql(schema,marker):
    return ("DO $selection_drop$ DECLARE owned boolean; marker text; BEGIN SELECT nspowner=(SELECT oid FROM pg_roles WHERE rolname=current_user),obj_description(oid,'pg_namespace') INTO owned,marker FROM pg_namespace WHERE nspname="+F.literal(schema)+
               "; IF NOT FOUND THEN RETURN; END IF; IF owned IS DISTINCT FROM true OR marker IS DISTINCT FROM "+F.literal(marker)+
               " THEN RAISE EXCEPTION 'Selection cleanup owner/marker changed'; END IF; EXECUTE "+F.literal('DROP SCHEMA '+F.identifier(schema)+' CASCADE;')+"; END; $selection_drop$;")


def main():
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('action',choices=['load','drop'])
    parser.add_argument('--registration-dir',type=Path); parser.add_argument('--output-dir',type=Path,required=True)
    parser.add_argument('--state-dir',type=Path,required=True); parser.add_argument('--seconds',type=float,default=120)
    args=parser.parse_args()
    if args.action=='load' and args.registration_dir is None: parser.error('load requires registration-dir')
    if args.action=='drop' and args.registration_dir is not None: parser.error('drop uses the saved load request')
    interrupted=[None]
    def interrupt(signum,frame): interrupted[0]=signal.Signals(signum).name
    old={n:signal.signal(n,interrupt) for n in [signal.SIGINT,signal.SIGTERM]}
    try:
        if args.action=='load': result=load(args.registration_dir,args.output_dir,args.state_dir,args.seconds,stop=lambda:interrupted[0])
        else: result=drop(args.state_dir,args.output_dir,args.seconds,stop=lambda:interrupted[0])
        print(json.dumps(dict(status=result['status'],qualifying=False))); return 0
    except M.Stopped as error:
        print('Load stopped: '+str(error),file=sys.stderr); return error.code
    except (ValueError,OSError,RuntimeError,KeyError,TypeError,sqlite3.Error,subprocess.SubprocessError) as error:
        print('Selection loader refused: '+str(error),file=sys.stderr); return 1
    finally:
        for n,handler in old.items(): signal.signal(n,handler)


if __name__=='__main__': raise SystemExit(main())
