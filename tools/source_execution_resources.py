"""Register operator-approved resources and issue short-lived execution leases.

Host observation is read-only. This tool never allocates resources, grants host
permissions, changes PostgreSQL settings or starts a benchmark.
"""
import argparse
import datetime as DT
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import sys
import tempfile
import time

import source_run_registration as R
import bounded_source_loader as L

M=R.M
S=R.S
spec=importlib.util.spec_from_file_location('achillesnext_resource_observer',Path(__file__).parent/'docker/resource_audit.py')
C=importlib.util.module_from_spec(spec);spec.loader.exec_module(C)
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())
GIB=1024**3
LEASE_SECONDS=10
AUTHORITY=('dedicated_allocation','storage_reservations','scoped_metadata_access','stop_authority','cache_lifecycle','projection_reviewed')


def now():return time.time()
def stamp(value):return DT.datetime.fromtimestamp(value,DT.timezone.utc).isoformat()
def timestamp(value):
    if type(value) is not str or not 1<=len(value)<=40:raise ValueError('Bounded UTC timestamp required')
    # PostgreSQL emits +00; Python 3.10 requires the minute component.
    if value.endswith('+00'):value+=':00'
    # PostgreSQL omits trailing fractional zeroes; 3.10 accepts only 3/6 digits.
    value=re.sub(r'\.([0-9]{1,5})(?=\+00:00$)',lambda m:'.'+m[1].ljust(6,'0'),value)
    parsed=DT.datetime.fromisoformat(value)
    if parsed.utcoffset()!=DT.timedelta(0):raise ValueError('UTC timestamp required')
    return parsed.timestamp()


def digest(value):return S.BASE.sha(S.BASE.canonical(value))
def sha(value):
    if type(value) is not str or not re.fullmatch('[0-9a-f]{64}',value):raise ValueError('SHA256 identity required')
    return value


def integer(value,minimum=0):
    if type(value) is not int or not minimum<=value<=2**63-1:raise ValueError('Bounded integer required')
    return value


def path(value):
    if type(value) is not str or not 1<=len(value)<=4096 or '\0' in value or not Path(value).is_absolute():raise ValueError('Absolute bounded path required')
    return value


def pins():
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA:raise ValueError('Resource implementation changed after import')
    if S.BASE.sha(Path(C.__file__).read_bytes())!=C.SOURCE_SHA256:raise ValueError('Resource observer changed after import')
    return dict(resources=SOURCE_SHA,observer=C.SOURCE_SHA256,stream=S.BASE.sha((Path(__file__).parent/'partition_stream.py').read_bytes()))


def template(job,plan_sha,tier):
    job=S.outside(Path(job)).resolve();sha(plan_sha)
    if tier not in ('S1','S2'):raise ValueError('Use S1 or S2')
    return dict(kind='source_resource_allocation',version=1,allocation_id='unassigned',operator_uid=None,
        expires_at=stamp(now()+3600),partition_plan_sha256=plan_sha,tier=tier,job_dir=str(job),
        authority={k:False for k in AUTHORITY},common_parent=None,containers=dict(runner=None,postgres=None),
        storage={role:dict(host_path=str(job.parent),worker_path=str(job.parent),pool='unassigned') for role in R.ROLES},
        pools=dict(unassigned=dict(reserved_bytes=0)),projection=None,database=None)


