"""Copy verified bounded partitions, inventory their union and load one fixture schema."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys

import partition_execution as E
import bounded_source_loader as L

R=E.R
I=E.I
M=E.M
S=E.S
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())


def pins():
    modules=[E,E.P,R,I,M,S]
    for module in modules:
        if S.BASE.sha(Path(module.__file__).read_bytes())!=module.SOURCE_SHA:
            raise ValueError('Shared-load dependency changed after import')
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA:
        raise ValueError('Shared loader changed after import')
    return dict(shared_loader=SOURCE_SHA,executor=E.SOURCE_SHA,planner=E.P.SOURCE_SHA,
                registration=R.SOURCE_SHA,inventory=I.SOURCE_SHA,materializer=M.SOURCE_SHA,loader=L.pins())


def isolated_output(output,execution,plan):
    output=Path(output)
    if output.is_symlink():raise ValueError('Shared load output must not be a symlink')
    output=S.outside(output).resolve()
    registration=M.read_json(Path(plan['registration_dir'])/'registration.json')['request']
    inputs=[execution,plan['registration_dir'],registration['sample_source'],registration['sample_inventory']]
    for raw in inputs:
        if raw is None:continue
        path=Path(raw).resolve()
        if output.is_relative_to(path) or path.is_relative_to(output):raise ValueError('Keep shared output separate from execution and registered inputs')
    return output


def merged_plan(execution,request,plan):
    windows=[];byte_count=0
    for unit in request['units']:
        source=execution/unit['directory']/'source'
        windows.extend(M.load_plan(source)['windows'])
        byte_count+=M.read_json(source/'complete.json')['csv_bytes']
    if byte_count>M.MAX_BYTES:raise ValueError('Combined selection exceeds 64 MiB CSV budget')
    c=plan['controls'];source=plan['source']
    combined=M.build_plan(source['tier'],source['parameters']['cdm_version'],windows,
                          c['chunk_rows'],c['csv_bytes'],c['invocation_seconds'],c['min_free_bytes'])
    return combined,byte_count


def copy_sources(execution,request,proof,target,combined,guard):
    """No generation: exclusively copy committed files and replay the new selection."""
    c=combined['limits'];source=combined['source']
    prepared=M.prepare(target,source['tier'],source['parameters']['cdm_version'],combined['windows'],
                       chunk_rows=combined['chunk_rows'],byte_limit=c['csv_bytes'],seconds=c['invocation_seconds'],min_free=c['min_free_bytes'])
    if S.BASE.canonical(prepared)!=S.BASE.canonical(combined):raise ValueError('Combined materialization plan changed')
    with M.locked(target) as target:
        if M.read_json(target/'checkpoint.json')!=M.checkpoint(combined,[]):raise ValueError('Combined source was modified before copy')
        descriptions=M.layout(combined);copied=[];inodes={}
        for unit,saved in zip(request['units'],proof['units']):
            with M.locked(execution/unit['directory']/'source') as original:
                unit_plan,complete,_=I.verified_source(original,guard)
                if S.BASE.canonical(I.binding(unit_plan,complete))!=S.BASE.canonical(saved['source_binding']):
                    raise ValueError('Execution unit binding changed before copy')
                for chunk in complete['chunks']:
                    guard.check(disk=True)
                    if len(copied)>=len(descriptions):raise ValueError('Too many source chunks')
                    desc=descriptions[len(copied)]
                    if any(desc[k]!=chunk[k] for k in ('table','start','rows')):raise ValueError('Combined chunk order differs')
                    st=M.regular(original/chunk['file'],S.MAX_BYTES,(1,2));inode=(st.st_dev,st.st_ino)
                    if inode in inodes:os.link(target/inodes[inode],target/desc['file'],follow_symlinks=False)
                    else:
                        size=0
                        with M.open_file(original/chunk['file']) as reader,M.open_file(target/desc['file'],True) as writer:
                            while True:
                                guard.check(disk=True);raw=reader.read(min(65536,chunk['bytes']-size+1))
                                if not raw:break
                                size+=len(raw)
                                if size>chunk['bytes']:raise ValueError('Source grew during copy')
                                writer.write(raw)
                            writer.flush();os.fsync(writer.fileno())
                        if size!=chunk['bytes']:raise ValueError('Source shrank during copy')
                        inodes[inode]=desc['file']
                    copied.append(dict(desc,**{k:chunk[k] for k in ['bytes','sha256','row_bytes_min','row_bytes_max','null_counts']}))
        if len(copied)!=len(descriptions):raise ValueError('Combined source is incomplete')
        cp=M.checkpoint(combined,copied);M.atomic_json(target,'checkpoint.json',cp)
        M.atomic_json(target,'complete.json',M.receipt(combined,cp),exclusive=True)
        _,complete,_=I.verified_source(target,guard)
        return complete


def load(execution_dir,output,state_dir,seconds=120,stop=None):
    output=Path(output);guard=E.Guard(Path(execution_dir),seconds,stop=stop)
    guard.paths.append(output.parent);guard.check(disk=True)
    identity=pins();created=False;committed=False;stage='verify_execution'
    try:
        with M.locked(execution_dir) as execution:
            guard.root=execution;guard.paths[0]=execution
            proof,request,plan=E.verify_locked(execution,guard)
            output=isolated_output(output,execution,plan)
            schedule=Path(request['schedule_dir'])
            if output.is_relative_to(schedule) or schedule.is_relative_to(output):raise ValueError('Shared load output overlaps schedule')
            combined,byte_count=merged_plan(execution,request,plan)
            guard.check(disk=True)
            if shutil.disk_usage(output.parent).free<byte_count+guard.controls['min_free_bytes']:
                raise ValueError('Insufficient space for combined source plus floor')
            output.mkdir(mode=0o700);created=True;M.sync_directory(output.parent)
            with M.open_file(output/'.lock',True):pass
            # Retain the input lock through the copy. The output lock is held
            # across all subsequent stages, including the owned database loader.
            with M.locked(output):
                binding=dict(kind='bounded_partition_shared_load_binding',version=1,execution_dir=str(execution),
                    execution_request_sha256=request['request_sha256'],execution_completion_sha256=S.BASE.sha(S.BASE.canonical(proof)),
                    partition_plan_sha256=proof['partition_plan_sha256'],units=proof['units'],combined_plan_sha256=combined['plan_sha256'],
                    code=identity,whole_source_loaded=False,full_tier_generated=False,qualifying=False)
                binding=dict(binding,binding_sha256=S.BASE.sha(S.BASE.canonical(binding)))
                M.atomic_json(output,'binding.json',binding,exclusive=True);stage='copy_sources'
                guard.paths.append(output)
                complete=copy_sources(execution,request,proof,output/'source',combined,guard)
                # Cooperative execution remains locked while the snapshot is
                # assembled; collection and loading below consume this new copy.
                stage='inventory'
                inventory=I.collect(output/'source',output/'inventory',seconds=seconds,
                                    min_free=guard.controls['min_free_bytes'],stop=guard.callback)
                stage='registration'
                registration=R.register(output/'registration','shared-'+binding['binding_sha256'][:24],
                    combined['source']['tier'],combined['source']['parameters']['cdm_version'],
                    {r:str(output) for r in R.ROLES},output/'source',output/'inventory',stop=guard.callback)
                guard.check(disk=True)
                if pins()!=identity:raise ValueError('Shared-load code changed before database work')
                stage='database_load'
                loaded=L.load(output/'registration',output/'load',state_dir,seconds=seconds,stop=guard.callback)
                committed=True;stage='receipt';guard.check(disk=True)
                if pins()!=identity:raise ValueError('Shared-load code changed during database work')
                result=dict(kind='bounded_partition_shared_load',version=1,status='complete',binding_sha256=binding['binding_sha256'],
                    execution_completion_sha256=binding['execution_completion_sha256'],combined_plan_sha256=combined['plan_sha256'],
                    inventory_sha256=S.BASE.sha(S.BASE.canonical(inventory)),registration_sha256=registration['registration_sha256'],
                    load_receipt_sha256=S.BASE.sha(S.BASE.canonical(loaded)),schema=loaded['request']['schema'],
                    rows=complete['rows'],csv_bytes=complete['csv_bytes'],coverage='selected_partitions_only',
                    whole_source_loaded=False,full_tier_generated=False,qualifying=False)
                M.atomic_json(output,'complete.json',result,exclusive=True);return result
    except (Exception,KeyboardInterrupt) as error:
        if created:
            outcome='committed' if committed else 'unknown' if stage=='database_load' else 'not_attempted'
            if stage=='database_load' and (output/'load/attempt.json').exists():
                try:outcome=M.read_json(output/'load/attempt.json')['commit_outcome']
                except (ValueError,OSError,KeyError,TypeError):pass
            M.atomic_json(output,'attempt.json',dict(status='stopped' if isinstance(error,(M.Stopped,KeyboardInterrupt)) else 'failed',
                stage=stage,reason=str(error) or 'KeyboardInterrupt',commit_outcome=outcome,
                whole_source_loaded=False,full_tier_generated=False,qualifying=False))
        raise


def drop(output,state_dir,seconds=30,stop=None):
    """Cleanup uses saved identity, even if original inputs/code were archived."""
    with M.locked(output) as root:
        binding=M.read_json(root/'binding.json')
        unsigned={k:v for k,v in binding.items() if k!='binding_sha256'}
        if (binding.get('kind')!='bounded_partition_shared_load_binding' or
            type(binding.get('version')) is not int or binding['version']!=1 or
            binding.get('binding_sha256')!=S.BASE.sha(S.BASE.canonical(unsigned))):
            raise ValueError('Invalid shared-load binding')
        child=root/'load'
        if child.is_symlink():raise ValueError('Shared child load must not be a symlink')
        request=M.read_json(child/'request.json')
        if request['source_binding']['plan_sha256']!=binding['combined_plan_sha256']:
            raise ValueError('Child load differs from combined source binding')
        return L.drop(state_dir,child,seconds,stop)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['load','drop'])
    parser.add_argument('--execution-dir',type=Path);parser.add_argument('--output-dir',type=Path,required=True)
    parser.add_argument('--state-dir',type=Path,required=True);parser.add_argument('--seconds',type=float,default=120)
    args=parser.parse_args();interrupted=[None]
    if args.action=='load' and args.execution_dir is None:parser.error('load requires execution-dir')
    if args.action=='drop' and args.execution_dir is not None:parser.error('drop uses the saved shared-load binding')
    def interrupt(signum,frame):interrupted[0]=signal.Signals(signum).name
    old={n:signal.signal(n,interrupt) for n in [signal.SIGINT,signal.SIGTERM]}
    try:
        if args.action=='load':result=load(args.execution_dir,args.output_dir,args.state_dir,args.seconds,lambda:interrupted[0])
        else:result=drop(args.output_dir,args.state_dir,args.seconds,lambda:interrupted[0])
        print(json.dumps(dict(status=result['status'],schema=result['schema'],qualifying=False)));return 0
    except M.Stopped as error:print('Shared load stopped: '+str(error),file=sys.stderr);return error.code
    except KeyboardInterrupt:print('Shared load interrupted',file=sys.stderr);return 130
    except (ValueError,OSError,RuntimeError,KeyError,TypeError,sqlite3.Error,subprocess.SubprocessError) as error:
        print('Shared load refused: '+str(error),file=sys.stderr);return 1
    finally:
        for n,handler in old.items():signal.signal(n,handler)


if __name__=='__main__':raise SystemExit(main())
