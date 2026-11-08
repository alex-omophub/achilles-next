#!/usr/bin/env python3
"""Mirror admitted synthetic pages behind the shipped view; no generation claim."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from postgresql_fixtures import Postgres, DB, MARKER, identifier, literal, guard_database
from inventory_fixture import canonical, sha
from inventory import measured, protocol_command, require_process_telemetry


def guard_connections(admin, owner):
    if admin.value(f"SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname={literal(DB)}") != MARKER:
        raise RuntimeError('Refusing unmarked synthetic database')
    guard_database(owner) # Resolve and guard the service connection itself.
    identity = "SELECT json_build_object('started',pg_postmaster_start_time()::text,'port',current_setting('port'))::text"
    if json.loads(admin.value(identity)) != json.loads(owner.value(identity)):
        raise ValueError('Admin and owner connections target different PostgreSQL instances')


def reader_host(admin_host, override=None):
    # JDBC requires TCP; preserve a selected TCP host and map socket defaults.
    host = override if override is not None else '127.0.0.1' if admin_host.startswith('/') else admin_host
    if not host or any(c in host for c in '/\\\r\n\x00') or any(c.isspace() for c in host):
        raise ValueError('Reader host must be a TCP hostname or address')
    return host


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--artifact-results', type=Path)
    parser.add_argument('--port', type=int, default=5432)
    parser.add_argument('--admin-host', default='/tmp')
    parser.add_argument('--admin-user')
    parser.add_argument('--reader-host', help='TCP host for JDBC; defaults to admin TCP host or 127.0.0.1 for sockets')
    args = parser.parse_args()
    if not 1 <= args.samples <= 100:
        parser.error('Samples must be 1..100')
    require_process_telemetry()
    host = reader_host(args.admin_host,args.reader_host)
    fixture = args.fixture.resolve(strict=True)
    manifest_raw = (fixture/'fixture.json').read_bytes(); manifest = json.loads(manifest_raw)
    receipt_raw = (fixture/'admission.json').read_bytes(); receipt = json.loads(receipt_raw)
    context = manifest['context']
    if (manifest['fixture'] != 'saved-inventory-v1' or receipt['status'] != 'passed'
            or receipt['fixture_sha256'] != sha(manifest_raw) or receipt['root_sha256'] != context['root']['sha256']):
        raise ValueError('Complete native admission with the exact fixture/root is required')
    artifact_results = json.loads((args.artifact_results or fixture/'run-reads.json').read_bytes())
    if artifact_results['status'] != 'passed' or artifact_results['root_sha256'] != context['root']['sha256']:
        raise ValueError('Matching artifact read proof is required for parity')
    admin = Postgres(args.state.resolve(), admin=True, host=args.admin_host, port=args.port, admin_user=args.admin_user)
    owner = Postgres(args.state.resolve())
    guard_connections(admin,owner)
    output = args.output_dir.resolve(); output.mkdir(mode=0o700)
    token = secrets.token_hex(6); role = 'achilles_inv_reader_'+token
    store = 'inventory_mirror_'+token; serve = 'inventory_serve_'+token
    s = identifier(store); v = identifier(serve); r = identifier(role)
    created = False; schema_created = False
    try:
        password = secrets.token_urlsafe(32)
        admin.run(f'CREATE ROLE {r} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD {literal(password)}')
        created = True
        admin.run(f'GRANT CONNECT ON DATABASE {identifier(DB)} TO {r}')
        # This is a transport-only mirror of a fully admitted synthetic export.
        # It deliberately does not fabricate typed cells, validation of a store,
        # or an execution of the public generation/publication pipeline.
        owner.run(f'''BEGIN; CREATE SCHEMA {s}; CREATE SCHEMA {v};
CREATE TABLE {s}.achillesnext_source_release(source_release_id uuid PRIMARY KEY,source_id text);
CREATE TABLE {s}.achillesnext_analysis_run(run_id uuid PRIMARY KEY,source_release_id uuid,profile_id text,profile_sha256 text);
CREATE TABLE {s}.achillesnext_result_release(release_id uuid PRIMARY KEY,run_id uuid,state text,content_revision bigint);
CREATE TABLE {s}.achillesnext_validation_receipt(receipt_id uuid PRIMARY KEY,release_id uuid,content_revision bigint,profile_sha256 text,passed boolean);
CREATE TABLE {s}.achillesnext_publication(publication_id uuid PRIMARY KEY,release_id uuid,receipt_id uuid,scope_id text,root_sha256 text,state text,approval_id text,approved_at timestamptz);
CREATE TABLE {s}.achillesnext_audience_grant(scope_id text,database_role name,enabled boolean,PRIMARY KEY(scope_id,database_role));
CREATE TABLE {s}.achillesnext_page_object(publication_id uuid,sha256 text,kind text,payload bytea,PRIMARY KEY(publication_id,sha256),CHECK(sha256=encode(sha256(payload),'hex')));
COMMIT;''')
        schema_created = True
        ddl = (Path(__file__).resolve().parents[2]/'inst/sql/postgresql/result-store.sql').read_text()
        view = ddl[ddl.index('CREATE VIEW __SERVE__.achillesnext_approved_pages'):].split(';', 1)[0]+';'
        owner.run(view.replace('__SERVE__', v).replace('__STORE__', s))
        source = '00000000-0000-4000-8000-000000000063'; run = '00000000-0000-4000-8000-000000000064'
        receipt_id = '00000000-0000-4000-8000-000000000065'
        owner.run(f'''BEGIN;
INSERT INTO {s}.achillesnext_source_release VALUES ({literal(source)},{literal(context['source_id'])});
INSERT INTO {s}.achillesnext_analysis_run VALUES ({literal(run)},{literal(source)},{literal(context['profile_id'])},{literal(context['profile_sha256'])});
INSERT INTO {s}.achillesnext_result_release VALUES ({literal(context['release_id'])},{literal(run)},'validated',1);
INSERT INTO {s}.achillesnext_validation_receipt VALUES ({literal(receipt_id)},{literal(context['release_id'])},1,{literal(context['profile_sha256'])},true);
INSERT INTO {s}.achillesnext_publication VALUES ({literal(context['publication_id'])},{literal(context['release_id'])},{literal(receipt_id)},{literal(context['access_scope_id'])},{literal(context['root']['sha256'])},'ready','synthetic-native-artifact-mirror',now()); COMMIT;''')
        total = size = 0; start = time.monotonic()
        # COPY stays bounded by one page; no gigabyte SQL string/Python row map.
        command = owner.args+['-d','service=achilles_next_owner']
        with (output/'copy.log').open('xb') as log:
            process = subprocess.Popen(command, env=owner.env, stdin=subprocess.PIPE, stdout=log, stderr=log)
            try:
                process.stdin.write(f'COPY {s}.achillesnext_page_object FROM STDIN;\n'.encode())
                for path in (fixture/'artifact/objects').iterdir():
                    if not re.fullmatch('[a-f0-9]{64}[.]json',path.name) or path.is_symlink() or not path.is_file():
                        raise ValueError('Unsafe mirror object file')
                    with path.open('rb') as page:
                        raw = page.read(4194305)
                    if len(raw)>4194304:
                        raise ValueError('Mirror page exceeds physical byte limit')
                    if sha(raw) != path.stem:
                        raise ValueError('Mirror object hash mismatch')
                    doc = json.loads(raw)
                    process.stdin.write((context['publication_id']+'\t'+path.stem+'\t'+doc['kind']+'\t\\\\x'+raw.hex()+'\n').encode())
                    total += 1; size += len(raw)
                process.stdin.write(b'\\.\n'); process.stdin.close()
                if process.wait():
                    raise RuntimeError('Synthetic mirror COPY failed; inspect its log')
            except BaseException:
                process.kill();process.wait();raise
        if total != manifest['inventory']['objects'] or size != manifest['inventory']['bytes']:
            raise ValueError('Mirror inventory disagrees with admitted fixture')
        copy_seconds = time.monotonic()-start
        owner.run(f"INSERT INTO {s}.achillesnext_audience_grant VALUES ({literal(context['access_scope_id'])},{literal(role)},true); GRANT USAGE ON SCHEMA {v} TO {r}; GRANT SELECT ON {v}.achillesnext_approved_pages TO {r}")
        privileges = json.loads(owner.value(f"""SELECT json_build_object(
'superuser',(SELECT rolsuper FROM pg_roles WHERE rolname={literal(role)}),
'source_schema_usage',has_schema_privilege({literal(role)},'cdm_tiny_a_55','USAGE'),
'restricted_schema_usage',has_schema_privilege({literal(role)},{literal(store)},'USAGE'),
'serving_schema_usage',has_schema_privilege({literal(role)},{literal(serve)},'USAGE'),
'approved_view_select',has_table_privilege({literal(role)},{literal(serve+'.achillesnext_approved_pages')},'SELECT'))::text"""))
        if privileges != dict(superuser=False,source_schema_usage=False,restricted_schema_usage=False,
                              serving_schema_usage=True,approved_view_select=True):
            raise RuntimeError('Synthetic serving privilege boundary failed')
        errors = []; stop = threading.Event()
        def grants():
            try:
                for name, enabled, signal in [('await-revoke',False,'revoked'),('revocation-checked',True,'restored')]:
                    while not stop.is_set() and not (output/name).exists():
                        stop.wait(0.05)
                    if stop.is_set():
                        return
                    owner.run(f'UPDATE {s}.achillesnext_audience_grant SET enabled={str(enabled).lower()}')
                    (output/signal).touch(exist_ok=False)
            except BaseException as error:
                errors.append(type(error).__name__)
        thread = threading.Thread(target=grants, daemon=True); thread.start()
        with tempfile.TemporaryDirectory(prefix='inventory-reader-') as folder:
            config = Path(folder)/'reader.json';config.touch(mode=0o600)
            config.write_text(json.dumps(dict(database=DB,host=host,user=role,password=password,port=args.port,
                serving_schema=serve,control_dir=str(output))))
            old = os.environ.get('ACHILLES_NEXT_INVENTORY_READER')
            os.environ['ACHILLES_NEXT_INVENTORY_READER'] = str(config)
            try:
                command,env = protocol_command('database',fixture,output/'reads.json',args.samples,output/'protocol')
                result = measured(command,output/'read.log',env)
            finally:
                if old is None:os.environ.pop('ACHILLES_NEXT_INVENTORY_READER',None)
                else:os.environ['ACHILLES_NEXT_INVENTORY_READER']=old
                stop.set();thread.join(timeout=2)
        if errors:
            raise RuntimeError('Synthetic grant coordinator failed')
        database_results = json.loads((output/'reads.json').read_bytes())
        signature = lambda results: [(item['operation'],item['response_sha256']) for item in results['operations']]
        if signature(artifact_results) != signature(database_results):
            raise ValueError('Artifact/database semantic response parity failed')
        (output/'metrics.json').write_bytes(canonical(dict(status='passed',fixture='admitted-page-transport-mirror-not-generation',
            native_receipt_sha256=sha(receipt_raw),shipped_view_sha256=sha(view.encode()),objects=total,bytes=size,
            copy_seconds=copy_seconds,worker=result,artifact_database_response_hashes_equal=True,
            serving_privileges=privileges,provider_source_privileges='none; new role granted only serving schema/view')))
        print('SAVED_INVENTORY_DATABASE_MIRROR_VIEW_ONLY_READS_REVOCATION_OK',flush=True)
    finally:
        if schema_created:owner.run(f'DROP SCHEMA {v} CASCADE; DROP SCHEMA {s} CASCADE')
        if created:
            admin.args[admin.args.index('-d')+1]=DB
            admin.run(f'DROP OWNED BY {r}; DROP ROLE {r}')


if __name__ == '__main__':
    main()
