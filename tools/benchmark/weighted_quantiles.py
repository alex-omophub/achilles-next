#!/usr/bin/env python3
"""Check exact PostgreSQL quantile parity and optionally benchmark native reports."""
import argparse
from decimal import Decimal
import hashlib
import json
import math
from pathlib import Path
import random
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
PROBABILITIES = [('p10', 1, 10), ('p25', 1, 4), ('p50', 1, 2), ('p75', 3, 4), ('p90', 9, 10)]


def normalized(value):
    text = format(Decimal(value), 'f')
    if '.' in text:
        text = text.rstrip('0').rstrip('.')
    return '0' if text in ('0', '-0') else text


def exact_sum(weighted):
    # Integer coefficients avoid Decimal's finite arithmetic context too.
    parts = [(normalized(v), int(w)) for v, w in weighted]
    scale = max((len(v.split('.')[1]) if '.' in v else 0 for v, _ in parts), default=0)
    total = 0
    for value, weight in parts:
        whole, _, fraction = value.partition('.')
        total += int(whole + fraction) * 10 ** (scale - len(fraction)) * weight
    sign = '-' if total < 0 else ''
    digits = str(abs(total)).zfill(scale + 1)
    return normalized(sign + (digits[:-scale] + '.' + digits[-scale:] if scale else digits))


