#!/usr/bin/env python3
"""Run tiny publication/read-role tests in the marked synthetic database only."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
from postgresql_fixtures import Postgres, DB, MARKER, identifier, literal


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--admin-host', default='/tmp')
    parser.add_argument('--admin-user')
    parser.add_argument('--port', type=int, default=5432)
    args = parser.parse_args()
    admin = Postgres(args.state, admin=True, host=args.admin_host, port=args.port, admin_user=args.admin_user)
    if admin.value(f"SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname={literal(DB)}") != MARKER:
        raise RuntimeError('Refusing unmarked database')
    role = 'achilles_test_reader_' + secrets.token_hex(6)
    password = secrets.token_urlsafe(32)
    created = False
    try:
        admin.run(f'BEGIN; CREATE ROLE {identifier(role)} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE '
                  f'NOREPLICATION NOBYPASSRLS PASSWORD {literal(password)}; '
                  f'GRANT CONNECT ON DATABASE {identifier(DB)} TO {identifier(role)}; COMMIT;')
        created = True
        with tempfile.TemporaryDirectory(prefix='achilles-reader-') as folder:
            path = Path(folder) / 'reader.json'
            path.touch(mode=0o600)
            path.write_text(json.dumps({'user': role, 'password': password, 'port': args.port}))
            env = os.environ.copy()
            env['ACHILLES_NEXT_SERVING_FIXTURE'] = str(path)
            env['ACHILLES_NEXT_FIXTURE_STATE'] = str(args.state.resolve())
            test = Path(__file__).resolve().parents[1] / 'tests/tracer/result-export.R'
            subprocess.run(['Rscript', str(test), str(args.config.resolve()), str(args.output_dir.resolve())], env=env, check=True)
    except Exception:
        # No SQL/credential-bearing exception is printed by this admin harness.
        raise RuntimeError('Synthetic serving test failed; inspect the R test output') from None
    finally:
        if created:
            admin.args[admin.args.index('-d')+1] = DB
            admin.run(f'DROP OWNED BY {identifier(role)}; DROP ROLE {identifier(role)};')


if __name__ == '__main__':
    main()
