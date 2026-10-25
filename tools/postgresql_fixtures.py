#!/usr/bin/env python3
"""Rebuild isolated synthetic OMOP fixtures using psql and the Python stdlib."""

import argparse
import csv
from decimal import Decimal
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures/postgresql"
LOCK = json.loads((FIXTURES / "lock.json").read_text())
DB = "achilles_next_fixtures"
OWNER = "achilles_next_fixture_owner"
RUNNER = "achilles_next_runner"
MARKER = "AchillesNext synthetic fixture sandbox v1"
VERSIONS = ("5.3", "5.4", "5.5")


def identifier(value):
    if not re.fullmatch(r"[a-z_][a-z_0-9]*", value):
        raise ValueError(f"Invalid SQL identifier: {value!r}")
    return '"' + value + '"'


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


class Postgres:
    def __init__(self, state, admin=False, host="/tmp", port=5432, admin_user=None):
        self.state = state
        self.admin = admin
        self.args = ["psql", "-X", "-w", "-q", "-v", "ON_ERROR_STOP=1", "-A", "-t"]
        self.env = os.environ.copy()
        # Explicit targets; never inherit an unrelated PGDATABASE/PGSERVICE.
        for key in ("PGDATABASE", "PGSERVICE", "PGOPTIONS", "PGHOST", "PGPORT", "PGUSER", "PGPASSWORD"):
            self.env.pop(key, None)
        self.env["PGCLIENTENCODING"] = "UTF8"
        self.env["PGOPTIONS"] = "-c timezone=UTC -c datestyle=ISO,YMD -c standard_conforming_strings=on"
        if admin:
            self.args += ["-h", host, "-p", str(port), "-d", "postgres"]
            if admin_user:
                self.args += ["-U", admin_user]
        else:
            self.env["PGSERVICEFILE"] = str(state / "pg_service.conf")
            self.env["PGPASSFILE"] = str(state / "pgpass")

    def run(self, sql, role="owner", allow_failure=False):
        args = self.args if self.admin else self.args + ["-d", f"service=achilles_next_{role}"]
        result = subprocess.run(args, input=sql, text=True, env=self.env, capture_output=True)
        if result.returncode and not allow_failure:
            # Error messages may contain SQL fragments. Never print role passwords.
            message = result.stderr.strip()
            passfile = self.state / "pgpass"
            if passfile.exists():
                for line in passfile.read_text().splitlines():
                    message = message.replace(line.rsplit(":", 1)[-1], "[redacted]")
            raise RuntimeError(message or "psql failed")
        return result

    def value(self, sql, role="owner"):
        return self.run(sql, role).stdout.strip()

    def rows(self, sql, role="owner"):
        return json.loads(self.value(f"SELECT COALESCE(json_agg(q), '[]'::json) FROM ({sql}) q;", role))


def check_versions(pg, allow_mismatch):
    server = pg.value("SHOW server_version;")
    client = subprocess.check_output(["psql", "--version"], text=True).strip()
    client_version = re.search(r"PostgreSQL\) (\d+\.\d+)", client).group(1)
    server_version = server.split()[0]
    matched = server_version == LOCK["postgresql_server"] and client_version == LOCK["psql_client"]
    if not matched and not allow_mismatch:
        raise ValueError(f"Version mismatch: server {server_version}, client {client_version}; "
                         f"locked {LOCK['postgresql_server']}/{LOCK['psql_client']}. "
                         "Use --allow-version-mismatch for an explicitly unpinned run.")
    return {"server": server, "psql": client, "matches_lock": matched,
            "python": sys.version.split()[0], "transport": LOCK["transport"]}


def write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(text)


