"""Bounded synthetic validation inside the image; no Docker socket or host control."""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[2]
STATE=Path('/validation/state')
SECRETS=Path('/validation/secrets')
OUTPUT=Path('/output')
MARKER='AchillesNext Docker validation v1'
CHILD=None
INTERRUPTED=False


def write_json(path,value):
    path.write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')


def source_pins():
    excluded={'node_modules','__pycache__','dist','build','coverage','.vite','.git'}
    return {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(ROOT.rglob('*')) if not excluded.intersection(p.relative_to(ROOT).parts)
        and p.is_file() and p.suffix!='.pyc' and not p.is_symlink()}


def bootstrap(state=STATE,credentials=SECRETS,uid=None,gid=None):
    uid=int(os.environ.get('VALIDATION_UID','1000')) if uid is None else uid
    gid=int(os.environ.get('VALIDATION_GID','1000')) if gid is None else gid
    if not 0<uid<2**31 or not 0<gid<2**31:raise ValueError('Non-root numeric UID/GID required')
    for directory in [state,credentials]:
        if directory.is_symlink():raise ValueError('Symlink validation volume')
        directory.mkdir(exist_ok=True)
        marker=directory/'docker-validation.json'
        if marker.exists():
            if marker.is_symlink() or json.loads(marker.read_text())!=dict(marker=MARKER,uid=uid,gid=gid):
                raise ValueError('Validation volume ownership/marker differs')
        else:
            if any(directory.iterdir()):raise ValueError('Refusing nonempty unmarked validation volume')
            write_json(marker,dict(marker=MARKER,uid=uid,gid=gid))
        os.chmod(directory,0o700);os.chown(directory,uid,gid)
        os.chmod(marker,0o600);os.chown(marker,uid,gid)
    password=credentials/'postgres_password'
    if password.is_symlink():raise ValueError('Symlink credential')
    if password.exists():
        if not re.fullmatch('[0-9a-f]{64}\n',password.read_text()):raise ValueError('Invalid saved synthetic credential')
    else:
        with password.open('x') as stream:stream.write(secrets.token_hex(32)+'\n')
    os.chmod(password,0o600);os.chown(password,uid,gid)
    print('Initialized marked validation volumes; synthetic credentials retained privately')


