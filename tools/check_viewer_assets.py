#!/usr/bin/env python3
"""Check shipped viewer bytes and source provenance without Node or a build."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEWER = ROOT / 'inst/viewer'


def check():
    lock = json.loads((VIEWER / 'viewer-lock.json').read_text())
    assert lock['format_version'] == 1
    assert lock['generated_by'] == 'achilles-next-package-viewer'
    for name, sha in lock['source_sha256'].items():
        path = (ROOT / name).resolve(strict=True)
        assert path.is_relative_to(ROOT)
        assert hashlib.sha256(path.read_bytes()).hexdigest() == sha, f'Viewer source changed: {name}; rebuild packaged assets'
    for name, sha in lock['files'].items():
        path = (VIEWER / name).resolve(strict=True)
        assert path.is_relative_to(VIEWER.resolve())
        assert hashlib.sha256(path.read_bytes()).hexdigest() == sha, f'Viewer asset changed: {name}'
    assert {p.relative_to(VIEWER).as_posix() for p in VIEWER.rglob('*') if p.is_file()} == set(lock['files']) | {'viewer-lock.json'}
    validator = ROOT / 'inst/validation'
    validation_lock = json.loads((validator / 'validator-lock.json').read_text())
    assert validation_lock['format_version'] == 1
    assert hashlib.sha256((validator / 'validate.mjs').read_bytes()).hexdigest() == validation_lock['sha256']
    print('PASS: installed publication validator integrity')
    print(f"PASS: {len(lock['files'])} prebuilt viewer files; {len(lock['source_sha256'])} source fingerprints")


if __name__ == '__main__':
    check()
