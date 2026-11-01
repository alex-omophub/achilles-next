#!/usr/bin/env python3
"""Bounded synthetic physical-plan probe; no full-profile/scale qualification."""
import argparse
from collections import defaultdict
from datetime import date, timedelta
from decimal import Decimal, localcontext
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
START, END = date(2020, 1, 15), date(2020, 2, 15)


def decimal_text(value):
    value = format(Decimal(value), 'f')
    if '.' in value:
        value = value.rstrip('0').rstrip('.')
    return '0' if value in ('-0', '') else value


def fixture(extra_rows=0):
    intervals = [[1, '2020-01-01', '2020-02-29'], [1, '2020-01-01', '2020-02-29'],
                 [1, '2020-01-15', '2020-03-01'], [2, '2020-01-10', '2020-01-10'],
                 [2, '2020-02-10', '2020-02-09'], [2, None, '2020-02-29'],
                 [4, '2020-02-01', '2020-02-29'], [4, '2020-03-01', '2020-03-02'],
                 [5, '2019-12-31', '2019-12-31'], [99, '2020-01-01', '2020-12-31'],
                 [None, '2020-01-01', '2020-12-31']]
    rows = [
        [1, 100, '2020-01-01', '-5', 201, None], [1, 100, '2020-01-15', '1.125', 201, 0],
        [1, 100, '2020-02-01', '100', 201, None], [1, 100, '2020-02-10', '1000', 202, 0],
        [2, 100, '2020-01-10', '0.125', 201, 0], [2, 100, '2020-02-15', '0.25', 201, 0],
        [3, 0, '2020-01-20', '1', 201, None], [4, None, '2020-02-02', '-0.125', 202, None],
        [None, 100, '2020-01-15', '9007199254740993.125', 201, None],
        [99, 100, '2020-01-15', '0.000000000000000000000000001', 201, 0],
        [1, 100, None, '0.1', 201, 0], [1, 100, '2019-12-31', '0.001', 201, None],
        [1, 101, '2020-02-01', None, 202, 0], [1, 102, '2020-02-01', 'NaN', 201, 0],
        [1, 102, '2020-02-01', 'Infinity', 201, 0], [1, 102, '2020-02-01', '-Infinity', 201, None],
        [1, 102, '2020-02-01', '2', None, 0], [1, 102, '2020-02-01', '2', 0, 0],
        [1, 102, '2020-02-01', '2', 999, 0], [1, 102, '2020-02-01', '2', 203, 0],
        [1, 102, '2020-02-01', '2', 201, 417], [1, -1, None, None, 201, None],
    ]
    rows += [rows[0][:], rows[1][:]]  # Identical physical rows must survive.
    for i in range(extra_rows):
        rows.append([i % 5 + 1, 100 + i % 13, (date(2019, 12, 20) + timedelta(days=i % 90)).isoformat(),
                     str(Decimal(i % 31) - Decimal('15.125')), 201 + i % 2, None if i % 3 == 0 else 0])
    return dict(people=list(range(1, 6)), intervals=intervals, events=[dict(zip(
        ['person_id', 'concept_id', 'event_date', 'value_as_number', 'unit_concept_id', 'operator_concept_id'], r)) for r in rows])


