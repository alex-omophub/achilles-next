"""Freeze source-run targets, bounded witnesses and read-only resource observations.

Registration is not execution admission. No workload, host configuration, database
connection or resource allocation is performed by this tool.
"""
import argparse
import datetime
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import sqlite3
import sys

import source_inventory as I

M=I.M
S=I.S
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())
ROLES=('source','inventory','database','temporary','export')
REFERENCE=dict(platform='Linux',cpus=8,memory_bytes=32*1024**3,
               job_memory_limit_bytes=28*1024**3,free_storage_bytes=512*1024**3)
UNVERIFIED=('dedicated_allocation','storage_pool_reservations','common_parent_audit',
            'operator_stop_authority','capacity_projection')
UNAVAILABLE=('full_tier_executor','full_source_inventory','chunk_database_loader')
PROC_SELF=Path('/proc/self')
MAX_PROC_BYTES=1024**2


def storage_plan(value):
    if type(value) is not dict or set(value)!=set(ROLES):
        raise ValueError('Storage plan needs exactly source/inventory/database/temporary/export paths')
    result={}
    for role in ROLES:
        path=value[role]
        if type(path) is not str or not 1<=len(path)<=4096 or '\0' in path or not Path(path).is_absolute():
            raise ValueError('Storage paths must be bounded absolute directory paths')
        result[role]=str(Path(path).resolve())
    return result


def measured(call):
    try:
        value=call()
        if value is None: raise ValueError('unavailable')
        return dict(state='observed',value=value)
    except (OSError,ValueError): return dict(state='unavailable',value=None)


def positive_integer(value):
    if type(value) is not int or not 0<value<=2**63-1: raise ValueError('Invalid positive resource count')
    return value


def memory_bytes():
    return positive_integer(os.sysconf('SC_PHYS_PAGES')*os.sysconf('SC_PAGE_SIZE'))


def process_cpus():
    affinity=getattr(os,'sched_getaffinity',None)
    if affinity is None: raise ValueError('Process CPU affinity unavailable')
    try: return positive_integer(len(affinity(0)))
    except NotImplementedError: raise ValueError('Process CPU affinity unavailable') from None


def proc_text(name):
    with (PROC_SELF/name).open('rb') as stream: raw=stream.read(MAX_PROC_BYTES+1)
    if len(raw)>MAX_PROC_BYTES: raise ValueError('Proc metadata byte budget exceeded')
    return raw.decode('utf-8')


def group_path(value):
    path=PurePosixPath(value)
    if not value.startswith('/') or value.startswith('//') or str(path)!=value or '..' in path.parts or '\0' in value:
        raise ValueError('Canonical absolute cgroup path required')
    return path


def mount_path(value):
    if re.search(r'\\(?!040|011|012|134)',value): raise ValueError('Unknown mount path escape')
    return group_path(re.sub(r'\\(040|011|012|134)',lambda match:chr(int(match[1],8)),value))


def cgroup_directory():
    members=[line[3:] for line in proc_text('cgroup').splitlines() if line.startswith('0::')]
    if len(members)!=1: raise ValueError('One unified cgroup membership required')
    member=group_path(members[0]); candidates=[]
    for line in proc_text('mountinfo').splitlines():
        before,separator,after=line.partition(' - '); tail=after.split()
        if not separator or not tail: raise ValueError('Malformed mount metadata')
        if tail[0]!='cgroup2': continue
        fields=before.split()
        if len(fields)<6: raise ValueError('Incomplete cgroup mount metadata')
        root,mount=mount_path(fields[3]),mount_path(fields[4])
        if member.is_relative_to(root):
            candidates.append((len(root.parts),Path(str(mount))/member.relative_to(root)))
    if not candidates: raise ValueError('Current cgroup is outside the mounted view')
    depth=max(d for d,path in candidates)
    paths={path for d,path in candidates if d==depth}
    # Multiple aliases are acceptable only when they resolve to the same group.
    identities=set()
    for path in paths:
        if not path.is_dir(): raise ValueError('Current cgroup directory unavailable')
        st=path.stat(); identities.add((st.st_dev,st.st_ino))
    if len(identities)!=1: raise ValueError('Ambiguous current cgroup mount view')
    return min(paths,key=str)


