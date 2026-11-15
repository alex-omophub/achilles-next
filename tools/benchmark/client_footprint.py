#!/usr/bin/env python3
"""Fresh-process, client-only baseline; no database or Docker setup.

Requires an installed AchillesNext matching this checkout. Results and optional
artifact context can be kept outside the checkout. No acceptance budgets implied.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys

from resource_telemetry import directory_bytes, observe


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--repeats', type=int, default=3, choices=range(1, 6))
    parser.add_argument('--artifact', type=Path)
    parser.add_argument('--context', type=Path, help='Exact trusted context JSON for the artifact; requires --artifact')
    parser.add_argument('--rscript', default='Rscript')
    args = parser.parse_args()
    if bool(args.artifact) != bool(args.context):
        parser.error('--artifact and --context must be supplied together')
    root = Path(__file__).resolve().parents[2]
    command = shutil.which(args.rscript)
    if command is None:
        parser.error('Rscript not found; install R and package dependencies first')
    artifact = args.artifact.resolve(strict=True) if args.artifact else None
    context = args.context.resolve(strict=True) if args.context else None
    if artifact and (not artifact.is_dir() or not context.is_file() or context.stat().st_size > 65536):
        parser.error('Artifact directory and context file (at most 64 KiB) required')
    # Never overwrite measurements or put outputs beneath an input artifact.
    output = args.output.resolve()
    if artifact and (output == artifact or artifact in output.parents):
        parser.error('Output must be outside the artifact')
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    files = ['tools/benchmark/'+n for n in ['client_footprint.py','client_footprint.R','resource_telemetry.py','implementation_identity.R']]
    manifest = dict(schema='client-footprint-v1',status='running',scope='fresh owned R process including any in-process JVM; excludes SQL engine and controller',
        platform=platform.platform(),machine=platform.machine(),logical_cpus=os.cpu_count(),
        repeats=args.repeats,qualifying=False,runs=[],
        harness_sha256={p: hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files},
        limits='Diagnostic observer safeguards only; not product hardware or acceptance requirements',
        limitations=['DatabaseConnector::connect sentinel covers measured operations, not a process-wide network sandbox',
                      'No external execution, aggregate export growth, browser heap or SQL-performance qualification',
                      'OS/file caches uncontrolled; fresh R is not a cold filesystem or server'])
    record = output/'manifest.json'
    record.write_text(json.dumps(manifest,indent=2)+'\n')
    for repeat in range(args.repeats):
        for mode in ['plan','primitives'] + (['saved'] if artifact else []):
            name = f'{repeat+1}-{mode}'
            run = output/name
            run.mkdir(); (run/'tmp').mkdir()
            env = dict(os.environ, TMPDIR=str(run/'tmp'))
            try:
                result = observe([command,'--vanilla',str(root/'tools/benchmark/client_footprint.R'),
                    mode,str(root),str(run),str(artifact or ''),str(context or '')],
                    run,env=env,interval=.1,wall_seconds=120,rss_limit=2*1024**3,
                    output_limit=64*1024**2,min_free=64*1024**2)
                manifest['runs'].append(dict(name=name,final_output_bytes=directory_bytes(run),**result))
                if result['status'] != 'completed':
                    raise RuntimeError(f'{name} failed; inspect retained worker.log and telemetry')
            except BaseException as error:
                manifest['status'] = 'failed'
                manifest['error'] = str(error)
                raise
            finally:
                record.write_text(json.dumps(manifest,indent=2)+'\n')
    manifest['status'] = 'completed'
    record.write_text(json.dumps(manifest,indent=2)+'\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
