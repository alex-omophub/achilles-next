"""Freeze a full logical source schedule; emit one bounded selection at a time.

Metadata only: no CSV generation, database access or execution admission.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys

import source_run_registration as R

M=R.M
S=R.S
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())


def controls(rows_per_partition=100000,chunk_rows=10000):
    if (type(rows_per_partition) is not int or not 1<=rows_per_partition<=M.MAX_ROWS or
        type(chunk_rows) is not int or not 1<=chunk_rows<=10000 or
        (rows_per_partition+chunk_rows-1)//chunk_rows>M.MAX_CHUNKS):
        raise ValueError('Partition controls exceed bounded materializer limits')
    return dict(rows_per_partition=rows_per_partition,chunk_rows=chunk_rows,
                csv_bytes=M.MAX_BYTES,invocation_seconds=120.0,min_free_bytes=64*1024**2)


def layout(source,rows_per_partition):
    tables=[]; first=0
    for table,rows in sorted(source['table_rows'].items()):
        count=max(1,(rows+rows_per_partition-1)//rows_per_partition)
        tables.append(dict(table=table,rows=rows,first_partition=first,partitions=count))
        first+=count
    return tables,first


def body(registration,directory,settings):
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA:
        raise ValueError('Partition planner changed after import')
    tables,count=layout(registration['target'],settings['rows_per_partition'])
    return dict(kind='source_partition_plan',version=1,algorithm='contiguous-table-partitions-v1',
                registration_dir=str(directory),registration_sha256=registration['registration_sha256'],
                source=registration['target'],controls=settings,tables=tables,partition_count=count,
                total_rows=sum(t['rows'] for t in tables),
                coverage='full_logical_source_schedule_only',planner_sha256=SOURCE_SHA,
                materializer_sha256=M.SOURCE_SHA,registration_tool_sha256=R.SOURCE_SHA,
                status='planned_not_admitted',execution_enabled=False,
                full_tier_generated=False,qualifying=False)


def record(registration,directory,settings):
    value=body(registration,directory,settings)
    return dict(value,partition_plan_sha256=S.BASE.sha(S.BASE.canonical(value)))


def isolated_output(output,registration_dir,registration):
    output=Path(output)
    if output.is_symlink(): raise ValueError('Partition plan output must not be a symlink')
    output=S.outside(output).resolve()
    inputs=[registration_dir]
    if registration['sample'] is not None:
        inputs.extend(registration['sample'][name] for name in ('source_dir','inventory_dir'))
    for raw in inputs:
        path=Path(raw).resolve()
        if output.is_relative_to(path) or path.is_relative_to(output):
            raise ValueError('Keep partition plan separate from registration/source/inventory')
    return output


def create(registration_dir,output,rows_per_partition=100000,chunk_rows=10000):
    settings=controls(rows_per_partition,chunk_rows)
    registration=R.verify(registration_dir); directory=Path(registration_dir).resolve()
    value=record(registration,directory,settings)
    output=isolated_output(output,directory,registration)
    if shutil.disk_usage(output.parent).free<16*1024**2:
        raise ValueError('Partition plan free-space floor reached')
    output.mkdir(mode=0o700); M.sync_directory(output.parent)
    M.atomic_json(output,'partition-plan.json',value,exclusive=True)
    return value


def verify(output):
    output=Path(output)
    if output.is_symlink(): raise ValueError('Partition plan output must not be a symlink')
    output=S.outside(output).resolve()
    with os.scandir(output) as entries:
        first=next(entries,None); extra=next(entries,None)
        if first is None or first.name!='partition-plan.json' or extra is not None:
            raise ValueError('Unexpected partition plan inventory')
    saved=M.read_json(output/'partition-plan.json')
    directory=Path(saved['registration_dir'])
    registration=R.verify(directory)
    isolated_output(output,directory,registration)
    c=saved['controls']; settings=controls(c['rows_per_partition'],c['chunk_rows'])
    expected=record(registration,directory.resolve(),settings)
    if S.BASE.canonical(saved)!=S.BASE.canonical(expected):
        raise ValueError('Partition plan identity/coverage differs')
    return saved


def partition(plan,index):
    """Random access to a previously verified schedule; no row enumeration."""
    if type(index) is not int or not 0<=index<plan['partition_count']:
        raise ValueError('Partition index outside schedule')
    size=plan['controls']['rows_per_partition']
    for table in plan['tables']:
        offset=index-table['first_partition']
        if 0<=offset<table['partitions']:
            start=offset*size; rows=min(size,table['rows']-start)
            return [dict(table=table['table'],start=start,rows=rows)]
    raise ValueError('Partition not covered by table layout')


def materialization_plan(plan,index):
    """Return the exact existing bounded-materializer plan for this work unit."""
    c=plan['controls']; source=plan['source']
    value=M.build_plan(source['tier'],source['parameters']['cdm_version'],partition(plan,index),
                       c['chunk_rows'],c['csv_bytes'],c['invocation_seconds'],c['min_free_bytes'])
    if S.BASE.canonical(value['source'])!=S.BASE.canonical(source):
        raise ValueError('Partition source changed before handoff')
    return value


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    commands=parser.add_subparsers(dest='action',required=True)
    create_parser=commands.add_parser('create')
    create_parser.add_argument('--registration-dir',type=Path,required=True)
    create_parser.add_argument('--rows-per-partition',type=int,default=100000)
    create_parser.add_argument('--chunk-rows',type=int,default=10000)
    commands.add_parser('verify')
    selection=commands.add_parser('selection'); selection.add_argument('--partition',type=int,required=True)
    for command in [create_parser,commands.choices['verify'],selection]:
        command.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args()
    try:
        if args.action=='create': plan=create(args.registration_dir,args.output_dir,args.rows_per_partition,args.chunk_rows)
        else: plan=verify(args.output_dir)
        if args.action=='selection':
            # Also check the unchanged materializer accepts the work unit and pins.
            value=materialization_plan(plan,args.partition)['windows']
        else:
            value=dict(status=plan['status'],partition_plan_sha256=plan['partition_plan_sha256'],
                       tables=len(plan['tables']),partitions=plan['partition_count'],rows=plan['total_rows'],
                       execution_enabled=False,qualifying=False)
        print(json.dumps(value,sort_keys=True)); return 0
    except M.Stopped as error:
        print('Partition planning stopped: '+str(error),file=sys.stderr); return error.code
    except KeyboardInterrupt:
        print('Partition planning interrupted',file=sys.stderr); return 130
    except (ValueError,OSError,KeyError,TypeError,sqlite3.Error) as error:
        print('Partition planning refused: '+str(error),file=sys.stderr); return 1


if __name__=='__main__': raise SystemExit(main())