def allocation(value):
    fields={'kind','version','allocation_id','operator_uid','expires_at','partition_plan_sha256','tier','job_dir',
        'authority','common_parent','containers','storage','pools','projection','database'}
    if type(value) is not dict or set(value)!=fields or value['kind']!='source_resource_allocation' or type(value['version']) is not int or value['version']!=1:raise ValueError('Invalid resource allocation shape')
    if type(value['allocation_id']) is not str or not re.fullmatch('[a-z0-9][a-z0-9-]{0,63}',value['allocation_id']):raise ValueError('Invalid allocation ID')
    if value['operator_uid'] is not None:integer(value['operator_uid'],1)
    timestamp(value['expires_at']);sha(value['partition_plan_sha256']);path(value['job_dir'])
    if value['tier'] not in ('S1','S2'):raise ValueError('Invalid source tier')
    if type(value['authority']) is not dict or set(value['authority'])!=set(AUTHORITY) or any(type(x) is not bool for x in value['authority'].values()):raise ValueError('Explicit operator authority booleans required')
    if value['common_parent'] is not None:
        path(value['common_parent'])
        if len(C.group_path(value['common_parent']).parts)>32:raise ValueError('Cgroup ancestor budget exceeded')
    if type(value['containers']) is not dict or set(value['containers'])!={'runner','postgres'}:raise ValueError('Two container identities required')
    for item in value['containers'].values():
        if item is not None:
            if type(item) is not dict or set(item)!={'id','pid'}:raise ValueError('Invalid container identity')
            sha(item['id']);integer(item['pid'],1)
    if type(value['storage']) is not dict or set(value['storage'])!=set(R.ROLES):raise ValueError('Five storage roles required')
    pools=value['pools']
    if type(pools) is not dict or not 1<=len(pools)<=5:raise ValueError('Register 1..5 physical storage pools')
    for name,entry in pools.items():
        if type(name) is not str or not re.fullmatch('[a-z0-9][a-z0-9-]{0,63}',name) or type(entry) is not dict or set(entry)!={'reserved_bytes'}:raise ValueError('Invalid storage pool')
        integer(entry['reserved_bytes'])
    for role,item in value['storage'].items():
        if type(item) is not dict or set(item)!={'host_path','worker_path','pool'} or item['pool'] not in pools:raise ValueError('Invalid storage binding')
        path(item['host_path']);path(item['worker_path'])
    if set(pools)!={x['pool'] for x in value['storage'].values()}:raise ValueError('Unused storage pool')
    p=value['projection']
    if p is not None:
        if type(p) is not dict or set(p)!={'basis','evidence_file','sha256','peak_bytes'} or p['basis'] not in ('bounded_witness','S1_calibration'):raise ValueError('Invalid capacity projection')
        path(p['evidence_file']);sha(p['sha256'])
        if type(p['peak_bytes']) is not dict or set(p['peak_bytes'])!=set(R.ROLES):raise ValueError('Five projected storage costs required')
        for n in p['peak_bytes'].values():integer(n,1)
    d=value['database']
    if d is not None:
        if type(d) is not dict or set(d)!={'database','owner','database_oid','postmaster_started_at','server_version','address','port','settings','initial_database_bytes'}:raise ValueError('Invalid database identity')
        for name in ['database','owner','postmaster_started_at','server_version']:
            if type(d[name]) is not str or not 1<=len(d[name])<=128:raise ValueError('Invalid database identity text')
        integer(d['database_oid'],1);integer(d['port'],1);integer(d['initial_database_bytes'])
        if (d['address'] not in ('127.0.0.1','::1',None) or type(d['settings']) is not dict or
            set(d['settings'])!={'shared_buffers','work_mem','hash_mem_multiplier','max_parallel_workers_per_gather','huge_pages','default_tablespace','temp_tablespaces'} or
            any(type(x) is not str or not 0<=len(x)<=128 for x in d['settings'].values())):raise ValueError('Local database/settings identity required')
    return value


def file_sha(filename):
    M.regular(Path(filename),16*1024**2);h=hashlib.sha256()
    with M.open_file(Path(filename)) as stream:
        while raw:=stream.read(65536):h.update(raw)
    return h.hexdigest()


def boot_id():return C.read(Path('/proc/sys/kernel/random/boot_id')).strip()


def directory_identity(directory):
    directory=Path(directory)
    if directory.is_symlink() or not directory.is_dir():raise ValueError('Nonsymlink storage directory required')
    st=directory.stat();return [st.st_dev,st.st_ino]