def cgroup_value(name):
    # Resolve the process membership within its mount view; never use the root
    # as a fallback for an unreadable or unmapped nested group.
    if name not in ('memory.max','cpu.max'): raise ValueError('Unknown cgroup limit')
    directory=cgroup_directory()
    with (directory/name).open('rb') as stream: raw=stream.read(129)
    if len(raw)>128: raise ValueError('Oversized cgroup limit')
    if cgroup_directory()!=directory: raise ValueError('Cgroup membership changed during observation')
    value=raw.decode('ascii').strip()
    if name=='cpu.max':
        quota,period=value.split()
        if not re.fullmatch('[1-9][0-9]*',period): raise ValueError('Invalid cgroup period')
        if quota!='max' and not re.fullmatch('[1-9][0-9]*',quota): raise ValueError('Invalid cgroup quota')
        return dict(quota_usec=None if quota=='max' else positive_integer(int(quota)),period_usec=positive_integer(int(period)))
    if value=='max': return dict(bytes=None)
    if not re.fullmatch('[0-9]+',value): raise ValueError('Invalid cgroup memory limit')
    return dict(bytes=positive_integer(int(value)))


def disk(path):
    path=Path(path)
    if not path.is_dir(): raise ValueError('Storage observation needs an existing directory')
    device=str(path.stat().st_dev); usage=shutil.disk_usage(path)
    return dict(logical_device=device,total_bytes=usage.total,free_bytes=usage.free)


def observe(paths):
    return dict(captured_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                platform=platform.system(),architecture=platform.machine(),
                visible_cpus=measured(process_cpus),
                physical_memory_bytes=measured(memory_bytes),
                cgroup_memory_max=measured(lambda:cgroup_value('memory.max')),
                cgroup_cpu_max=measured(lambda:cgroup_value('cpu.max')),
                storage={role:measured(lambda path=paths[role]:disk(path)) for role in ROLES})


def check_fact(fact,kind):
    if type(fact) is not dict or set(fact)!={'state','value'}: raise ValueError('Invalid observation envelope')
    if fact['state']=='unavailable':
        if fact['value'] is not None: raise ValueError('Unavailable observation has a value')
        return
    if fact['state']!='observed': raise ValueError('Unknown observation state')
    value=fact['value']
    if kind=='number': positive_integer(value)
    elif kind=='memory':
        if type(value) is not dict or set(value)!={'bytes'}: raise ValueError('Invalid memory observation')
        if value['bytes'] is not None: positive_integer(value['bytes'])
    elif kind=='cpu':
        if type(value) is not dict or set(value)!={'quota_usec','period_usec'}: raise ValueError('Invalid CPU observation')
        if value['quota_usec'] is not None: positive_integer(value['quota_usec'])
        positive_integer(value['period_usec'])
    else:
        if type(value) is not dict or set(value)!={'logical_device','total_bytes','free_bytes'}:
            raise ValueError('Invalid storage observation')
        if type(value['logical_device']) is not str or not re.fullmatch('[0-9]{1,20}',value['logical_device']):
            raise ValueError('Invalid device identity')
        positive_integer(value['total_bytes'])
        if type(value['free_bytes']) is not int or not 0<=value['free_bytes']<=value['total_bytes']:
            raise ValueError('Invalid free-space observation')


