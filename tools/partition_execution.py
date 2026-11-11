"""Resume a bounded set of source partitions through generation and inventory.

Local SQLite inventories only; no source/PostgreSQL access, full-tier admission
or analytical-result publication.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import sqlite3
import sys

import source_partition_plan as P

R=P.R
I=R.I
M=P.M
S=P.S
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())
MAX_UNITS=8
MAX_INVENTORY_ATTEMPTS=3


class Guard(I.Guard):
    def __init__(self,root,seconds=120,stop=None):
        c=I.limits(seconds=seconds,min_free=64*1024**2)
        super().__init__([root],c,stop); self.root=root

    def check(self,disk=False):
        super().check(disk)
        path=self.root/'STOP'
        if path.exists() or path.is_symlink():
            M.regular(path,0); raise M.Stopped('operator_stop_file')

    def callback(self):
        self.check(); return None


def request(schedule_dir,indices,stop=None):
    if (type(indices) is not list or not 1<=len(indices)<=MAX_UNITS or
        any(type(n) is not int for n in indices) or len(set(indices))!=len(indices)):
        raise ValueError('Choose 1..8 distinct integer partition indices')
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA:
        raise ValueError('Partition executor changed after import')
    plan=P.verify(schedule_dir,stop=stop); units=[]; rows=0; chunks=0
    for ordinal,index in enumerate(sorted(indices)):
        materialization=P.materialization_plan(plan,index)
        rows+=sum(w['rows'] for w in materialization['windows']); chunks+=len(M.layout(materialization))
        units.append(dict(partition=index,directory=f'unit-{ordinal:03}',
                          materialization_plan_sha256=materialization['plan_sha256']))
    if rows>M.MAX_ROWS or chunks>M.MAX_CHUNKS:
        raise ValueError('Execution selection exceeds 100000 total rows or 128 chunks')
    value=dict(kind='bounded_partition_execution_request',version=1,schedule_dir=str(Path(schedule_dir).resolve()),
               partition_plan_sha256=plan['partition_plan_sha256'],units=units,selected_rows=rows,selected_chunks=chunks,
               executor_sha256=SOURCE_SHA,inventory_sha256=I.SOURCE_SHA,
               inventory_attempt_limit=MAX_INVENTORY_ATTEMPTS,
               full_tier_generated=False,qualifying=False)
    return dict(value,request_sha256=S.BASE.sha(S.BASE.canonical(value))),plan


def prepare(schedule_dir,output,indices,stop=None):
    if M.fcntl is None:raise ValueError('POSIX file locking is required')
    guard=Guard(Path(output).parent,stop=stop);guard.root=Path(output);guard.check()
    req,plan=request(schedule_dir,indices,guard.callback)
    output=P.isolated_output(output,plan['registration_dir'],R.verify(plan['registration_dir'],stop=guard.callback))
    parent=Path(schedule_dir).resolve()
    if output.is_relative_to(parent) or parent.is_relative_to(output):
        raise ValueError('Keep execution output separate from the partition schedule')
    guard.check(disk=True)
    output.mkdir(mode=0o700); M.sync_directory(output.parent)
    with M.open_file(output/'.lock',True): pass
    with M.locked(output):
        M.atomic_json(output,'request.json',req,exclusive=True)
        cp=dict(request_sha256=req['request_sha256'],units=[dict(partition=u['partition'],inventory_attempt=None,result=None) for u in req['units']])
        M.atomic_json(output,'checkpoint.json',cp,exclusive=True)
    return req


def load_request(root,guard):
    saved=M.read_json(root/'request.json')
    req,plan=request(saved['schedule_dir'],[u['partition'] for u in saved['units']],guard.callback)
    if S.BASE.canonical(req)!=S.BASE.canonical(saved):
        raise ValueError('Execution request/source identity differs')
    # Recheck path isolation on resumed work too.
    P.isolated_output(root,plan['registration_dir'],R.verify(plan['registration_dir'],stop=guard.callback))
    parent=Path(req['schedule_dir'])
    if root.is_relative_to(parent) or parent.is_relative_to(root):
        raise ValueError('Execution output overlaps schedule')
    allowed={'.lock','request.json','checkpoint.json','attempt.json','complete.json','STOP',
             'checkpoint.json.next','attempt.json.next','complete.json.next'}|{u['directory'] for u in req['units']}
    names=set()
    with os.scandir(root) as entries:
        for entry in entries:
            if entry.name not in allowed: raise ValueError('Unexpected execution file')
            if entry.name.startswith('unit-'):
                if not entry.is_dir(follow_symlinks=False): raise ValueError('Execution unit must be a nonsymlink directory')
            else:M.regular(root/entry.name,M.JSON_BYTES if entry.name not in ('.lock','STOP') else 0)
            names.add(entry.name)
    cp=M.read_json(root/'checkpoint.json')
    if (set(cp)!={'request_sha256','units'} or cp['request_sha256']!=req['request_sha256'] or
        type(cp['units']) is not list or len(cp['units'])!=len(req['units'])):
        raise ValueError('Execution checkpoint identity differs')
    for unit,state in zip(req['units'],cp['units']):
        if (type(state) is not dict or set(state)!={'partition','inventory_attempt','result'} or
            type(state['partition']) is not int or state['partition']!=unit['partition'] or
            (state['inventory_attempt'] is not None and (type(state['inventory_attempt']) is not int or not 0<=state['inventory_attempt']<MAX_INVENTORY_ATTEMPTS)) or
            (state['result'] is not None and (type(state['result']) is not dict or state['inventory_attempt'] is None))):
            raise ValueError('Invalid execution unit checkpoint')
        folder=root/unit['directory']
        if folder.exists():
            allowed_unit={'source'}|{f'inventory-{n:03}' for n in range((state['inventory_attempt'] if state['inventory_attempt'] is not None else -1)+1)}
            present=set()
            with os.scandir(folder) as entries:
                for entry in entries:
                    if entry.name not in allowed_unit or not entry.is_dir(follow_symlinks=False):
                        raise ValueError('Unexpected execution unit artifact')
                    present.add(entry.name)
            retained={f'inventory-{n:03}' for n in range(state['inventory_attempt'] or 0)}
            if not retained<=present:raise ValueError('Missing retained inventory attempt')
        elif state['inventory_attempt'] is not None:raise ValueError('Missing execution unit')
    if (root/'complete.json').exists() and any(state['result'] is None for state in cp['units']):
        raise ValueError('Completion receipt contradicts execution checkpoint')
    guard.check(disk=True)
    return req,plan,cp


def source_ready(folder,plan,unit,guard,execute):
    expected=P.materialization_plan(plan,unit['partition']); source=folder/'source'
    if not source.exists():
        if not execute: raise ValueError('Missing source materialization')
        c=plan['controls']
        M.prepare(source,plan['source']['tier'],plan['source']['parameters']['cdm_version'],expected['windows'],
                  chunk_rows=c['chunk_rows'],byte_limit=c['csv_bytes'],seconds=c['invocation_seconds'],min_free=c['min_free_bytes'])
    if M.load_plan(source)!=expected or expected['plan_sha256']!=unit['materialization_plan_sha256']:
        raise ValueError('Unit materialization differs from scheduled work')
    if not (source/'complete.json').exists():
        if not execute: raise ValueError('Source materialization incomplete')
        result=M.run(source,stop=guard.callback)
        if result['status']!='complete':
            if result['status']=='stopped':raise M.Stopped(result['reason'],result['code'])
            raise RuntimeError('Source generation failed: '+result['reason'])
    with M.locked(source) as source:I.verified_source(source,guard)
    return source


def unit_result(req,unit,source,inventory,record):
    complete=M.read_json(source/'complete.json')
    return dict(partition_plan_sha256=req['partition_plan_sha256'],partition=unit['partition'],
                materialization_plan_sha256=unit['materialization_plan_sha256'],
                source_completion_sha256=S.BASE.sha(S.BASE.canonical(complete)),
                inventory_directory=inventory.name,inventory_sha256=S.BASE.sha(S.BASE.canonical(record)),
                source_binding=record['binding'],selected_rows=record['selected_rows'],source_csv_bytes=record['source_csv_bytes'])


def receipt(req,results):
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA:raise ValueError('Partition executor changed after import')
    return dict(kind='bounded_partition_execution_complete',version=1,status='complete',request_sha256=req['request_sha256'],
                partition_plan_sha256=req['partition_plan_sha256'],units=results,
                selected_rows=sum(r['selected_rows'] for r in results),source_csv_bytes=sum(r['source_csv_bytes'] for r in results),
                coverage='selected_partitions_only',full_tier_generated=False,qualifying=False)


def run(output,seconds=120,max_units=MAX_UNITS,retry_incomplete_inventory=False,stop=None):
    if type(max_units) is not int or not 1<=max_units<=MAX_UNITS:raise ValueError('Invocation needs 1..8 unit limit')
    if type(retry_incomplete_inventory) is not bool:raise ValueError('Retry flag must be boolean')
    with M.locked(output) as root:
        guard=Guard(root,seconds,stop)
        try:
            guard.check(disk=True);req,plan,cp=load_request(root,guard);processed=0;results=[]
            for unit,state in zip(req['units'],cp['units']):
                guard.check(disk=True);folder=root/unit['directory']
                if state['result'] is None and processed>=max_units:raise M.Stopped('invocation_unit_limit')
                if not folder.exists():folder.mkdir(mode=0o700);M.sync_directory(root)
                source=source_ready(folder,plan,unit,guard,execute=state['result'] is None)
                if state['inventory_attempt'] is None:
                    state['inventory_attempt']=0;M.atomic_json(root,'checkpoint.json',cp)
                inventory=folder/f"inventory-{state['inventory_attempt']:03}"
                if inventory.exists() and not (inventory/'inventory.json').exists():
                    if not retry_incomplete_inventory or state['result'] is not None:
                        raise ValueError('Incomplete inventory retained; explicitly retry into a new attempt directory')
                    if state['inventory_attempt']+1>=MAX_INVENTORY_ATTEMPTS:raise ValueError('Inventory attempt limit reached')
                    state['inventory_attempt']+=1;M.atomic_json(root,'checkpoint.json',cp)
                    inventory=folder/f"inventory-{state['inventory_attempt']:03}"
                if not inventory.exists():
                    if state['result'] is not None:raise ValueError('Completed inventory is missing')
                    I.collect(source,inventory,stop=guard.callback)
                record=I.verify(source,inventory,stop=guard.callback)
                result=unit_result(req,unit,source,inventory,record)
                if state['result'] is not None and S.BASE.canonical(state['result'])!=S.BASE.canonical(result):
                    raise ValueError('Completed unit identity differs')
                if state['result'] is None:
                    state['result']=result;M.atomic_json(root,'checkpoint.json',cp);processed+=1
                results.append(result)
            value=receipt(req,results);guard.check(disk=True)
            if (root/'complete.json').exists():
                if S.BASE.canonical(M.read_json(root/'complete.json'))!=S.BASE.canonical(value):raise ValueError('Execution completion differs')
            else:M.atomic_json(root,'complete.json',value,exclusive=True)
            return value
        except (Exception,KeyboardInterrupt) as error:
            M.atomic_json(root,'attempt.json',dict(status='stopped' if isinstance(error,(M.Stopped,KeyboardInterrupt)) else 'failed',
                reason=str(error) or 'KeyboardInterrupt',full_tier_generated=False,qualifying=False))
            raise


def verify_locked(root,guard):
    """Caller holds the operation lock; return receipt, request and schedule."""
    guard.check(disk=True);req,plan,cp=load_request(root,guard);results=[]
    for unit,state in zip(req['units'],cp['units']):
        if state['result'] is None:raise ValueError('Execution is not complete')
        folder=root/unit['directory'];source=source_ready(folder,plan,unit,guard,False)
        inventory=folder/f"inventory-{state['inventory_attempt']:03}"
        record=I.verify(source,inventory,stop=guard.callback);result=unit_result(req,unit,source,inventory,record)
        if S.BASE.canonical(state['result'])!=S.BASE.canonical(result):raise ValueError('Completed unit identity differs')
        results.append(result)
    expected=receipt(req,results)
    if S.BASE.canonical(M.read_json(root/'complete.json'))!=S.BASE.canonical(expected):raise ValueError('Execution completion differs')
    guard.check();return expected,req,plan


def verify(output,seconds=120,stop=None):
    with M.locked(output) as root:
        return verify_locked(root,Guard(root,seconds,stop))[0]


def main():
    parser=argparse.ArgumentParser(description=__doc__);commands=parser.add_subparsers(dest='action',required=True)
    create=commands.add_parser('prepare');create.add_argument('--schedule-dir',type=Path,required=True)
    create.add_argument('--partitions',type=int,nargs='+',required=True)
    execute=commands.add_parser('run');execute.add_argument('--max-units',type=int,default=MAX_UNITS)
    execute.add_argument('--retry-incomplete-inventory',action='store_true')
    check=commands.add_parser('verify')
    for command in [create,execute,check]:command.add_argument('--output-dir',type=Path,required=True)
    for command in [execute,check]:command.add_argument('--seconds',type=float,default=120)
    args=parser.parse_args();interrupted=[None]
    def interrupt(signum,frame):interrupted[0]=signal.Signals(signum).name
    old={n:signal.signal(n,interrupt) for n in [signal.SIGINT,signal.SIGTERM]}
    try:
        if args.action=='prepare':value=prepare(args.schedule_dir,args.output_dir,args.partitions,lambda:interrupted[0]);status='prepared'
        elif args.action=='run':value=run(args.output_dir,args.seconds,args.max_units,args.retry_incomplete_inventory,lambda:interrupted[0]);status=value['status']
        else:value=verify(args.output_dir,args.seconds,lambda:interrupted[0]);status=value['status']
        print(json.dumps(dict(status=status,selected_rows=value['selected_rows'],full_tier_generated=False,qualifying=False)));return 0
    except M.Stopped as error:print('Partition execution stopped: '+str(error),file=sys.stderr);return error.code
    except KeyboardInterrupt:print('Partition execution interrupted',file=sys.stderr);return 130
    except (ValueError,OSError,RuntimeError,KeyError,TypeError,sqlite3.Error) as error:
        print('Partition execution refused: '+str(error),file=sys.stderr);return 1
    finally:
        for n,handler in old.items():signal.signal(n,handler)


if __name__=='__main__':raise SystemExit(main())