def oracle(data, domain):
    domain = domain.removesuffix('_weighted')
    people = set(data['people'])
    # Independent daily expansion only for this tiny oracle, never production SQL.
    observed = defaultdict(set)
    for person, start, end in data['intervals']:
        if person not in people or start is None or end is None or start > end:
            continue
        start, end = date.fromisoformat(start), date.fromisoformat(end)
        observed[person].update(start + timedelta(days=d) for d in range((end-start).days+1))
    periods = [('full', None, None), ('window', START, END), ('year', START, END),
               ('month', START, date(2020, 1, 31)), ('month', date(2020, 2, 1), END)]
    counts = defaultdict(list)
    for row in data['events']:
        day = date.fromisoformat(row['event_date']) if row['event_date'] else None
        for kind, start, end in periods:
            if kind == 'full' or day is not None and start <= day <= end:
                counts[row['concept_id'], kind, start, end].append(row)
    captures = []
    for (concept, kind, start, end), rows in counts.items():
        eligible = [r for r in rows if r['event_date'] and date.fromisoformat(r['event_date']) in observed[r['person_id']]
                    and START <= date.fromisoformat(r['event_date']) <= END]
        captures.append(dict(concept_id=None if concept is None else str(concept), kind=kind,
            period_start=start.isoformat() if start else None, period_end=end.isoformat() if end else None,
            records=str(len(rows)), people=str(len({r['person_id'] for r in rows if r['person_id'] in people})),
            observed_records=str(len(eligible)), observed_people=str(len({r['person_id'] for r in eligible}))))
    numeric = []
    if domain in ('measurement', 'observation'):
        groups = defaultdict(list)
        for r in data['events']:
            operator = r['operator_concept_id'] if domain == 'measurement' else None
            if r['unit_concept_id'] not in (201, 202) or operator not in (None, 0):
                continue
            group = groups[r['concept_id'], r['unit_concept_id'], operator]
            value = r['value_as_number']
            if value is not None and Decimal(value).is_finite():
                group.append(Decimal(value))
        for (concept, unit, operator), values in groups.items():
            values.sort(); n = len(values)
            with localcontext() as context:
                context.prec = 200
                total = decimal_text(sum(values, Decimal(0))) if values else None
            result = dict(concept_id=None if concept is None else str(concept), unit_concept_id=str(unit),
                          operator_concept_id=None if operator is None else str(operator), n=str(n), total=total,
                          minimum=decimal_text(values[0]) if n else None, maximum=decimal_text(values[-1]) if n else None)
            for name, a, b in [('p10', 1, 10), ('p25', 1, 4), ('p50', 1, 2), ('p75', 3, 4), ('p90', 9, 10)]:
                result[name] = decimal_text(values[(n*a+b-1)//b-1]) if n else None
            numeric.append(result)
    frequencies = defaultdict(int)
    for row in data['events']:
        if row['person_id'] in people:
            frequencies[row['concept_id'], row['person_id']] += 1
    histogram = defaultdict(int)
    for (concept, person), n in frequencies.items():
        histogram[concept, n] += 1
    linked_event_frequency = [dict(concept_id=None if concept is None else str(concept), records_per_person=str(n), people=str(count))
                              for (concept, n), count in histogram.items()]
    return dict(capture=captures, numeric=numeric, linked_event_frequency=linked_event_frequency)


def canonical(rows):
    output = []
    for row in rows:
        row = dict(row)
        for key in ('total', 'minimum', 'maximum', 'p10', 'p25', 'p50', 'p75', 'p90'):
            if row.get(key) is not None:
                row[key] = decimal_text(row[key])
        output.append(json.dumps(row, sort_keys=True))
    return sorted(output)


def coverage_oracle(data):
    observed = defaultdict(set)
    for person, start, end in data['intervals']:
        if person not in data['people'] or start is None or end is None or start > end:
            continue
        start, end = date.fromisoformat(start), date.fromisoformat(end)
        observed[person].update(start + timedelta(days=d) for d in range((end-start).days+1))
    periods = [('full', None, None), ('window', START, END), ('year', START, END),
               ('month', START, date(2020, 1, 31)), ('month', date(2020, 2, 1), END)]
    result = []
    for kind, start, end in periods:
        populations = [{d for d in days if kind == 'full' or start <= d <= end} for days in observed.values()]
        result.append(dict(kind=kind, period_start=start.isoformat() if start else None, period_end=end.isoformat() if end else None,
                           people=str(sum(bool(p) for p in populations)), person_days=str(sum(len(p) for p in populations))))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--trials', type=int, choices=(1, 3), default=3,
                        help='Paired repeats: three for exploratory timing, one for CI correctness')
    args = parser.parse_args()
    out = args.output_dir.resolve()
    if out.exists() or out.is_relative_to(ROOT):
        parser.error('Use a new evidence directory outside the checkout')
    out.mkdir(mode=0o700, parents=True)
    inputs = [dict(id='empty', data=dict(people=[], intervals=[], events=[])),
              dict(id='adversarial', data=fixture()), dict(id='bounded_1200', data=fixture(1200))]
    definitions = [*sorted((ROOT/'R').glob('*.R')), *sorted((ROOT/'inst/sql/postgresql').glob('batch-*.sql')),
                   ROOT/'tools/benchmark/batch_primitives.py', ROOT/'tests/tracer/batch-workspace.R',
                   ROOT/'inst/analysis/core-batch-plan-v1.json', ROOT/'inst/analysis/core-characterization-v2.json']
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in definitions}
    (out/'input.json').write_text(json.dumps(inputs))
    started = time.perf_counter()
    subprocess.run(['Rscript', '--vanilla', 'tests/tracer/batch-workspace.R', str(args.config.resolve(strict=True)), str(out), str(args.trials)], cwd=ROOT, check=True)
    report = json.loads((out/'report.json').read_text())
    expected_runs = {(c['id'], mode, trial) for c in inputs for mode in ('reference', 'shared') for trial in range(1, args.trials+1)}
    actual_runs = {(r['case'], r['mode'], r['trial']) for r in report['runs']}
    if expected_runs != actual_runs or len(report['runs']) != len(expected_runs):
        raise ValueError('Missing or duplicated primitive trials')
    expected_domains = set(json.loads((ROOT/'inst/analysis/core-characterization-v2.json').read_text())['domains']) | {'measurement_weighted', 'observation_weighted'}
    if any(set(r['outputs']) != expected_domains for r in report['runs']):
        raise ValueError('Missing domain or numeric-strategy probe output')
    mismatches = 0
    for case in inputs:
        for run in report['runs']:
            if run['case'] != case['id']:
                continue
            if canonical(run['coverage']) != canonical(coverage_oracle(case['data'])):
                raise ValueError(f'Independent coverage mismatch: {case["id"]}/{run["mode"]}')
            for domain, actual in run['outputs'].items():
                expected = oracle(case['data'], domain)
                for kind in ('capture', 'numeric', 'linked_event_frequency'):
                    if canonical(actual[kind]) != canonical(expected[kind]):
                        mismatches += 1
                        raise ValueError(f'Independent oracle mismatch: {case["id"]}/{run["mode"]}/{domain}/{kind}')
    summaries = []
    for case in inputs:
        for mode in ('reference', 'shared'):
            runs = [r for r in report['runs'] if r['case'] == case['id'] and r['mode'] == mode]
            summaries.append(dict(case=case['id'], mode=mode, trials=len(runs),
                elapsed_ms_median=statistics.median(r['elapsed_ms'] for r in runs),
                materialization_statements=[sum(s['state'] == 'computed' for s in r['telemetry']['stages']) for r in runs],
                submitted_sql_statements=[r['telemetry']['statement_count'] for r in runs],
                source_scan_nodes=[sum((s.get('plan_stats') or {}).get('source_scan_nodes', 0) for s in r['telemetry']['stages']) for r in runs],
                peak_intermediate_bytes=[r['telemetry']['peak_intermediate_bytes'] for r in runs]))
    for mode in ('reference', 'shared'):
        statements = {n for s in summaries if s['mode'] == mode for n in s['submitted_sql_statements']}
        if len(statements) != 1:
            raise ValueError(f'Statement count changed with concept/row cardinality: {mode}')
    for p in definitions:
        if hashlib.sha256(p.read_bytes()).hexdigest() != hashes[str(p.relative_to(ROOT))]:
            raise ValueError('Probe definitions changed during execution; discard this run')
    report.update(independent_oracle_mismatches=mismatches, summary=summaries, definition_hashes=hashes,trials_per_mode=args.trials,
                  scope='Small synthetic primitive evaluation only; no full-profile/scale or general speedup claim',
                  cache_condition='Alternating order; process/server cache warmness uncontrolled, not OS-cold',
                  wall_ms=(time.perf_counter()-started)*1000)
    (out/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(f'PASS: {len(report["runs"])} nine-domain primitive runs; independent grain/quantile parity; private staging/cleanup; no scale claim')


if __name__ == '__main__':
    main()
