"""Create/drop only new marked preview schemas in the existing fixture sandbox."""
from pathlib import Path
import re
import secrets
import shutil
import tempfile
from postgresql_fixtures import guard_database, identifier, literal, grants_sql, MARKER
from synthetic_cdm import verify, DDL, canonical, sha


def load_preview(pg, directory):
    guard_database(pg)
    # Freeze only the bounded replay-checked input; a mutable source cannot be
    # swapped after validation and before frontend COPY reads its files.
    manifest = verify(directory)
    with tempfile.TemporaryDirectory(prefix='achillesnext-cdm-preview-') as folder:
        frozen = Path(folder)
        for name in ['manifest.json']+[t['file'] for t in manifest['tables'].values()]:
            shutil.copyfile(Path(directory)/name, frozen/name)
            (frozen/name).chmod(0o600)
        manifest = verify(frozen)
        if any(c in str(frozen) for c in "'\\\r\n"):
            raise ValueError('Preview COPY path cannot contain quotes, backslashes or newlines')
        schema = 'cdm_synthetic_'+secrets.token_hex(6)
        q = identifier(schema)
        marker = MARKER+': preview:'+sha(canonical(manifest))
        ddl=(DDL/(manifest['parameters']['cdm_version']+'.sql')).read_bytes()
        if sha(ddl)!=manifest['pins']['DDL']:raise ValueError('DDL changed after preview verification')
        commands = ['BEGIN;', "SET LOCAL statement_timeout='30s'; SET LOCAL lock_timeout='2s';",
                    f'CREATE SCHEMA {q}; REVOKE ALL ON SCHEMA {q} FROM PUBLIC; COMMENT ON SCHEMA {q} IS {literal(marker)};',
                    ddl.decode().replace('@cdmDatabaseSchema',q)]
        for table, info in manifest['tables'].items():
            cols = ','.join(identifier(n) for n in info['columns'])
            commands.append(f"\\copy {q}.{identifier(table)} ({cols}) FROM '{frozen/info['file']}' WITH (FORMAT csv, HEADER true, NULL '\\N')")
        commands += [grants_sql(schema), 'COMMIT;']
        # Existing schemas, even marked ones, are refused by CREATE. No reset.
        pg.run('\n'.join(commands))
    return dict(schema=schema,marker=marker,manifest_sha256=sha(canonical(manifest)),
                version=manifest['parameters']['cdm_version'])


def drop_preview(pg, loaded):
    guard_database(pg)
    schema = loaded['schema']
    if not re.fullmatch('cdm_synthetic_[0-9a-f]{12}',schema):
        raise ValueError('Not a generated preview schema')
    found = pg.rows("SELECT obj_description(oid,'pg_namespace') AS marker, "
                    "nspowner=(SELECT oid FROM pg_roles WHERE rolname=current_user) AS owned "
                    f"FROM pg_namespace WHERE nspname={literal(schema)}")
    if found != [dict(marker=loaded['marker'],owned=True)]:
        raise ValueError('Refusing cleanup of unowned/unmarked preview schema')
    pg.run('DROP SCHEMA '+identifier(schema)+' CASCADE;')
