#!/usr/bin/env python3
"""Opt-in synthetic inventory admission/read experiment; no database or CDM I/O."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time

from inventory_fixture import build, canonical


def measured(command, log, env=None):
    if not hasattr(os, 'wait4'):
        raise RuntimeError('This experiment requires Unix wait4 process telemetry')
    start = time.monotonic()
    with log.open('xb') as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, env=env)
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
    result = dict(command=command, exit_code=process.returncode, elapsed_seconds=time.monotonic()-start,
                  cpu_seconds=usage.ru_utime+usage.ru_stime,
                  peak_process_rss_bytes=usage.ru_maxrss*(1 if sys.platform == 'darwin' else 1024),
                  memory_scope='worker process lifetime peak RSS; R includes its in-process JVM; excludes PostgreSQL and OS cache')
    with log.with_suffix(log.suffix+'.metrics.json').open('xb') as stream:
        stream.write(canonical(result))
    if process.returncode:
        raise RuntimeError(f'Inventory worker failed; inspect {log}')
    return result


def protocol_command(phase, fixture, result, samples, snapshot):
    """Running Rscript streams its input: never execute an actively edited file."""
    snapshot.mkdir(mode=0o700)
    root = Path(__file__).resolve().parents[2]
    for source, name in [('tools/benchmark/inventory.R','inventory.R'),
                         ('tools/benchmark/implementation_identity.R','implementation_identity.R'),
                         ('tests/tracer/inventory-proof.R','inventory-proof.R')]:
        shutil.copy2(root/source,snapshot/name)
    env = os.environ.copy();env['ACHILLES_NEXT_INVENTORY_PROTOCOL_DIR'] = str(snapshot)
    return ['Rscript','--vanilla',str(snapshot/'inventory.R'),phase,str(fixture),str(result),str(samples)],env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['build', 'admit', 'read', 'all'])
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--entries', type=int, default=1_000_000)
    parser.add_argument('--page-rows', type=int, default=512)
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--run-id', default='run')
    args = parser.parse_args()
    if not 1 <= args.samples <= 100 or not args.run_id.replace('-', '').isalnum():
        parser.error('Samples must be 1..100 and run-id must be alphanumeric/hyphen')
    output = args.output_dir.resolve()
    if args.phase in ('build', 'all'):
        start = time.monotonic();manifest = build(output, args.entries, args.page_rows)
        manifest['build_elapsed_seconds'] = time.monotonic()-start
        # Keep the artifact pin separate from measurements. No provider can use
        # this fixture until a complete native admission receipt exists.
        (output/'build.json').write_bytes(canonical(dict(count=args.entries,
            elapsed_seconds=manifest['build_elapsed_seconds'], inventory=manifest['inventory'])))
        print('Built deterministic inventory:', manifest['inventory'], flush=True)
    else:
        manifest = json.loads((output/'fixture.json').read_bytes())
        if manifest['count'] != args.entries:
            parser.error('Entry count disagrees with existing fixture')
    metrics = dict(platform=platform.platform(), python=platform.python_version(),
                   os_cache='uncontrolled; fresh worker is not OS-cold', phases={})
    phases = ['admit', 'read'] if args.phase == 'all' else [args.phase]
    for phase in phases:
        if phase == 'build':
            continue
        result = output/('admission.json' if phase == 'admit' else args.run_id+'-reads.json')
        if result.exists():
            raise ValueError('Worker result must be new: '+str(result))
        command,env = protocol_command(phase,output,result,args.samples,output/(args.run_id+'-'+phase+'-protocol'))
        metrics['phases'][phase] = measured(command, output/(args.run_id+'-'+phase+'.log'),env)
        report = json.loads(result.read_bytes())
        if report.get('status') != 'passed' or report.get('root_sha256') != manifest['context']['root']['sha256']:
            raise ValueError('Worker did not prove the pinned inventory')
        if phase == 'admit':
            if (report['scratch_spools']['concepts']['entries'] != manifest['count']
                    or report['scratch_spools']['rows']['entries'] != manifest['count']+1):
                raise ValueError('Admitted witness inventory differs from fixture')
        print(phase, metrics['phases'][phase], flush=True)
    target = output/(args.run_id+'-'+args.phase+'-metrics.json')
    with target.open('xb') as stream:
        stream.write(canonical(metrics))


if __name__ == '__main__':
    main()