def database_volume(config,proc=Path('/proc')):
    """Observe only the registered postmaster's mounted PGDATA metadata.

    The existing scoped observer needs read/stat access; missing permission fails
    closed. No Docker socket, SQL superuser function or host-wide capability.
    External WAL/tablespaces are deliberately unsupported by this admission.
    """
    item=config['storage']['database'];postgres=config['containers']['postgres'];target=config['database']
    if postgres is None or target is None:raise ValueError('Database volume identity unavailable')
    process=Path(proc)/str(postgres['pid']);root=process/'root'
    data=root/Path(item['worker_path']).relative_to('/')
    identity=directory_identity(data)
    if directory_identity(item['host_path'])!=identity:raise ValueError('Database host/container storage mapping differs')
    pidfile=data/'postmaster.pid';M.regular(pidfile,8192)
    with M.open_file(pidfile) as stream:lines=stream.read(8193).decode('utf-8').splitlines()
    namespaces=[line.split()[1:] for line in C.read(process/'status').splitlines() if line.startswith('NSpid:')]
    if (len(lines)<4 or len(namespaces)!=1 or not namespaces[0] or
        lines[0]!=namespaces[0][-1] or lines[1]!=item['worker_path'] or
        int(lines[2])!=int(timestamp(target['postmaster_started_at'])) or int(lines[3])!=target['port']):raise ValueError('Registered process/path is not the target postmaster')
    children={name:directory_identity(data/name) for name in ('base','pg_wal','pg_tblspc')}
    # The target database may itself be a mount below an otherwise stable base.
    children['database']=directory_identity(data/'base'/str(target['database_oid']))
    if any(value[0]!=identity[0] for value in children.values()):raise ValueError('Database storage spans unregistered filesystems')
    with os.scandir(data/'pg_tblspc') as entries:
        if next(entries,None) is not None:raise ValueError('External database tablespaces are not admitted')
    return dict(data=identity,children=children,namespace_pid=lines[0],directory=lines[1])


def host_observation(config):
    """No credentials, process commands, Docker control, SQL or setting changes."""
    value=dict(platform=platform.system(),operator_uid=os.geteuid(),boot_id=R.measured(boot_id),
        visible_cpus=R.measured(R.process_cpus),memory_bytes=R.measured(R.memory_bytes),
        storage={role:R.measured(lambda item=item:R.disk(item['host_path'])) for role,item in config['storage'].items()},
        storage_directories={role:R.measured(lambda item=item:directory_identity(item['host_path'])) for role,item in config['storage'].items()},
        database_volume=R.measured(lambda:database_volume(config)),
        projection_sha256=R.measured(lambda:file_sha(config['projection']['evidence_file'])) if config['projection'] else dict(state='unavailable',value=None),
        attribution=None,attribution_error=None)
    try:
        if value['platform']!='Linux' or config['common_parent'] is None or any(x is None for x in config['containers'].values()):raise ValueError('Linux common-parent/container identities unavailable')
        observer=C.Audit('/sys/fs/cgroup','/proc',config['common_parent'],config['containers'])
        sample=observer.sample();ancestors={}
        for parent in observer.parent.parents:
            if str(parent)=='/':continue
            directory=observer.directory(parent)
            ancestors[str(parent)]={n:C.read(directory/n) for n in ('memory.max','cpu.max','memory.swap.max','pids.max')}
        value['attribution']=dict(identities=observer.identities,inodes={k:list(v) for k,v in observer.inodes.items()},
            observer_namespace=observer.observer_namespace,ancestors=ancestors,sample=sample)
    except (OSError,ValueError,KeyError,TypeError) as error:value['attribution_error']=str(error)
    return value


