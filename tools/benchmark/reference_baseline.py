#!/usr/bin/env python3
"""Measure pinned legacy SQL on synthetic, session-local PostgreSQL inputs."""

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import postgresql_fixtures as fixtures

CONFIG = ROOT / 'tests/fixtures/benchmark/workloads.json'
SETTINGS = {'work_mem': '64MB', 'max_parallel_workers_per_gather': 0,
            'jit': 'off', 'statement_timeout': '30s', 'lock_timeout': '2s'}
ALLOWED_FIXTURES = {'cdm_tiny_a_53', 'cdm_tiny_a_54', 'cdm_tiny_a_55',
                    'cdm_gibleed_53', 'cdm_gibleed_55'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def check_config(config):
    require(config['format_version'] == 1, 'Unsupported benchmark format')
    require(config['analysis_ids'] == [1, 1800, 1801, 1815], 'Only the pinned legacy slice is allowed')
    require(config['settings'] == SETTINGS, 'Changing resource settings needs a reviewed benchmark revision')
    require(set(config['fixtures']) <= ALLOWED_FIXTURES, 'Only declared synthetic fixtures may be read')
    require(type(config['trials']) is int and 3 <= config['trials'] <= 20, 'Use 3–20 measured trials')
    require(config['warmups'] == 1, 'One explicit warmup is required')
    ids = [*config['fixtures'], *(s['id'] for s in config['scales'])]
    require(len(ids) == len(set(ids)), 'Duplicate workload ID')
    for scale in config['scales']:
        require(re.fullmatch('[a-z][a-z0-9_]*', scale['id']), 'Invalid scale ID')
        for key, lower, upper in [('records', 1, 200000), ('distinct_values', 1, 4096),
                                  ('people', 1, 20000), ('overlap_every', 1, 100)]:
            require(type(scale[key]) is int and lower <= scale[key] <= upper, f'Unsafe scale bound: {key}')
        require(scale['distinct_values'] <= scale['records'] and scale['people'] <= scale['records'], 'Invalid scale cardinality')


def normalize(value):
    number = Decimal(value)
    if not number.is_finite():
        return str(number)
    result = format(number, 'f')
    if '.' in result:
        result = result.rstrip('0').rstrip('.')
    return '0' if result in ('0', '-0') else result


def numeric_order(value):
    number = Decimal(value)
    return (1, Decimal(0)) if number.is_nan() else (0, number)


def oracle(data):
    """Independent Python interval membership, row multiplicity and sorted ranks.

    Matches legacy scope, including overlap multiplication and operator pooling.
    Alpha membership counts are returned separately, never used as legacy truth.
    """
    periods = defaultdict(list)
    for person, start, end in data['periods']:
        periods[person].append((start, end))
    people = set(data['people'])
    records, alpha_records = Counter(), Counter()
    tested, groups = defaultdict(set), defaultdict(list)
    for person, concept, unit, operator, number, day in data['measurements']:
        matches = sum(start <= day <= end for start, end in periods[person])
        if matches:
            key = str(concept)
            records[key] += matches
            tested[key].add(person)
            if person in people:
                alpha_records[key] += 1
            if number is not None and unit is not None:
                groups[(key, str(unit))].extend([number] * matches)
    summaries = []
    for (concept, unit), values in sorted(groups.items()):
        values.sort(key=numeric_order)
        n = len(values)
        row = {'concept': concept, 'unit': unit, 'n': str(n),
               'min': normalize(values[0]), 'max': normalize(values[-1])}
        for label, numerator, denominator in [('p10', 1, 10), ('p25', 1, 4),
                                              ('p50', 1, 2), ('p75', 3, 4), ('p90', 9, 10)]:
            row[label] = normalize(values[(numerator * n + denominator - 1) // denominator - 1])
        summaries.append(row)
    return {'person_count': str(len(people)), 'records': {key: str(n) for key, n in sorted(records.items())},
            'tested_people': {key: str(len(value)) for key, value in sorted(tested.items())},
            'numeric': summaries, 'alpha_membership_records': {key: str(n) for key, n in sorted(alpha_records.items())}}


def check_result(actual, expected):
    comparable = {k: v for k, v in expected.items() if k != 'alpha_membership_records'}
    normalized = json.loads(json.dumps(actual))
    require(isinstance(normalized, dict) and normalized.keys() == comparable.keys(), 'Incomplete legacy result shape')
    for row in normalized['numeric']:
        for key in ['min', 'max', 'p10', 'p25', 'p50', 'p75', 'p90']:
            row[key] = normalize(row[key])
    require(normalized == comparable, 'Legacy output differs from independent Python count/rank oracle')


def check_export(rows, expected, unit_names=None):
    groups = {(r['concept'], r['unit']): r for r in expected['numeric']}
    fields = {'min_value': 'min', 'max_value': 'max', 'p10_value': 'p10', 'p25_value': 'p25',
              'median_value': 'p50', 'p75_value': 'p75', 'p90_value': 'p90'}
    for row in rows:
        if 'unit_concept_id' in row:
            target = groups.get((str(row['concept_id']), str(row['unit_concept_id'])))
        else:
            # Published 1.7.2 exports a unit label only. Resolve against the
            # independently captured local terminology; never guess an ID.
            candidates = [r for r in expected['numeric'] if r['concept'] == str(row['concept_id'])
                          and unit_names is not None and unit_names.get(r['unit']) == row.get('category')]
            require(len(candidates) == 1, 'Published export lacks an unambiguous numeric unit identity')
            target = candidates[0]
        require(target is not None, 'Export contains an unknown numeric group')
        for field, key in fields.items():
            require(normalize(str(row[field])) == target[key], 'Export quantile differs from exact oracle')


def describe_input(data):
    freq = Counter(value for *_, value, day in data['measurements'] if value is not None)
    return {'people_rows': len(data['people']), 'observation_period_rows': len(data['periods']),
            'measurement_rows': len(data['measurements']), 'recorded_numeric_distinct': len(freq),
            'max_value_frequency': max(freq.values(), default=0),
            'input_sha256': sha(encoded(data)), 'indexes': 'none on session-local input tables'}


def input_setup(workload):
    if isinstance(workload, str):
        require(workload in ALLOWED_FIXTURES, 'Refusing an undeclared source')
        q = fixtures.identifier(workload)
        marker = f'{fixtures.MARKER}: {workload}'
        return f"""DO $guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname={fixtures.literal(workload)}
 AND obj_description(oid,'pg_namespace')={fixtures.literal(marker)}
 AND nspowner=(SELECT oid FROM pg_roles WHERE rolname={fixtures.literal(fixtures.OWNER)}))
THEN RAISE EXCEPTION 'Refusing unmarked source'; END IF; END $guard$;
CREATE TEMP TABLE person AS SELECT person_id FROM {q}.person;
CREATE TEMP TABLE observation_period AS SELECT person_id, observation_period_start_date, observation_period_end_date FROM {q}.observation_period;
CREATE TEMP TABLE measurement AS SELECT measurement_id,person_id,measurement_concept_id,unit_concept_id,operator_concept_id,value_as_number,measurement_date FROM {q}.measurement;
CREATE TEMP TABLE concept AS SELECT concept_id,concept_name,domain_id FROM {q}.concept;
"""
    n, distinct, people, overlap = (workload[k] for k in ['records', 'distinct_values', 'people', 'overlap_every'])
    return f"""CREATE TEMP TABLE person AS SELECT g AS person_id FROM generate_series(1,{people}) g;
CREATE TEMP TABLE observation_period AS
 SELECT person_id, DATE '2020-01-01' AS observation_period_start_date, DATE '2020-12-31' AS observation_period_end_date FROM person
 UNION ALL SELECT person_id, DATE '2020-01-01', DATE '2020-12-31' FROM person WHERE person_id % {overlap}=0;
CREATE TEMP TABLE measurement AS SELECT g AS measurement_id, 1+(g-1)%{people} AS person_id,
 900000001 AS measurement_concept_id, 900000101 AS unit_concept_id, 0 AS operator_concept_id,
 ((g-1)%{distinct})::numeric+0.125 AS value_as_number, DATE '2020-01-15' AS measurement_date
 FROM generate_series(1,{n}) g;
CREATE TEMP TABLE concept(concept_id integer,concept_name text,domain_id text);
INSERT INTO concept VALUES (900000001,'Synthetic laboratory','Measurement'),(900000101,'Synthetic unit','Unit');
"""


INPUT_QUERY = """SELECT jsonb_build_object(
 'people',(SELECT COALESCE(jsonb_agg(person_id ORDER BY person_id),'[]') FROM person),
 'concepts',(SELECT COALESCE(jsonb_agg(jsonb_build_array(concept_id,concept_name,domain_id) ORDER BY concept_id,concept_name,domain_id),'[]') FROM concept),
 'periods',(SELECT COALESCE(jsonb_agg(jsonb_build_array(person_id,observation_period_start_date::text,observation_period_end_date::text)
 ORDER BY person_id,observation_period_start_date,observation_period_end_date),'[]') FROM observation_period),
 'measurements',(SELECT COALESCE(jsonb_agg(jsonb_build_array(person_id,measurement_concept_id,unit_concept_id,operator_concept_id,value_as_number::text,measurement_date::text)
 ORDER BY measurement_id,person_id,measurement_date,measurement_concept_id,value_as_number::text NULLS FIRST,unit_concept_id NULLS FIRST,operator_concept_id NULLS FIRST),'[]') FROM measurement));"""

RESULT_QUERY = """SELECT jsonb_build_object(
 'person_count',(SELECT count_value::text FROM bench_1),
 'records',(SELECT COALESCE(jsonb_object_agg(stratum_1,count_value::text),'{}') FROM bench_1801),
 'tested_people',(SELECT COALESCE(jsonb_object_agg(stratum_1,count_value::text),'{}') FROM bench_1800),
 'numeric',(SELECT COALESCE(jsonb_agg(jsonb_build_object('concept',stratum_1,'unit',stratum_2,'n',count_value::text,
 'min',min_value::text,'max',max_value::text,'p10',p10_value::text,'p25',p25_value::text,'p50',median_value::text,'p75',p75_value::text,'p90',p90_value::text)
 ORDER BY stratum_1,stratum_2),'[]') FROM bench_dist_1815));"""


def script(workload, compiled, plans=False):
    parts = ['\\timing off', 'BEGIN ISOLATION LEVEL REPEATABLE READ;', 'SET LOCAL search_path=pg_temp,pg_catalog;']
    parts += [f'SET LOCAL {key}={fixtures.literal(value)};' for key, value in SETTINGS.items()]
    parts += ['\\echo @@prepare', input_setup(workload)]
    parts += [f'ANALYZE {table};' for table in ['person', 'observation_period', 'measurement', 'concept']]
    parts += ['\\echo @@input', INPUT_QUERY, '\\echo @@generation', '\\timing on']
    index = 0
    for analysis in compiled['analyses'].values():
        for sql in analysis['statements']:
            clean = re.sub(r'--[^\n]*', '', sql).strip()
            if plans and re.match('CREATE TEMP TABLE', clean, flags=re.I):
                parts += [f'\\echo @@plan_{index}', 'EXPLAIN (ANALYZE,BUFFERS,SETTINGS,TIMING OFF,FORMAT JSON) ' + sql + ';', '\\echo @@generation']
                index += 1
            else:
                parts.append(sql + ';')
    parts += ['CREATE TEMP TABLE achilles_results AS SELECT * FROM bench_1 UNION ALL SELECT * FROM bench_1800 UNION ALL SELECT * FROM bench_1801;',
              'CREATE TEMP TABLE achilles_results_dist AS SELECT * FROM bench_dist_1815;',
              '\\timing off', '\\echo @@result', RESULT_QUERY,
              '\\echo @@export', '\\timing on',
              "SELECT COALESCE(jsonb_agg(to_jsonb(q)),'[]') FROM (" + compiled['export']['statements'][0].rstrip(';') + ') q;',
              '\\timing off', '\\echo @@rollback', 'ROLLBACK;']
    return '\n'.join(parts)


def parse_output(output):
    phase = None
    durations, payloads = defaultdict(list), defaultdict(list)
    for line in output.splitlines():
        if line.startswith('@@'):
            phase = line[2:]
        elif match := re.match(r'^Time: ([0-9.]+) ms', line):
            require(phase is not None, 'Timing lacks a phase')
            durations[phase].append(float(match[1]))
        elif line.strip() and phase:
            payloads[phase].append(line)
    require('input' in payloads and 'result' in payloads and 'export' in payloads, 'Incomplete psql output')
    parsed = {key: json.loads('\n'.join(lines), parse_float=Decimal) if key == 'export' else json.loads('\n'.join(lines))
              for key, lines in payloads.items() if key in ('input', 'result', 'export') or key.startswith('plan_')}
    parsed['_export_bytes'] = '\n'.join(payloads['export']).encode('utf-8')
    require(durations['generation'] and len(durations['export']) == 1, 'Missing phase timings')
    return parsed, dict(durations)


def summary(values):
    require(len(values) >= 3, 'Too few measured samples')
    return {'n': len(values), 'median_ms': statistics.median(values), 'min_ms': min(values), 'max_ms': max(values),
            'p95_ms': None, 'tail_reason': 'Small warmed serial sample; max is observed, not an estimated tail percentile'}


def hardware():
    details = {'system': platform.system(), 'machine': platform.machine(),
               'python': platform.python_version(), 'logical_cpus': os.cpu_count(),
               'macos_version': platform.mac_ver()[0] or None,
               'cpu_model': None, 'physical_memory_bytes': None}
    if platform.system() == 'Darwin':
        for name, key in [('machdep.cpu.brand_string', 'cpu_model'), ('hw.memsize', 'physical_memory_bytes')]:
            result = subprocess.run(['sysctl', '-n', name], text=True, capture_output=True)
            if result.returncode == 0:
                details[key] = result.stdout.strip()
    return details


def compile_legacy(output, config):
    start = time.perf_counter()
    result = subprocess.run(['Rscript', str(Path(__file__).with_name('render_legacy.R')), str(CONFIG), str(output/'rendered.json')],
                            text=True, capture_output=True, timeout=60)
    (output/'render.log').write_text(result.stdout + result.stderr)
    require(result.returncode == 0, 'Legacy rendering failed; inspect the local render.log')
    compiled = json.loads((output/'rendered.json').read_text())
    baseline = json.loads((ROOT/'inst/analysis/legacy-baselines.json').read_text())['baselines'][0]
    hashes = {}
    for key, rendered in [*compiled['analyses'].items(), ('export', compiled['export'])]:
        raw = bytes.fromhex(rendered.pop('source_hex'))
        blob = hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
        expected = config['export_git_blob'] if key == 'export' else baseline['selected_sql_git_blobs'][key]
        require(blob == expected, f'Installed template differs from pinned published bytes: {key}')
        hashes[key] = {'git_blob': blob, 'sha256': sha(raw)}
    compiled['provenance'] = {'commit': baseline['commit'], 'source_hashes': hashes,
                              'R_process_wall_ms': (time.perf_counter()-start)*1000}
    save(output/'rendered.json', compiled)
    return compiled


def run(args):
    config = json.loads(CONFIG.read_text())
    check_config(config)
    output = args.output_dir.expanduser().resolve()
    require(not output.is_relative_to(ROOT), 'Raw evidence must be outside the package checkout')
    require(not output.exists(), 'Output directory must be new; do not overwrite prior evidence')
    pg = fixtures.Postgres(args.postgresql_state.expanduser().resolve())
    fixtures.guard_database(pg)
    versions = fixtures.check_versions(pg, allow_mismatch=False)
    # The existing read-only runner intentionally has no database TEMP privilege.
    # Use the isolated, nonsuperuser fixture owner; every generated write targets
    # a session-local table and the whole transaction is rolled back.
    run_role = 'owner'
    # Only explicit benchmark settings are changed, within each transaction.
    pg.env['LC_ALL'] = 'C'
    output.mkdir(parents=True, mode=0o700)
    compiled = compile_legacy(output, config)
    environment = pg.rows("SELECT name,setting,unit FROM pg_settings WHERE name IN ('shared_buffers','effective_cache_size','work_mem','max_connections','max_parallel_workers_per_gather','jit','track_io_timing','block_size') ORDER BY name", run_role)
    report = {'format_version': 1, 'captured_at': datetime.now(timezone.utc).isoformat(),
              'scope': 'Published legacy SQL/template slice over temporary synthetic copies; not full Achilles execution or alpha performance',
              'versions': versions, 'legacy': compiled['provenance'], 'R_packages': compiled['versions'],
              'client': hardware(), 'exclusive_compute': False,
              'settings': SETTINGS, 'server_defaults': environment, 'config_sha256': sha(CONFIG.read_bytes()),
              'database_role': fixtures.OWNER, 'role_reason': 'Existing runner denies TEMP; database ACLs are not changed',
              'cache_policy': config['cache_policy'], 'workloads': [],
              'unavailable': {'server_peak_rss': 'Not instrumented', 'server_cpu_time': 'Not instrumented',
                              'cold_cache_latency': 'No cache eviction/restart attempted', 'full_achilles_dispatch_export': 'Not run; template slice through psql',
                              'browser_view_latency': 'No viewer implemented', 'human_task_times': 'Requires separate owner/researcher sessions'}}
    for workload in [*config['fixtures'], *config['scales']]:
        name = workload if isinstance(workload, str) else workload['id']
        folder = output/name
        folder.mkdir(mode=0o700)
        statement = script(workload, compiled)
        (folder/'run.sql').write_text(statement)
        # An untimed correctness preflight gates all reported timing samples.
        result = pg.run(statement, run_role)
        parsed, _ = parse_output(result.stdout)
        data = parsed.pop('input')
        expected = oracle(data)
        unit_names = {str(cid): name for cid, name, domain in data['concepts']}
        check_result(parsed['result'], expected)
        check_export(parsed['export'], expected, unit_names)
        identity = describe_input(data)
        save(folder/'input.json', data)
        save(folder/'oracle.json', expected)
        del data
        measured = []
        for trial in range(config['warmups']+config['trials']):
            start = time.perf_counter()
            result = pg.run(statement, run_role)
            wall = (time.perf_counter()-start)*1000
            values, times = parse_output(result.stdout)
            require(describe_input(values.pop('input')) == identity, 'Input changed after correctness preflight')
            check_result(values['result'], expected)
            check_export(values['export'], expected, unit_names)
            # Preserve exact server JSON literals; do not reserialize through floats.
            exported = values.pop('_export_bytes')
            start = time.perf_counter()
            artifact = folder/f'trial-{trial}.json'
            artifact.write_bytes(exported)
            write_ms = (time.perf_counter()-start)*1000
            start = time.perf_counter()
            require(json.loads(artifact.read_bytes(), parse_float=Decimal) == values['export'], 'Export round-trip failed')
            decode_ms = (time.perf_counter()-start)*1000
            sample = {'trial': trial, 'warmup': trial < config['warmups'],
                      'generation_compute_materialize_ms': sum(times['generation']), 'server_statement_ms': times,
                      'legacy_export_query_ms': sum(times['export']), 'audit_file_write_ms': write_ms,
                      'audit_file_read_decode_ms': decode_ms, 'psql_process_wall_ms': wall,
                      'export_bytes': len(exported), 'export_sha256': sha(exported), 'export_rows': len(values['export']),
                      'compute_only_ms': None, 'materialize_only_ms': None, 'publication_ms': None, 'view_ms': None}
            measured.append(sample)
            save(folder/f'trial-{trial}-timing.json', sample)
        plan_result = pg.run(script(workload, compiled, plans=True), run_role)
        plans, _ = parse_output(plan_result.stdout)
        require(describe_input(plans.pop('input')) == identity, 'Plan input differs')
        check_result(plans.pop('result'), expected)
        plans.pop('export')
        plans.pop('_export_bytes')
        save(folder/'plans.json', plans)
        (folder/'warnings.log').write_text(plan_result.stderr)
        kept = [s for s in measured if not s['warmup']]
        workload_report = {'id': name, 'input': identity, 'oracle': 'passed_before_timing_and_after_each_trial',
                           'expected': expected, 'trials': measured, 'plans': f'{name}/plans.json',
                           'summary': {key: summary([s[key] for s in kept]) for key in [
                               'generation_compute_materialize_ms', 'legacy_export_query_ms', 'audit_file_write_ms', 'audit_file_read_decode_ms', 'psql_process_wall_ms']}}
        report['workloads'].append(workload_report)
        save(output/'report.json', report)
        print(f"PASS {name}: {identity['measurement_rows']} records; oracle verified; {len(kept)} measured trials", flush=True)
    report['tool_sha256'] = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in [Path(__file__), Path(__file__).with_name('render_legacy.R'), CONFIG]}
    save(output/'report.json', report)
    print(f'Private evidence: {output / "report.json"}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--postgresql-state', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        run(args)
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