def assessment(observations):
    fields={'captured_at','platform','architecture','visible_cpus','physical_memory_bytes','cgroup_memory_max','cgroup_cpu_max','storage'}
    if type(observations) is not dict or set(observations)!=fields: raise ValueError('Invalid resource observation')
    stamp=observations['captured_at']
    if type(stamp) is not str or len(stamp)>40 or datetime.datetime.fromisoformat(stamp).utcoffset()!=datetime.timedelta(0):
        raise ValueError('UTC observation timestamp required')
    for key in ['platform','architecture']:
        if type(observations[key]) is not str or not 1<=len(observations[key])<=128: raise ValueError('Invalid platform observation')
    for key,kind in [('visible_cpus','number'),('physical_memory_bytes','number'),('cgroup_memory_max','memory'),('cgroup_cpu_max','cpu')]:
        check_fact(observations[key],kind)
    if type(observations['storage']) is not dict or set(observations['storage'])!=set(ROLES):
        raise ValueError('Incomplete storage observations')
    blockers=[name+'_unverified' for name in UNVERIFIED]+[name+'_unavailable' for name in UNAVAILABLE]; groups={}
    if observations['platform']!='Linux': blockers.append('reference_platform_not_linux')
    for key,minimum in [('visible_cpus',REFERENCE['cpus']),('physical_memory_bytes',REFERENCE['memory_bytes'])]:
        fact=observations[key]
        if fact['state']!='observed': blockers.append(key+'_unavailable')
        elif fact['value']<minimum: blockers.append(key+'_below_reference')
    for key in ['cgroup_memory_max','cgroup_cpu_max']:
        fact=observations[key]
        if fact['state']!='observed': blockers.append(key+'_unavailable'); continue
        value=fact['value']
        if key=='cgroup_memory_max' and value['bytes'] is not None and value['bytes']<REFERENCE['job_memory_limit_bytes']:
            blockers.append(key+'_below_reference')
        if key=='cgroup_cpu_max' and value['quota_usec'] is not None and value['quota_usec']<REFERENCE['cpus']*value['period_usec']:
            blockers.append(key+'_below_reference')
    for role,fact in observations['storage'].items():
        check_fact(fact,'disk')
        if fact['state']!='observed': blockers.append('storage_unavailable:'+role); continue
        value=fact['value']; group=groups.setdefault(value['logical_device'],dict(roles=[],free_bytes_min=value['free_bytes']))
        group['roles'].append(role); group['free_bytes_min']=min(group['free_bytes_min'],value['free_bytes'])
    devices=[]
    for device,group in sorted(groups.items()):
        group['roles'].sort(); devices.append(dict(logical_device=device,**group))
    return dict(full_tier_ready=False,execution_enabled=False,blocking_reasons=sorted(blockers),
                logical_device_groups=devices,
                storage_scope='Logical device aliases grouped without summing free space; physical pools/reservations unverified',
                cgroup_scope='Current process endpoints in its mounted namespace; ancestor constraints, whole-job inclusion and stop authority unverified')


def sample(source_dir,inventory_dir,target):
    if (source_dir is None)!=(inventory_dir is None): raise ValueError('Specify both sample source and inventory directories')
    if source_dir is None: return None
    record=I.verify(source_dir,inventory_dir)
    plan=M.load_plan(Path(source_dir).resolve())
    if S.BASE.canonical(plan['source'])!=S.BASE.canonical(target): raise ValueError('Sample target differs from registered tier/version')
    return dict(source_dir=str(Path(source_dir).resolve()),inventory_dir=str(Path(inventory_dir).resolve()),
                source_binding=record['binding'],inventory_sha256=S.BASE.sha(S.BASE.canonical(record)),
                database=record['database'],selected_rows=record['selected_rows'],source_csv_bytes=record['source_csv_bytes'],
                coverage='bounded_selection_only')


def request(run_id,tier,version,paths,source_dir,inventory_dir):
    if type(run_id) is not str or not re.fullmatch('[a-z0-9][a-z0-9-]{0,63}',run_id): raise ValueError('Use a bounded lowercase run ID')
    for path in [source_dir,inventory_dir]:
        if path is not None and Path(path).is_symlink(): raise ValueError('Sample directories must not be symlinks')
    return dict(run_id=run_id,tier=tier,cdm_version=version,storage=storage_plan(paths),
                sample_source=None if source_dir is None else str(Path(source_dir).resolve()),
                sample_inventory=None if inventory_dir is None else str(Path(inventory_dir).resolve()))