def assess(config,observed,created,baseline=None):
    blockers=[k+'_unverified' for k in AUTHORITY if not config['authority'][k]]
    if config['allocation_id']=='unassigned':blockers.append('allocation_unassigned')
    if config['operator_uid'] is None or observed['operator_uid']!=config['operator_uid'] or observed['operator_uid']==0:blockers.append('scoped_nonroot_operator_unverified')
    if observed['platform']!='Linux':blockers.append('reference_platform_not_linux')
    if not created-2<=now()<timestamp(config['expires_at'])<=created+8*3600:blockers.append('allocation_expired_or_invalid_window')
    for name,minimum in [('visible_cpus',8),('memory_bytes',32*GIB)]:
        fact=observed[name]
        if fact['state']!='observed' or type(fact['value']) is not int or fact['value']<minimum:blockers.append(name+'_below_reference_or_unavailable')
    if observed['boot_id']['state']!='observed':blockers.append('boot_identity_unavailable')
    if config['database'] is None:blockers.append('database_identity_missing')
    elif config['database']['settings']['huge_pages']!='off':blockers.append('hugetlb_accounting_unverified')
    if config['database'] is not None and (config['database']['settings']['default_tablespace'] not in ('','pg_default') or config['database']['settings']['temp_tablespaces']!=''):blockers.append('external_database_tablespaces_unverified')
    if observed['database_volume']['state']!='observed':blockers.append('database_volume_unverified')
    elif baseline and observed['database_volume']!=baseline['observed']['database_volume']:blockers.append('database_volume_identity_changed')
    projection=config['projection'];pools={};devices={}
    if projection is None:blockers.append('capacity_projection_missing')
    else:
        if projection['basis']!=('bounded_witness' if config['tier']=='S1' else 'S1_calibration'):blockers.append('capacity_projection_basis_differs')
        if observed['projection_sha256']!=dict(state='observed',value=projection['sha256']):blockers.append('capacity_projection_evidence_changed_or_missing')
        if sum(projection['peak_bytes'].values())>384*GIB:blockers.append('projected_disk_above_budget')
    for role,item in config['storage'].items():
        if observed['storage_directories'][role]['state']!='observed':blockers.append(role+'_directory_identity_unavailable')
        elif baseline and observed['storage_directories'][role]!=baseline['observed']['storage_directories'][role]:blockers.append(role+'_directory_identity_changed')
        fact=observed['storage'][role]
        if fact['state']!='observed':blockers.append(role+'_storage_unavailable');continue
        R.check_fact(fact,'disk');disk=fact['value'];pool=item['pool'];device=disk['logical_device']
        if device in devices and devices[device]!=pool:blockers.append('storage_alias_split_across_pools')
        devices[device]=pool
        group=pools.setdefault(pool,dict(free_bytes=disk['free_bytes'],projected_bytes=0))
        group['free_bytes']=min(group['free_bytes'],disk['free_bytes'])
        if projection:group['projected_bytes']+=projection['peak_bytes'][role]
    if len(pools)!=len(config['pools']):blockers.append('storage_pool_observations_incomplete')
    if baseline is None and sum(x['free_bytes'] for x in pools.values())<512*GIB:blockers.append('free_storage_below_reference')
    for pool,entry in pools.items():
        reserved=config['pools'][pool]['reserved_bytes'];projected=entry['projected_bytes']
        if reserved<(projected*5+3)//4 or reserved==0:blockers.append(pool+'_reservation_lacks_25_percent_headroom')
        if baseline is None:
            if reserved>entry['free_bytes']:blockers.append(pool+'_reservation_exceeds_free_storage')
        else:
            old=baseline['pool_observations'].get(pool)
            if old is None or old['free_bytes']-entry['free_bytes']>projected or entry['free_bytes']<reserved-projected:blockers.append(pool+'_storage_budget_or_floor_exceeded')
    attribution=observed['attribution']
    if attribution is None or attribution['sample']['unavailable']:blockers.append('common_parent_attribution_unavailable')
    else:
        sample=attribution['sample'];metrics=sample['metrics'];controls=metrics['controls']
        if controls['memory_bytes']!=28*GIB or controls['swap_bytes']!=0 or controls['cpu_quota_usec']!=8*controls['cpu_period_usec'] or controls['pids'] is None or not 128<=controls['pids']<=1024:blockers.append('parent_resource_limits_differ')
        if metrics['memory_lifetime_peak_bytes']>28*GIB or metrics['swap_current_bytes']!=0 or any(metrics['memory_events'].get(k,0)>0 for k in ('oom','oom_kill')):blockers.append('memory_swap_or_oom_budget_exceeded')
        for raw in attribution['ancestors'].values():
            c=C.controls(raw)
            if c['memory_bytes'] is not None and c['memory_bytes']<28*GIB or c['cpu_quota_usec'] is not None and c['cpu_quota_usec']<8*c['cpu_period_usec']:blockers.append('ancestor_resource_limit_below_reference')
        if baseline:
            old=baseline['observed']['attribution']
            if observed['boot_id']!=baseline['observed']['boot_id'] or any(attribution[k]!=old[k] for k in ('identities','inodes','ancestors','observer_namespace')):blockers.append('host_or_process_identity_changed')
            if sample['member_controls']!=old['sample']['member_controls']:blockers.append('member_resource_limits_changed')
            if any(sample['raw'][n]!=old['sample']['raw'][n] for n in ('memory.max','memory.swap.max','cpu.max','pids.max')):blockers.append('parent_resource_limits_changed')
            if metrics['memory_lifetime_peak_bytes']<old['sample']['metrics']['memory_lifetime_peak_bytes']:blockers.append('memory_counter_epoch_changed')
            elapsed=metrics['cpu']['usage_usec']-old['sample']['metrics']['cpu']['usage_usec']
            if not 0<=elapsed<=40*3600*1000000:blockers.append('cpu_budget_or_counter_epoch_changed')
            for role,fact in observed['storage'].items():
                if fact['state']!='observed' or fact['value']['logical_device']!=baseline['observed']['storage'][role]['value']['logical_device']:blockers.append(role+'_storage_identity_changed')
    return dict(blocking_reasons=sorted(set(blockers)),pool_observations=pools)