def sorted_oracle(values):
    finite = sorted([v for v in values if v is not None and Decimal(v).is_finite()], key=Decimal)
    if not values:
        return None  # No observed group; distinct from an observed zero-n group.
    if not finite:
        return {k: ('0' if k == 'n' else None) for k in ['n', 'sum', 'min', 'max', 'mean_numerator', 'mean_denominator', *[p[0] for p in PROBABILITIES]]}
    n = len(finite)
    total = exact_sum([(v, 1) for v in finite])
    return {'n': str(n), 'sum': total, 'min': normalized(finite[0]), 'max': normalized(finite[-1]),
            'mean_numerator': total, 'mean_denominator': str(n),
            **{key: normalized(finite[(a * n + b - 1) // b - 1]) for key, a, b in PROBABILITIES}}


def compressed_oracle(weights):
    """Huge synthetic weights cannot be expanded; independent Python integer ranks."""
    ordered = sorted(weights, key=lambda pair: Decimal(pair[0]))
    n = sum(int(w) for _, w in ordered)
    total = exact_sum(ordered)
    quantiles = {}
    for key, a, b in PROBABILITIES:
        rank = (a * n + b - 1) // b
        cumulative = 0
        for value, weight in ordered:
            cumulative += int(weight)
            if cumulative >= rank:
                quantiles[key] = normalized(value)
                break
    return {'n': str(n), 'sum': total, 'min': normalized(ordered[0][0]), 'max': normalized(ordered[-1][0]),
            'mean_numerator': total, 'mean_denominator': str(n), **quantiles}


def cases():
    arrays = [[], [None, 'NaN', 'Infinity', '-Infinity'], ['-5'], ['-5', '1'], ['-5', '1', '1'],
              ['0'] * 9 + ['2.5'], ['-0.125', '-0.125', '0', '1.25', None],
              ['9007199254740993.125', '-9007199254740993.124', '0.000000000000000000000000001'],
              ['1', '1.00', '1.000', '-0.0', '0.00', '2.50']]
    rng = random.Random(20261030)
    pool = ['-100.125', '-5', '-0.00001', '0', '0', '1', '1', '2.5', '9007199254740993.125', None]
    arrays += [[rng.choice(pool) for _ in range(rng.randint(1, 40))] for _ in range(60)]
    result = [{'id': f'array_{i:02}', 'values': array, 'expected': sorted_oracle(array)} for i, array in enumerate(arrays)]
    for records, distinct in [(12, 7), (100000, 32), (100000, 4096), (100000, 100000)]:
        recipe = {'records': records, 'distinct': distinct}
        values = [format(Decimal(i % distinct) - Decimal(distinct // 2) + Decimal('0.125'), 'f') for i in range(records)]
        result.append({'id': f'recipe_{records}_{distinct}', 'recipe': recipe, 'expected': sorted_oracle(values)})
    for i, weights in enumerate([[['-5', '9007199254740993'], ['1.125', '1']],
                                [['-0.125', '1'], ['0', '9223372036854775807'], ['9007199254740993.125', '3']]]):
        result.append({'id': f'huge_weights_{i}', 'weights': weights, 'expected': compressed_oracle(weights),
                       'reference_limitation': 'Weight exceeds practical physical expansion; independently checked using Python integer cumulative ranks'})
    return result


def compare_bundles(a, b):
    """Compare every metric's semantic payload, excluding run/strategy identity."""
    ma = json.loads((a / 'manifest.json').read_text()); mb = json.loads((b / 'manifest.json').read_text())
    for field in ['profile', 'source', 'request', 'request_sha256', 'publication', 'eligible_for_current_pointer', 'disclosure']:
        if ma[field] != mb[field]:
            raise ValueError(f'Strategy changed {field}')
    for p in ma['outputs']:
        da = json.loads((a / p['path']).read_text()); db = json.loads((b / p['path']).read_text())
        for d in (da, db):
            for field in ['bundle_id', 'run_id']:
                d.pop(field)
            if d['metric_id'] == 'source.passport':
                d['rows'][0]['values'].pop('run_id')
        for doc in (da, db):
            if doc['metric_id'] == 'measurement.numeric_summary':
                for row in doc['rows'] or []:
                    if row['values'] is not None:
                        for field in ['sum', 'min', 'max', 'mean_numerator', *[p[0] for p in PROBABILITIES]]:
                            if row['values'][field] is not None:
                                row['values'][field] = normalized(row['values'][field])
        if da != db:
            raise ValueError(f'Strategy changed result payload: {p["metric_id"]}')


def validate_budgets(budgets):
    if not isinstance(budgets, dict):
        raise ValueError('Reviewed budgets must be an object')
    def finite(value, minimum):
        return type(value) in (int, float) and math.isfinite(value) and value >= minimum
    numeric = budgets.get('numeric_compute_materialize_ms', {})
    if not isinstance(numeric, dict) or any(not finite(v, 0) or v == 0 for v in numeric.values()):
        raise ValueError('Invalid reviewed numeric budget')
    regression = budgets.get('validated_slice_regression')
    if regression is not None and (not isinstance(regression, dict) or not finite(regression.get('multiplier'), 1) or not finite(regression.get('allowance_ms'), 0)):
        raise ValueError('Invalid reviewed regression budget')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True, help='Trusted local R fixture configuration')
    parser.add_argument('--output-dir', type=Path, required=True, help='New private evidence directory outside checkout')
    parser.add_argument('--budget-file', type=Path, help='Optional local reviewed thresholds; never a package default or automatic strategy switch')
    parser.add_argument('--benchmark', action='store_true', help='Also run five alternating trials of native reports on four bounded workloads')
    args = parser.parse_args()
    output = args.output_dir.resolve()
    if output.is_relative_to(ROOT) or output.exists():
        parser.error('Use a new evidence directory outside the package checkout')
    budgets = json.loads(args.budget_file.read_text()) if args.budget_file else {}
    validate_budgets(budgets)
    output.mkdir(parents=True, mode=0o700)
    oracle = cases()
    (output / 'oracle.json').write_text(json.dumps(oracle, indent=2) + '\n')
    definitions = [*sorted((ROOT / 'inst/sql/postgresql').glob('*.sql')), ROOT / 'tools/benchmark/weighted_quantiles.R', Path(__file__)]
    code_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in definitions}
    begin = time.perf_counter()
    subprocess.run(['Rscript', '--vanilla', str(ROOT / 'tools/benchmark/weighted_quantiles.R'),
                    str(args.config.resolve(strict=True)), str(output), 'benchmark' if args.benchmark else 'parity'], cwd=ROOT, check=True)
    report = json.loads((output / 'report.json').read_text())
    if report['parity_cases'] != len(oracle):
        raise ValueError('Missing parity cases')
    for pair in report.get('bundle_pairs', []):
        a, b = (output / pair[k] for k in ['reference', 'weighted'])
        compare_bundles(a, b)
        for bundle in (a, b):
            subprocess.run(['node', 'packages/contracts/tools/validate.mjs', str(bundle)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    report['harness_wall_ms'] = (time.perf_counter() - begin) * 1000
    for p in definitions:
        if hashlib.sha256(p.read_bytes()).hexdigest() != code_hashes[str(p.relative_to(ROOT))]:
            raise ValueError('Benchmark code changed during execution; discard this run')
    for name, digest in report['installed_sql_sha256'].items():
        if code_hashes.get('inst/sql/postgresql/' + name) != digest:
            raise ValueError('Installed SQL differs from the recorded source')
    report['definition_sha256'] = code_hashes
    report['validated_bundle_pairs'] = len(report.get('bundle_pairs', []))
    report['default_selection'] = 'reference; weighted is explicit opt-in, no automatic performance promotion'
    report['reviewed_budget_input'] = budgets or None
    summaries = {}
    for workload in report.get('workloads', []):
        rows = [r for r in report['trials'] if r['workload'] == workload['id'] and r['retained']]
        metrics = {}
        for strategy in ['reference', 'weighted']:
            samples = [r for r in rows if r['strategy'] == strategy]
            metrics[strategy] = {key: {'n': len(samples), 'median_ms': statistics.median(r[key] for r in samples),
                'min_ms': min(r[key] for r in samples), 'max_ms': max(r[key] for r in samples)}
                for key in ['numeric_compute_materialize_ms', 'generator_export_ms', 'validation_ms', 'validated_slice_ms']}
        ref = metrics['reference']['validated_slice_ms']['median_ms']; weighted = metrics['weighted']['validated_slice_ms']['median_ms']
        regression = budgets.get('validated_slice_regression')
        if regression:
            multiplier, allowance = regression['multiplier'], regression['allowance_ms']
            if type(multiplier) not in (int, float) or multiplier < 1 or type(allowance) not in (int, float) or allowance < 0:
                raise ValueError('Invalid reviewed regression budget')
            metrics['reviewed_regression_limit_ms'] = max(ref * multiplier, ref + allowance)
            metrics['within_reviewed_regression_limit'] = weighted <= metrics['reviewed_regression_limit_ms']
        budget = budgets.get('numeric_compute_materialize_ms', {}).get(workload['id'])
        if budget is not None and (type(budget) not in (int, float) or budget <= 0):
            raise ValueError('Invalid reviewed numeric budget')
        metrics['within_reviewed_numeric_budget'] = None if budget is None else metrics['weighted']['numeric_compute_materialize_ms']['median_ms'] <= budget
        summaries[workload['id']] = metrics
    report['summaries'] = summaries
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: {len(oracle)} exact quantile cases; {report["validated_bundle_pairs"]} native strategy pairs; reference remains default')


if __name__ == '__main__':
    main()
