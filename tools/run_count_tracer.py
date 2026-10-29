#!/usr/bin/env python3
"""Developer-only R -> validated partial bundle -> React build command."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True, help='Trusted local R configuration defining config')
    parser.add_argument('--output', type=Path, required=True, help='New bundle directory under an existing parent')
    parser.add_argument('--serve', action='store_true', help='Run the loopback Vite developer server after validation/build')
    args = parser.parse_args()
    config, output = args.config.resolve(strict=True), args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error('Output must be a new directory')
    with tempfile.TemporaryDirectory(prefix='achilles-next-r-') as library:
        subprocess.run(['R', 'CMD', 'INSTALL', '--library=' + library, str(ROOT)], check=True)
        env = dict(os.environ)
        env['R_LIBS'] = library + os.pathsep + env.get('R_LIBS', '')
        subprocess.run(['Rscript', str(ROOT / 'tools/count_tracer.R'), str(config), str(output)], env=env, check=True)
        subprocess.run(['node', 'packages/contracts/tools/validate.mjs', str(output)], cwd=ROOT, check=True)
        subprocess.run(['npm', 'run', 'build', '--prefix', 'packages/tracer'], cwd=ROOT, check=True)
    print(f'Validated partial tracer bundle: {output}', flush=True)
    print('In the React tracer, choose this bundle folder.', flush=True)
    viewer_call = f'AchillesNext::viewResults({json.dumps(str(output), ensure_ascii=False)})'
    print(f'With AchillesNext installed in your R library, open it with {viewer_call}.', flush=True)
    if args.serve:
        subprocess.run(['npm', 'run', 'dev', '--prefix', 'packages/tracer'], cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