def stop_files(root):
    for name in ('STOP','revoked.json'):
        p=root/name
        if p.exists() or p.is_symlink():
            M.regular(p,0 if name=='STOP' else M.JSON_BYTES)
            raise M.Stopped('resource_'+('operator_stop_file' if name=='STOP' else 'admission_revoked'))


def read_registration(root,check_code=True):
    root=S.outside(Path(root)).resolve();value=M.read_json(root/'registration.json')
    fields={'kind','version','created_at','allocation','observed','pool_observations','code','status','blocking_reasons','qualifying','registration_sha256'}
    if (type(value) is not dict or set(value)!=fields or value.get('kind')!='source_execution_resource_registration' or
        type(value.get('version')) is not int or value['version']!=1 or value.get('qualifying') is not False or
        value.get('status') not in ('registered','blocked') or type(value.get('blocking_reasons')) is not list or
        len(value['blocking_reasons'])>128 or any(type(x) is not str or len(x)>128 for x in value['blocking_reasons']) or
        value.get('registration_sha256')!=digest({k:v for k,v in value.items() if k!='registration_sha256'})):raise ValueError('Resource registration identity differs')
    timestamp(value['created_at'])
    allocation(value['allocation'])
    if check_code and value['code']!=pins():raise ValueError('Resource/stream implementation changed')
    return value


def write_lease(root,record,observed,assessment):
    issued=now();value=dict(kind='source_execution_resource_lease',version=1,registration_sha256=record['registration_sha256'],
        issued_at=stamp(issued),valid_until=stamp(min(issued+LEASE_SECONDS,timestamp(record['allocation']['expires_at']))),
        status='ready' if not assessment['blocking_reasons'] else 'blocked',blocking_reasons=assessment['blocking_reasons'],
        observation_sha256=digest(observed),qualifying=False)
    M.atomic_json(root,'lease.json',value);return value