def body(req,observations):
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA: raise ValueError('Registration tool changed after import')
    target=S.Source(req['tier'],req['cdm_version']).plan()
    witness=sample(req['sample_source'],req['sample_inventory'],target)
    result=assessment(observations)
    if witness is None: result['blocking_reasons']=sorted(result['blocking_reasons']+['bounded_source_witness_missing'])
    return dict(kind='source_run_registration',version=1,status='planned_not_admitted',request=req,
                target=target,sample=witness,reference_requirements=dict(REFERENCE),observations=observations,
                assessment=result,registration_tool_sha256=SOURCE_SHA,
                materializer_sha256=M.SOURCE_SHA,inventory_tool_sha256=I.SOURCE_SHA,
                full_tier_generated=False,qualifying=False)


def register(output,run_id,tier,version,paths,source_dir=None,inventory_dir=None):
    req=request(run_id,tier,version,paths,source_dir,inventory_dir)
    value=body(req,observe(req['storage']))
    record=dict(value,registration_sha256=S.BASE.sha(S.BASE.canonical(value)))
    output=Path(output)
    if output.is_symlink(): raise ValueError('Registration output must not be a symlink')
    output=S.outside(output).resolve()
    for path in [req['sample_source'],req['sample_inventory']]:
        if path is not None and (output.is_relative_to(path) or Path(path).is_relative_to(output)):
            raise ValueError('Keep registration separate from sample source/inventory')
    if shutil.disk_usage(output.parent).free<16*1024**2: raise ValueError('Registration free-space floor reached')
    output.mkdir(mode=0o700); M.sync_directory(output.parent)
    M.atomic_json(output,'registration.json',record,exclusive=True)
    return record


def verify(output):
    output=Path(output)
    if output.is_symlink(): raise ValueError('Registration output must not be a symlink')
    output=S.outside(output).resolve()
    with os.scandir(output) as entries:
        first=next(entries,None); extra=next(entries,None)
        if first is None or first.name!='registration.json' or extra is not None: raise ValueError('Unexpected registration inventory')
    record=M.read_json(output/'registration.json'); req=record['request']
    normalized=request(req['run_id'],req['tier'],req['cdm_version'],req['storage'],req['sample_source'],req['sample_inventory'])
    value=body(normalized,record['observations'])
    expected=dict(value,registration_sha256=S.BASE.sha(S.BASE.canonical(value)))
    if S.BASE.canonical(expected)!=S.BASE.canonical(record): raise ValueError('Registration identity/summary differs')
    return record


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['register','verify']); parser.add_argument('--output-dir',type=Path,required=True)
    parser.add_argument('--run-id'); parser.add_argument('--tier',choices=['S1','S2']); parser.add_argument('--cdm-version',choices=['5.3','5.4','5.5'])
    parser.add_argument('--storage-plan',type=Path); parser.add_argument('--sample-source',type=Path); parser.add_argument('--sample-inventory',type=Path)
    args=parser.parse_args()
    if args.action=='register' and None in (args.run_id,args.tier,args.cdm_version,args.storage_plan):
        parser.error('register requires run-id, tier, cdm-version and storage-plan')
    if args.action=='verify' and any(v is not None for v in [args.run_id,args.tier,args.cdm_version,args.storage_plan,args.sample_source,args.sample_inventory]):
        parser.error('verify uses the frozen registration request')
    try:
        if args.action=='register':
            M.regular(args.storage_plan,65536)
            with M.open_file(args.storage_plan) as stream: paths=json.loads(stream.read(65537))
            record=register(args.output_dir,args.run_id,args.tier,args.cdm_version,paths,args.sample_source,args.sample_inventory)
        else: record=verify(args.output_dir)
        print(args.action+' complete: '+record['request']['run_id']+'; planned_not_admitted; qualifying=false'); return 0
    except M.Stopped as error:
        print('Registration stopped: '+str(error),file=sys.stderr); return error.code
    except KeyboardInterrupt:
        print('Registration interrupted',file=sys.stderr); return 130
    except (ValueError,OSError,KeyError,TypeError,sqlite3.Error) as error:
        print('Registration refused: '+str(error),file=sys.stderr); return 1


if __name__=='__main__': raise SystemExit(main())