def provision(args):
    state = args.state_dir
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    if state.stat().st_mode & 0o077:
        raise ValueError("State directory must be private (chmod 700)")
    admin = Postgres(state, admin=True, host=args.host, port=args.port, admin_user=args.admin_user)
    versions = check_versions(admin, args.allow_version_mismatch)
    services = "".join(
        f"[achilles_next_{role}]\nhost={args.host}\nport={args.port}\ndbname={DB}\nuser={name}\n\n"
        for role, name in (("owner", OWNER), ("runner", RUNNER)))
    passwords = {}
    if (state / "pgpass").exists():
        for line in (state / "pgpass").read_text().splitlines():
            fields = line.split(":")
            if len(fields) != 5 or fields[:3] != [args.host, str(args.port), DB]:
                raise ValueError("Saved connection target differs; use the original host/port and state directory")
            passwords[fields[3]] = fields[4]
        if set(passwords) != {OWNER, RUNNER}:
            raise ValueError("Unexpected credential file; refusing to replace credentials")
        for name in ("pgpass", "pg_service.conf"):
            if (state / name).stat().st_mode & 0o077:
                raise ValueError(f"{name} must have mode 600")
        if (state / "pg_service.conf").read_text() != services:
            raise ValueError("Saved connection services differ; refusing to change the target")
    else:
        # Do not take over existing roles, even if they happen to share our names.
        if admin.value(f"SELECT count(*) FROM pg_roles WHERE rolname IN ({literal(OWNER)}, {literal(RUNNER)});") != "0":
            raise ValueError("Fixture roles already exist without this local state; refusing takeover")
        passwords = {name: secrets.token_urlsafe(32) for name in (OWNER, RUNNER)}
        write_private(state / "pgpass", "".join(f"{args.host}:{args.port}:{DB}:{name}:{password}\n" for name, password in passwords.items()))
        write_private(state / "pg_service.conf", services)
    for name in (OWNER, RUNNER):
        existing = admin.rows(f"SELECT r.rolname, r.rolsuper, r.rolcreatedb, r.rolcreaterole, r.rolreplication, "
                              f"r.rolbypassrls, r.rolcanlogin, shobj_description(r.oid, 'pg_authid') AS marker "
                              f"FROM pg_roles r WHERE rolname={literal(name)}")
        if existing:
            r = existing[0]
            if (r["marker"] != MARKER or any(r[k] for k in ("rolsuper", "rolcreatedb", "rolcreaterole", "rolreplication", "rolbypassrls")) or not r["rolcanlogin"]):
                raise ValueError(f"Unexpected attributes/ownership for role {name}")
        else:
            admin.run(f"BEGIN; CREATE ROLE {identifier(name)} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE "
                      f"NOREPLICATION NOBYPASSRLS PASSWORD {literal(passwords[name])}; "
                      f"COMMENT ON ROLE {identifier(name)} IS {literal(MARKER)}; COMMIT;")
    databases = admin.rows(f"SELECT d.datname, shobj_description(d.oid, 'pg_database') AS marker "
                           f"FROM pg_database d WHERE datname={literal(DB)}")
    if databases and databases[0]["marker"] != MARKER:
        raise ValueError("Database already exists without fixture marker; refusing takeover")
    if not databases:
        admin.run(f"CREATE DATABASE {identifier(DB)} OWNER {identifier(OWNER)} ENCODING 'UTF8' TEMPLATE template0;")
        admin.run(f"COMMENT ON DATABASE {identifier(DB)} IS {literal(MARKER)};")
    admin.run(f"REVOKE ALL ON DATABASE {identifier(DB)} FROM PUBLIC; "
              f"GRANT CONNECT ON DATABASE {identifier(DB)} TO {identifier(RUNNER)};")
    pg = Postgres(state)
    guard_database(pg)
    pg.run("REVOKE ALL ON SCHEMA public FROM PUBLIC;")
    existing = pg.rows("SELECT obj_description(oid, 'pg_namespace') AS marker, "
                       "nspowner=(SELECT oid FROM pg_roles WHERE rolname=current_user) AS owned "
                       "FROM pg_namespace WHERE nspname='fixture_results'")
    if existing and existing != [{"marker": MARKER, "owned": True}]:
        raise ValueError("Unexpected results schema; refusing takeover")
    pg.run(f"CREATE SCHEMA IF NOT EXISTS fixture_results; "
           f"COMMENT ON SCHEMA fixture_results IS {literal(MARKER)}; "
           f"REVOKE ALL ON SCHEMA fixture_results FROM PUBLIC; "
           f"GRANT USAGE, CREATE ON SCHEMA fixture_results TO {identifier(RUNNER)};")
    return pg, versions