def register(config_file,output):
    config=allocation(M.read_json(Path(config_file)));output=S.outside(Path(output)).resolve()
    for other in [Path(config_file).resolve(),Path(config['job_dir']).resolve(),*(Path(x['host_path']).resolve() for x in config['storage'].values())]:
        if other==output or other.is_relative_to(output) or output.is_relative_to(other):raise ValueError('Keep resource output separate from input/job/storage paths')
    observed=host_observation(config);created=now();checked=assess(config,observed,created)
    body=dict(kind='source_execution_resource_registration',version=1,created_at=stamp(created),allocation=config,
        observed=observed,pool_observations=checked['pool_observations'],code=pins(),
        status='registered' if not checked['blocking_reasons'] else 'blocked',blocking_reasons=checked['blocking_reasons'],qualifying=False)
    record=dict(body,registration_sha256=digest(body));output.mkdir(mode=0o700);M.sync_directory(output.parent)
    with M.open_file(output/'.lock',True):pass
    with M.locked(output):M.atomic_json(output,'registration.json',record,exclusive=True);write_lease(output,record,observed,checked)
    return record


def renew(output):
    with M.locked(output) as root:
        stop_files(root);record=read_registration(root)
        observed=host_observation(record['allocation']);checked=assess(record['allocation'],observed,timestamp(record['created_at']),record)
        if record['status']!='registered':checked['blocking_reasons'].append('initial_registration_blocked')
        return write_lease(root,record,observed,checked)


def worker_identity():
    directory=R.cgroup_directory();st=directory.stat()
    return dict(platform=platform.system(),boot_id=boot_id(),namespace=os.readlink('/proc/self/ns/pid'),
        cgroup_inode=[st.st_dev,st.st_ino],memory=R.cgroup_value('memory.max'),cpu=R.cgroup_value('cpu.max'))


class Lease:
    def __init__(self,root,record,worker=False):self.root=Path(root);self.record=record;self.last=None;self.until=0;self.worker=worker
    def check(self):
        stop_files(self.root);tick=time.monotonic()
        if self.last is not None and tick-self.last<.5 and now()<self.until:return
        value=M.read_json(self.root/'lease.json');at=now()
        fields={'kind','version','registration_sha256','issued_at','valid_until','status','blocking_reasons','observation_sha256','qualifying'}
        if (type(value) is not dict or set(value)!=fields or value.get('qualifying') is not False or
            value.get('kind')!='source_execution_resource_lease' or type(value.get('version')) is not int or value['version']!=1 or
            value.get('registration_sha256')!=self.record['registration_sha256'] or value.get('status')!='ready' or value.get('blocking_reasons')!=[] or
            not at-LEASE_SECONDS-2<=timestamp(value['issued_at'])<=at+2 or
            not at<timestamp(value['valid_until'])<=min(timestamp(value['issued_at'])+LEASE_SECONDS,timestamp(self.record['allocation']['expires_at']))):raise M.Stopped('resource_admission_lease_unavailable_or_expired')
        if self.worker:check_worker(self.record)
        self.last=tick;self.until=timestamp(value['valid_until'])


def verify_worker(directory,job,plan,stop=None):
    root=Path(directory)
    if root.is_symlink():raise ValueError('Symlink resource registration')
    record=read_registration(root);config=record['allocation'];stop_files(root)
    if record['status']!='registered':raise ValueError('Resource admission blocked: '+', '.join(record['blocking_reasons']))
    if config['partition_plan_sha256']!=plan['partition_plan_sha256'] or config['tier']!=plan['source']['tier'] or Path(config['job_dir']).resolve()!=Path(job).resolve():raise ValueError('Resource admission source/job binding differs')
    witness=R.verify(plan['registration_dir'],stop=stop)['sample']
    if witness is None:raise ValueError('Whole-source admission needs a verified bounded source witness')
    lease=Lease(root,record,worker=True);lease.check()
    return dict(directory=str(root.resolve()),registration_sha256=record['registration_sha256']),lease,config['database']