def fixtures():
    spec=importlib.util.spec_from_file_location('achillesnext_docker_fixtures',ROOT/'tools/postgresql_fixtures.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


def build_manifest():
    target=Path('/opt/validation/image-manifest.json')
    runtime=Path('/tmp/achillesnext-build-runtime.json')
    subprocess.run(['Rscript','--vanilla','tools/docker/runtime.R',str(runtime)],check=True)
    tuple=json.loads((ROOT/'tests/tracer/runtime-lock.json').read_text())
    client=subprocess.check_output(['psql','--version'],text=True).strip()
    node=subprocess.check_output(['node','--version'],text=True).strip()
    if not re.search(r'\b'+re.escape(tuple['psql_client'])+r'\b',client) or node!='v'+tuple['node']:
        raise ValueError('Client/Node tuple mismatch')
    write_json(target,dict(source_sha256=source_pins(),runtime=json.loads(runtime.read_text()),psql=client,node=node,
        lock_sha256=hashlib.sha256((ROOT/'tools/docker/runtime-lock.json').read_bytes()).hexdigest(),
        system_packages_sha256=hashlib.sha256(Path('/opt/validation/system-packages.txt').read_bytes()).hexdigest()))
    runtime.unlink()


def interrupt(signum,frame):
    global INTERRUPTED
    INTERRUPTED=True
    if CHILD is not None:
        try:os.killpg(CHILD.pid,signal.SIGINT)
        except ProcessLookupError:pass


def execute(command,out,name,timeout=300):
    global CHILD
    if INTERRUPTED:raise RuntimeError('Validation interrupted')
    for directory in [STATE,OUTPUT]:
        if shutil.disk_usage(directory).free<10*1024**3:raise RuntimeError('Validation volume free-space floor reached')
    print('STEP '+name,flush=True)
    start=time.monotonic()
    with (out/(name+'.log')).open('xb') as log:
        CHILD=subprocess.Popen(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            try:code=CHILD.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(CHILD.pid,signal.SIGINT)
                try:CHILD.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    os.killpg(CHILD.pid,signal.SIGTERM)
                    try:CHILD.wait(timeout=15)
                    except subprocess.TimeoutExpired:os.killpg(CHILD.pid,signal.SIGKILL);CHILD.wait()
                raise RuntimeError('Step deadline exceeded: '+name)
        finally:CHILD=None
    if code or INTERRUPTED:raise RuntimeError('Validation step failed/interrupted: '+name+'; see retained log')
    return dict(step=name,wall_seconds=time.monotonic()-start)


def cgroup_files(read):
    result={}
    for name in ['memory.current','memory.peak','memory.max','memory.stat','memory.events','memory.swap.current','memory.swap.max','cpu.stat','cpu.max','io.stat','pids.max','cgroup.procs']:
        try:
            value=read(name)
            if value is None or len(value)>65536:raise ValueError('Unavailable or oversized counter')
            result[name]=dict(state='available',raw=value)
        except (OSError,ValueError,RuntimeError,subprocess.SubprocessError):
            result[name]=dict(state='unavailable',raw=None)
    return result


def snapshot(admin):
    runner=cgroup_files(lambda name:(Path('/sys/fs/cgroup')/name).read_text())
    server=cgroup_files(lambda name:json.loads(admin.value("SELECT COALESCE(to_json(pg_read_file('/sys/fs/cgroup/"+name+"',0,65536,true))::text,'null')"))) if admin else None
    return dict(runner_cgroup=runner,postgres_cgroup=server,
        scope='separate container counters; process IDs are container-local; includes startup/health/observer activity; lifetime peaks must not be summed',
        whole_job_peak=dict(state='unavailable',reason='no verified common parent cgroup'),qualifying=False)


def run(mode):
    if mode not in ['offline','smoke','telemetry']:raise ValueError('Unknown validation mode')
    if os.getuid()==0:raise ValueError('Run validation as a non-root user')
    expected=dict(marker=MARKER,uid=os.getuid(),gid=os.getgid())
    for directory in [STATE,SECRETS]:
        if directory.is_symlink() or json.loads((directory/'docker-validation.json').read_text())!=expected:
            raise ValueError('Unmarked/foreign validation state')
    if not OUTPUT.is_dir() or OUTPUT.is_symlink():raise ValueError('Output bind directory required')
    home=STATE/'home';home.mkdir(exist_ok=True,mode=0o700)
    out=OUTPUT/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+secrets.token_hex(4))
    out.mkdir(mode=0o700)
    record=dict(status='running',mode=mode,qualifying=False,steps=[],project=os.environ.get('ACHILLESNEXT_VALIDATION_PROJECT'),
        image_id=os.environ.get('ACHILLESNEXT_VALIDATION_IMAGE_ID') or None,
        platform=dict(os=sys.platform,machine=platform.machine(),kernel=platform.release(),visible_logical_CPUs=os.cpu_count()),
        cache='fresh validator process; database and kernel caches uncontrolled; no host restart/cache reset',
        limits='Compose CPU/memory/PID caps plus step deadlines; bind storage monitored, not quota-reserved')
    write_json(out/'validation.json',record)
    admin=None
    try:
        manifest=json.loads(Path('/opt/validation/image-manifest.json').read_text())
        if source_pins()!=manifest['source_sha256']:raise ValueError('Image source differs from build manifest')
        write_json(out/'image-manifest.json',manifest)
        record['steps'].append(execute(['Rscript','--vanilla','tools/docker/runtime.R',str(out/'runtime.json')],out,'runtime'))
        record['steps'].append(execute(['Rscript','--vanilla','tests/tracer/resource-telemetry-observer.R'],out,'observer-offline'))
        if mode=='offline':
            record['steps'].append(execute(['python3','-m','unittest','discover','-s','tests','-p','test_*.py'],out,'python',1200))
            record['steps'].append(execute(['npm','run','check','--prefix','packages/contracts'],out,'contracts',300))
            record['steps'].append(execute(['npm','test','--prefix','packages/tracer'],out,'react',300))
        else:
            fixture=fixtures();state=STATE/'postgresql';state.mkdir(exist_ok=True,mode=0o700)
            # Explicit loopback credentials exist only in this Compose network namespace.
            adminpass=STATE/'admin.pgpass'
            adminpass.write_text('127.0.0.1:5432:*:postgres:'+ (SECRETS/'postgres_password').read_text().strip()+'\n');adminpass.chmod(0o600)
            os.environ['PGPASSFILE']=str(adminpass);os.environ['PGCONNECT_TIMEOUT']='5'
            admin=fixture.Postgres(state,admin=True,host='127.0.0.1',admin_user='postgres')
            admin.env['PGOPTIONS']+=' -c statement_timeout=10000 -c lock_timeout=1000'
            server=admin.value('SHOW server_version').split()[0]
            if server!=fixture.LOCK['postgresql_server']:raise ValueError('PostgreSQL server tuple mismatch')
            write_json(out/'resources-before.json',snapshot(admin))
            record['steps'].append(execute(['python3','tools/postgresql_fixtures.py','setup','--host','127.0.0.1',
                '--admin-user','postgres','--state-dir',str(state)],out,'fixture-setup'))
            record['steps'].append(execute(['Rscript','--vanilla','tests/tracer/resource-telemetry-observer.R','tools/tracer_fixture_config.R'],out,'observer-sql'))
            record['steps'].append(execute(['Rscript','--vanilla','tests/tracer/implementation-identity.R'],out,'identity'))
            if mode=='telemetry':
                record['steps'].append(execute(['python3','tools/benchmark/telemetry.py','--with-projected','--state',str(state),
                    '--config','tools/tracer_fixture_config.R','--output-dir',str(out/'telemetry'),'--cgroup','/sys/fs/cgroup'],out,'telemetry',900))
                receipt=json.loads((out/'telemetry/receipt.json').read_text())
                if receipt['status']!='passed' or receipt['qualifying']:raise ValueError('Invalid tiny telemetry receipt')
                record['tiny_receipt_sha256']=hashlib.sha256((out/'telemetry/receipt.json').read_bytes()).hexdigest()
            record['fixture_content_id']=json.loads((state/'verification.json').read_text())['content_id']
        if INTERRUPTED or source_pins()!=manifest['source_sha256']:raise ValueError('Interrupted run or image source drift')
        record['status']='passed'
    except (Exception,KeyboardInterrupt) as error:
        record['status']='failed';record['error']=str(error)
    finally:
        try:write_json(out/'resources-after.json',snapshot(admin))
        except Exception:record['resource_capture']='unavailable'
        write_json(out/'validation.json',record)
        print(record['status'].upper()+': '+str(out),flush=True)
    return 0 if record['status']=='passed' else 1


def main():
    if len(sys.argv)!=2:raise ValueError('Select bootstrap, build-manifest, offline, smoke or telemetry')
    if sys.argv[1]=='bootstrap':bootstrap();return 0
    if sys.argv[1]=='build-manifest':build_manifest();return 0
    signal.signal(signal.SIGINT,interrupt);signal.signal(signal.SIGTERM,interrupt)
    return run(sys.argv[1])


if __name__=='__main__':sys.exit(main())