def guard_database(pg):
    result = pg.rows("SELECT current_database() AS db, current_user AS usr, "
                     "shobj_description(oid, 'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
    if result != [{"db": DB, "usr": OWNER, "marker": MARKER}]:
        raise ValueError("Connection is not the owned, marked fixture sandbox")


def check_sources():
    for name, sha in LOCK["cdm"]["files"].items():
        if digest((FIXTURES / "ddl" / name).read_bytes()) != sha:
            raise ValueError(f"DDL checksum mismatch: {name}")


def archive_path(state, version, download):
    asset = LOCK["gibleed"]["assets"][version]
    cache = state / "cache"
    cache.mkdir(exist_ok=True)
    path = cache / asset["filename"]
    if not path.exists():
        if not download:
            raise ValueError(f"Missing {asset['filename']}; use setup --with-gibleed to download")
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as stream:
            temp = Path(stream.name)
            try:
                with urllib.request.urlopen(asset["url"], timeout=60) as response:
                    shutil.copyfileobj(response, stream)
            except Exception:
                temp.unlink(missing_ok=True)
                raise
        if digest(temp.read_bytes()) != asset["sha256"]:
            temp.unlink()
            raise ValueError(f"Downloaded archive checksum mismatch: {version}")
        temp.replace(path)
    if digest(path.read_bytes()) != asset["sha256"]:
        raise ValueError(f"Cached archive checksum mismatch: {version}")
    return path


def schema_name(source, version):
    if source not in ("tiny_a", "tiny_b", "gibleed", "synpuf") or version not in VERSIONS:
        raise ValueError("Unknown fixture source or CDM version")
    if source in ("gibleed", "synpuf") and version == "5.4":
        raise ValueError("No 5.4 external dataset is declared")
    return f"cdm_{source}_{version.replace('.', '')}"


def create_schema_sql(schema, version, reset):
    q = identifier(schema)
    marker = f"{MARKER}: {schema}"
    guard = f"""DO $guard$ BEGIN
IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname={literal(schema)} AND
 (obj_description(oid, 'pg_namespace') IS DISTINCT FROM {literal(marker)} OR
  nspowner <> (SELECT oid FROM pg_roles WHERE rolname=current_user))) THEN
 RAISE EXCEPTION 'Refusing to replace an unowned or unmarked schema';
END IF; END $guard$;
"""
    if not reset:
        # An existing SynPUF schema is never reset, reloaded, or hashed by this tool.
        return guard
    ddl = (FIXTURES / "ddl" / f"{version}.sql").read_text()
    keys = (FIXTURES / "ddl" / f"{version}-primary-keys.sql").read_text()
    # GiBleed 5.3 contains repeated source IDs. Preserve the published records;
    # do not deduplicate them or claim PK/FK conformance for the external dataset.
    if schema == "cdm_gibleed_53":
        keys = ""
    return (guard + f"DROP SCHEMA IF EXISTS {q} CASCADE; CREATE SCHEMA {q}; "
            f"COMMENT ON SCHEMA {q} IS {literal(marker)};\n" +
            ddl.replace("@cdmDatabaseSchema", q) + keys.replace("@cdmDatabaseSchema", q))


def grants_sql(schema):
    q = identifier(schema)
    return (f"REVOKE ALL ON SCHEMA {q} FROM PUBLIC; GRANT USAGE ON SCHEMA {q} TO {identifier(RUNNER)}; "
            f"GRANT SELECT ON ALL TABLES IN SCHEMA {q} TO {identifier(RUNNER)}; "
            f"ALTER DEFAULT PRIVILEGES IN SCHEMA {q} GRANT SELECT ON TABLES TO {identifier(RUNNER)};\n")


def copy_sql(schema, table, columns, rows):
    # Quote every non-null field. Empty strings and SQL NULL remain distinct.
    out = io.StringIO()
    out.write(f"COPY {identifier(schema)}.{identifier(table)} ({','.join(map(identifier, columns))}) "
              "FROM STDIN WITH (FORMAT CSV, NULL '\\N');\n")
    for row in rows:
        if len(row) != len(columns):
            raise ValueError(f"Unexpected CSV width in {table}")
        out.write(",".join("\\N" if value is None else '"' + str(value).replace('"', '""') + '"' for value in row) + "\n")
    out.write("\\.\n")
    return out.getvalue()


def tiny_data(source, version):
    data = json.loads((FIXTURES / "tiny.json").read_text())
    common = data["common"]
    result = {table: list(rows) for table, rows in common.items()}
    result.update(data["sources"][source])
    if version != "5.3":
        result.update(data["additions"]["5.4"][source])
    if version == "5.5":
        result.update(data["additions"]["5.5"][source])
    row = {"cdm_source_name": f"AchillesNext synthetic {source}", "cdm_source_abbreviation": source,
           "cdm_holder": "Synthetic fixture", "source_release_date": "2020-01-01",
           "cdm_release_date": "2020-01-01", "cdm_version": version, "vocabulary_version": "fixture-1"}
    if version != "5.3":
        row["cdm_version_concept_id"] = 0
    if version == "5.5":
        row["cdm_release_identifier"] = f"fixture-1-{source}"
    result["cdm_source"] = [row]
    return result


def tiny_sql(schema, source, version):
    sql = []
    for table, rows in tiny_data(source, version).items():
        if not rows:
            continue
        columns = sorted({key for row in rows for key in row})
        sql.append(copy_sql(schema, table, columns, ([row.get(key) for key in columns] for row in rows)))
    return "".join(sql)


def gibleed_sql(schema, version, archive):
    sql = []
    counts = {}
    with zipfile.ZipFile(archive) as zipped:
        if sum(info.file_size for info in zipped.infolist()) > 100_000_000:
            raise ValueError("Unexpected uncompressed archive size")
        for name in sorted(zipped.namelist()):
            if name.startswith("__MACOSX/") or not name.lower().endswith(".csv"):
                continue
            table = Path(name).stem.lower()
            if table in counts:
                raise ValueError(f"Duplicate CSV table: {table}")
            with zipped.open(name) as stream:
                reader = csv.reader(io.TextIOWrapper(stream, encoding="utf-8-sig", newline=""))
                columns = [column.lower() for column in next(reader)]
                # Upstream uses empty cells for missing values. Preserve all nonempty cells.
                rows = [[None if cell == "" else cell for cell in row] for row in reader]
            counts[table] = len(rows)
            if version == "5.3" and table in ("cohort", "cohort_attribute"):
                if rows:
                    raise ValueError("Unexpected populated legacy extension table")
                continue
            sql.append(copy_sql(schema, table, columns, rows))
    if counts != LOCK["gibleed"]["assets"][version]["row_counts"]:
        raise ValueError("Archive table/row counts differ from the lock")
    return "".join(sql)


def reset_fixtures(pg, state, with_gibleed, download=False, prepare_synpuf=False):
    guard_database(pg)
    check_sources()
    archives = {v: archive_path(state, v, download) for v in ("5.3", "5.5")} if with_gibleed else {}
    parts = ["BEGIN; SELECT pg_advisory_xact_lock(1702, 1);\n"]
    for source in ("tiny_a", "tiny_b"):
        for version in VERSIONS:
            schema = schema_name(source, version)
            parts += [create_schema_sql(schema, version, True), tiny_sql(schema, source, version), grants_sql(schema)]
    for version, archive in archives.items():
        schema = schema_name("gibleed", version)
        parts += [create_schema_sql(schema, version, True), gibleed_sql(schema, version, archive), grants_sql(schema)]
    if prepare_synpuf:
        for version in ("5.3", "5.5"):
            schema = schema_name("synpuf", version)
            exists = pg.value(f"SELECT count(*) FROM pg_namespace WHERE nspname={literal(schema)};") != "0"
            parts += [create_schema_sql(schema, version, not exists), grants_sql(schema)]
    parts += ["COMMIT;\n"]
    pg.run("".join(parts))


def schema_inventory(pg, schema):
    return pg.rows("SELECT table_name, column_name, data_type, is_nullable, ordinal_position, "
                   "character_maximum_length, numeric_precision, numeric_scale "
                   f"FROM information_schema.columns WHERE table_schema={literal(schema)} ORDER BY table_name, ordinal_position")


def fingerprint(pg, schema):
    inventory = schema_inventory(pg, schema)
    keys = pg.rows("SELECT r.relname AS table_name, c.conname AS name, pg_get_constraintdef(c.oid, true) AS definition "
                   "FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid JOIN pg_namespace n ON n.oid=r.relnamespace "
                   f"WHERE n.nspname={literal(schema)} AND c.contype='p' ORDER BY r.relname, c.conname")
    tables = {}
    for table in sorted({row["table_name"] for row in inventory}):
        raw = pg.value(f"SELECT to_jsonb(t)::text FROM {identifier(schema)}.{identifier(table)} t "
                       "ORDER BY to_jsonb(t)::text COLLATE \"C\";")
        # psql emits one JSON object per row. Sorting preserves duplicate multiplicity.
        count = len(raw.splitlines()) if raw else 0
        tables[table] = {"rows": count, "sha256": digest(raw.encode())}
    result = {"structure_sha256": digest(canonical({"columns": inventory, "primary_keys": keys}).encode()),
              "tables": tables, "primary_key_count": len(keys)}
    result["content_id"] = digest(canonical(result).encode())
    return result


def verify_tiny(pg, schema, source, version):
    expected = json.loads((FIXTURES / "expected.json").read_text())[source]
    q = identifier(schema)
    expressions = {
        "persons": f"SELECT count(*) FROM {q}.person",
        "observation_periods": f"SELECT count(*) FROM {q}.observation_period",
        "raw_observation_days": f"SELECT sum(observation_period_end_date-observation_period_start_date+1) FROM {q}.observation_period",
        # Deliberately simple daily expansion, independent of the future interval-merging operator.
        "union_observation_days": f"SELECT count(*) FROM (SELECT DISTINCT person_id, d::date FROM {q}.observation_period, "
                                  "LATERAL generate_series(observation_period_start_date::timestamp, observation_period_end_date::timestamp, interval '1 day') d) x",
        "measurements": f"SELECT count(*) FROM {q}.measurement",
        "numeric_values": f"SELECT count(value_as_number) FROM {q}.measurement",
        "measured_people": f"SELECT count(DISTINCT person_id) FROM {q}.measurement",
        "events_outside_observation": f"SELECT count(*) FROM {q}.measurement m WHERE NOT EXISTS "
                                      f"(SELECT 1 FROM {q}.observation_period p WHERE p.person_id=m.person_id "
                                      "AND m.measurement_date BETWEEN p.observation_period_start_date AND p.observation_period_end_date)",
        "unknown_nonzero_concepts": f"SELECT count(*) FROM {q}.measurement m WHERE measurement_concept_id<>0 AND NOT EXISTS "
                                   f"(SELECT 1 FROM {q}.concept c WHERE c.concept_id=m.measurement_concept_id)",
    }
    for key, query in expressions.items():
        actual = int(pg.value(query, "runner"))
        if actual != expected[key]:
            raise ValueError(f"{schema}: {key}: expected {expected[key]}, got {actual}")
    values = pg.rows(f"SELECT value_as_number::text AS value FROM {q}.measurement WHERE measurement_concept_id=900000001 "
                     "AND unit_concept_id=900000101 AND COALESCE(operator_concept_id,0)=0 AND value_as_number IS NOT NULL "
                     "ORDER BY value_as_number", "runner")
    if [row["value"] for row in values] != expected["primary_numeric_values_sorted"]:
        raise ValueError(f"{schema}: sorted numeric reference differs")
    if source == "tiny_a":
        if pg.value(f"SELECT value_as_number::text FROM {q}.measurement WHERE measurement_id=11", "runner") != "9007199254740993.125":
            raise ValueError("Decimal precision was lost")
        if version == "5.5" and pg.value(f"SELECT value_as_date FROM {q}.observation WHERE observation_id=1", "runner") != "2020-02-29":
            raise ValueError("CDM 5.5 date-valued observation was lost")
    frequencies = pg.rows(f"SELECT p.person_id::text AS person, count(m.measurement_id)::int AS events "
                           f"FROM {q}.person p LEFT JOIN {q}.measurement m USING (person_id) GROUP BY p.person_id", "runner")
    if {row["person"]: row["events"] for row in frequencies} != expected["measurement_frequency_by_person"]:
        raise ValueError(f"{schema}: person/event frequencies differ")
    # PostgreSQL's built-in sorted reference, not the future AchillesNext algorithm.
    summary = pg.rows(f"SELECT count(*) AS n, sum(value_as_number)::text AS sum, avg(value_as_number)::text AS mean, "
                      "percentile_disc(0.25) WITHIN GROUP (ORDER BY value_as_number)::text AS p25_discrete, "
                      "percentile_disc(0.5) WITHIN GROUP (ORDER BY value_as_number)::text AS p50_discrete, "
                      "percentile_disc(0.75) WITHIN GROUP (ORDER BY value_as_number)::text AS p75_discrete, "
                      "percentile_disc(0.9) WITHIN GROUP (ORDER BY value_as_number)::text AS p90_discrete "
                      f"FROM {q}.measurement WHERE measurement_concept_id=900000001 AND unit_concept_id=900000101 "
                      "AND COALESCE(operator_concept_id,0)=0 AND value_as_number IS NOT NULL", "runner")[0]
    if any(Decimal(str(summary[key])) != Decimal(str(value)) for key, value in expected["primary_numeric_summary"].items()):
        raise ValueError(f"{schema}: independent numeric summary differs")


def verify_permissions(pg):
    if pg.value("SELECT current_user;", "runner") != RUNNER:
        raise ValueError("Runner connection did not use the expected role")
    invalid = pg.rows("SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                      "WHERE c.relkind='r' AND n.nspname ~ '^cdm_(tiny_[ab]|gibleed|synpuf)_' AND "
                      f"(NOT has_table_privilege({literal(RUNNER)},c.oid,'SELECT') OR "
                      f"has_table_privilege({literal(RUNNER)},c.oid,'INSERT,UPDATE,DELETE,TRUNCATE') OR "
                      f"NOT has_schema_privilege({literal(RUNNER)},n.oid,'USAGE') OR "
                      f"has_schema_privilege({literal(RUNNER)},n.oid,'CREATE'))")
    if invalid:
        raise ValueError(f"Unexpected source access grants: {invalid}")
    denied = pg.run("BEGIN; INSERT INTO cdm_tiny_a_53.person (person_id,gender_concept_id,year_of_birth,race_concept_id,ethnicity_concept_id) "
                    "VALUES (999,0,2000,0,0); ROLLBACK;", "runner", allow_failure=True)
    if denied.returncode == 0 or "permission denied" not in denied.stderr:
        raise ValueError("Runner source write was not denied by permissions")
    denied = pg.run("BEGIN; CREATE SCHEMA fixture_runner_must_not_create; ROLLBACK;", "runner", allow_failure=True)
    if denied.returncode == 0 or "permission denied" not in denied.stderr:
        raise ValueError("Runner must not create database-level schemas")
    pg.run("BEGIN; CREATE TABLE fixture_results.permission_probe (n integer); "
           "INSERT INTO fixture_results.permission_probe VALUES (1); "
           "SELECT n FROM fixture_results.permission_probe; ROLLBACK;", "runner")
    return {"read_sources": True, "source_insert_denied": True, "database_create_schema_denied": True,
            "results_create_insert_select": True}


def verify_structure(pg, schema, result, version):
    ddl = (FIXTURES / "ddl" / f"{version}.sql").read_text()
    tables = re.findall(r"CREATE TABLE @cdmDatabaseSchema\.(\w+)\s*\((.*?)\);", ddl, re.S)
    if set(result["tables"]) != {table for table, body in tables}:
        raise ValueError(f"Table set does not match CDM {version}")
    types = {"integer": "integer", "numeric": "numeric", "timestamp": "timestamp without time zone",
             "date": "date", "text": "text", "varchar": "character varying"}
    expected = []
    for table, body in sorted(tables):
        for ordinal, field in enumerate(body.strip().split(","), 1):
            match = re.fullmatch(r'"?(\w+)"?\s+(\w+)(?:\((\d+)\))?\s+(NOT NULL|NULL)', field.strip(), re.I)
            if not match:
                raise ValueError(f"Unrecognized pinned DDL field: {field}")
            name, data_type, length, required = match.groups()
            expected.append((table, name.lower(), types[data_type.lower()], "NO" if required.upper() == "NOT NULL" else "YES",
                             ordinal, int(length) if length else None))
    actual = [(row["table_name"], row["column_name"], row["data_type"], row["is_nullable"], row["ordinal_position"],
               row["character_maximum_length"]) for row in schema_inventory(pg, schema)]
    if actual != expected:
        raise ValueError(f"Column structure does not match CDM {version}: {schema}")
    keys = (FIXTURES / "ddl" / f"{version}-primary-keys.sql").read_text()
    expected_keys = 0 if schema == "cdm_gibleed_53" else len(re.findall(r"PRIMARY KEY", keys))
    if result["primary_key_count"] != expected_keys:
        raise ValueError(f"Unexpected primary key policy: {schema}")


def verify(pg, state, versions, with_gibleed):
    guard_database(pg)
    check_sources()
    schemas = {}
    for source in ("tiny_a", "tiny_b"):
        for version in VERSIONS:
            schema = schema_name(source, version)
            verify_tiny(pg, schema, source, version)
            result = fingerprint(pg, schema)
            verify_structure(pg, schema, result, version)
            expected = {table: len(rows) for table, rows in tiny_data(source, version).items()}
            for table, detail in result["tables"].items():
                if detail["rows"] != expected.get(table, 0):
                    raise ValueError(f"Unexpected row count: {schema}.{table}")
            schemas[schema] = result
    if with_gibleed:
        for version in ("5.3", "5.5"):
            archive_path(state, version, False)
            schema = schema_name("gibleed", version)
            result = fingerprint(pg, schema)
            verify_structure(pg, schema, result, version)
            counts = LOCK["gibleed"]["assets"][version]["row_counts"]
            for table, detail in result["tables"].items():
                if detail["rows"] != counts.get(table, 0):
                    raise ValueError(f"Unexpected row count: {schema}.{table}")
            schemas[schema] = result
    permissions = verify_permissions(pg)
    content_id = digest(canonical({schema: data["content_id"] for schema, data in schemas.items()}).encode())
    report = {"format_version": 1, "fixture_version": LOCK["fixture_version"], "content_id": content_id,
              "versions": versions, "permissions": permissions, "schemas": schemas,
              "input_sha256": {name: digest((FIXTURES / name).read_bytes()) for name in ("lock.json", "tiny.json", "expected.json")},
              "scope": "Synthetic fixture environment; no analysis engine or performance certification"}
    output = state / "verification.json"
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(schemas)} source schemas; row counts, independent references and access boundaries")
    print(f"Content ID: {content_id}")
    print(f"Local report: {output}")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("setup", "reset", "verify"))
    parser.add_argument("--state-dir", type=Path, default=ROOT / ".local/postgresql")
    parser.add_argument("--host", default="/tmp", help="Local Unix socket directory or loopback address")
    parser.add_argument("--port", type=int, default=5432)
    parser.add_argument("--admin-user", help="Existing PostgreSQL role allowed to create database and roles")
    parser.add_argument("--with-gibleed", action="store_true", help="Include pinned 5.3 and 5.5 public fixtures")
    parser.add_argument("--allow-version-mismatch", action="store_true", help="Record an explicitly unpinned run")
    parser.add_argument("--check-repeat", action="store_true", help="Rebuild twice and require identical fixture content IDs")
    args = parser.parse_args()
    args.state_dir = args.state_dir.expanduser().resolve()
    if args.command == "verify" and args.check_repeat:
        parser.error("--check-repeat rebuilds data and is only available with setup/reset")
    if not (args.host.startswith("/") or args.host in ("127.0.0.1", "localhost", "::1")):
        parser.error("Only a local PostgreSQL host/socket is supported")
    if ":" in args.host or "\n" in args.host or "\n" in str(args.state_dir):
        parser.error("Use a Unix socket or IPv4 loopback host")
    if sys.version_info < (3, 10):
        parser.error("Python 3.10 or newer is required")
    try:
        check_sources()
        if args.command == "setup":
            pg, versions = provision(args)
        else:
            pg = Postgres(args.state_dir)
            versions = check_versions(pg, args.allow_version_mismatch)
        if args.command in ("setup", "reset"):
            reset_fixtures(pg, args.state_dir, args.with_gibleed,
                           download=args.command == "setup", prepare_synpuf=args.command == "setup")
        first = verify(pg, args.state_dir, versions, args.with_gibleed)
        if args.check_repeat:
            reset_fixtures(pg, args.state_dir, args.with_gibleed)
            second = verify(pg, args.state_dir, versions, args.with_gibleed)
            if first["content_id"] != second["content_id"]:
                raise ValueError("Clean rebuild produced a different content ID")
            second["repeatability_check"] = "Two clean rebuilds produced identical content IDs"
            (args.state_dir / "verification.json").write_text(json.dumps(second, indent=2, sort_keys=True) + "\n")
            print("PASS: two clean rebuilds produced identical content IDs")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