def check_worker(record):
    config=record['allocation'];job=config['job_dir']
    identity=worker_identity();a=record['observed']['attribution'];runner=a['identities']['runner'];group=runner['cgroup']
    controls=C.controls(a['sample']['member_controls']['runner'])
    if (identity['platform']!='Linux' or identity['boot_id']!=record['observed']['boot_id']['value'] or identity['namespace']!=runner['pid_namespace'] or
        identity['cgroup_inode']!=a['inodes'][group] or identity['memory']!=dict(bytes=controls['memory_bytes']) or
        identity['cpu']!=dict(quota_usec=controls['cpu_quota_usec'],period_usec=controls['cpu_period_usec'])):raise ValueError('Execution process is outside registered runner resources')
    for role in ('source','inventory','export','temporary'):
        item=config['storage'][role];base=Path(item['worker_path']).resolve();actual=R.disk(base)
        location=Path(tempfile.gettempdir()).resolve() if role=='temporary' else Path(job).resolve()
        if (not location.is_relative_to(base) or actual['logical_device']!=record['observed']['storage'][role]['value']['logical_device'] or
            dict(state='observed',value=directory_identity(base))!=record['observed']['storage_directories'][role]):raise ValueError('Worker storage binding differs: '+role)


def target_identity(client):
    rows=client.rows("SELECT current_database() AS database,current_user AS owner,(SELECT oid::bigint FROM pg_database WHERE datname=current_database()) AS database_oid,pg_postmaster_start_time()::text AS postmaster_started_at,current_setting('server_version') AS server_version,host(inet_server_addr()) AS address,current_setting('port')::integer AS port,pg_database_size(current_database()) AS initial_database_bytes,json_build_object('shared_buffers',current_setting('shared_buffers'),'work_mem',current_setting('work_mem'),'hash_mem_multiplier',current_setting('hash_mem_multiplier'),'max_parallel_workers_per_gather',current_setting('max_parallel_workers_per_gather'),'huge_pages',current_setting('huge_pages'),'default_tablespace',current_setting('default_tablespace'),'temp_tablespaces',current_setting('temp_tablespaces')) AS settings")
    if len(rows)!=1:raise ValueError('Database resource identity unavailable')
    return rows[0]


def main():
    parser=argparse.ArgumentParser(description=__doc__);commands=parser.add_subparsers(dest='action',required=True)
    t=commands.add_parser('template');t.add_argument('--job-dir',type=Path,required=True);t.add_argument('--plan-sha256',required=True);t.add_argument('--tier',choices=['S1','S2'],required=True);t.add_argument('--output-file',type=Path,required=True)
    r=commands.add_parser('register');r.add_argument('--allocation-file',type=Path,required=True)
    for p in [r,commands.add_parser('renew'),commands.add_parser('revoke')]:p.add_argument('--output-dir',type=Path,required=True)
    d=commands.add_parser('database-identity');d.add_argument('--state-dir',type=Path,required=True)
    args=parser.parse_args()
    try:
        if args.action=='template':
            output=S.outside(args.output_file).resolve();value=template(args.job_dir,args.plan_sha256,args.tier)
            with M.open_file(output,True) as stream:stream.write(S.BASE.canonical(value));stream.flush();os.fsync(stream.fileno())
        elif args.action=='register':value=register(args.allocation_file,args.output_dir)
        elif args.action=='renew':value=renew(args.output_dir)
        elif args.action=='revoke':
            with M.locked(args.output_dir) as root:
                record=read_registration(root,check_code=False);value=dict(status='revoked',registration_sha256=record['registration_sha256'],qualifying=False);M.atomic_json(root,'revoked.json',value)
        else:
            client=L.Client(args.state_dir,L.Guard([args.state_dir]),'achillesnext-resource-identity');L.check_target(client);value=target_identity(client)
        print(json.dumps(value,sort_keys=True));return 3 if value.get('status')=='blocked' else 0
    except M.Stopped as error:print('Resource admission stopped: '+str(error),file=sys.stderr);return error.code
    except (ValueError,OSError,KeyError,TypeError,RuntimeError) as error:print('Resource admission refused: '+str(error),file=sys.stderr);return 1


if __name__=='__main__':raise SystemExit(main())
