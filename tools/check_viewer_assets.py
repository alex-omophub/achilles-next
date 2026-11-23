#!/usr/bin/env python3
"""Check shipped viewer bytes and source provenance without Node or a build."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check_distribution(name):
    folder = ROOT / 'inst' / name
    manifest = name + '-lock.json'
    lock = json.loads((folder / manifest).read_text())
    assert lock['format_version'] == 1
    assert lock['generated_by'] == 'achilles-next-package-' + name
    for file, sha in lock['source_sha256'].items():
        path = (ROOT / file).resolve(strict=True)
        assert path.is_relative_to(ROOT)
        assert hashlib.sha256(path.read_bytes()).hexdigest() == sha, f'{name} source changed: {file}; rebuild packaged assets'
    for file, sha in lock['files'].items():
        path = (folder / file).resolve(strict=True)
        assert path.is_relative_to(folder.resolve())
        assert hashlib.sha256(path.read_bytes()).hexdigest() == sha, f'{name} asset changed: {file}'
    assert {p.relative_to(folder).as_posix() for p in folder.rglob('*') if p.is_file()} == set(lock['files']) | {manifest}
    print(f"PASS: {len(lock['files'])} prebuilt {folder.name} files; {len(lock['source_sha256'])} source fingerprints")


def check():
    check_distribution('viewer')
    check_distribution('embed')
    validator = ROOT / 'inst/validation'
    validation_lock = json.loads((validator / 'validator-lock.json').read_text())
    assert validation_lock['format_version'] == 1
    assert hashlib.sha256((validator / 'validate.mjs').read_bytes()).hexdigest() == validation_lock['sha256']
    print('PASS: installed publication validator integrity')


if __name__ == '__main__':
    check()
