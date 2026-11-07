#!/usr/bin/env python3
"""Private-output paired routing experiment; no source DB access or format enablement."""
import argparse
import json
from pathlib import Path
import platform
import random
import resource
import statistics
import subprocess
import sys
import time
import tracemalloc

import saved_representation as rep

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = [Path(__file__).resolve(), Path(rep.__file__).resolve(), ROOT/'tools/benchmark/representation.R',
           ROOT/'tools/benchmark/implementation_identity.R']
RUN_CODE = {str(p.relative_to(ROOT)): rep.digest(p.read_bytes()) for p in SCRIPTS}


def inventory(directory):
    paths = []
    for path in (directory/'objects').iterdir():
        rep.need(len(paths) < 100000, 'Inventory object limit'); paths.append(path)
    size = 0; h = rep.hashlib.sha256()
    for path in sorted(paths):
        raw = rep.read_file(path, max(rep.LIMITS.values())); rep.need(rep.digest(raw) == path.stem, 'Inventory integrity')
        size += len(raw); h.update((path.name+'\n'+rep.digest(raw)+'\n').encode())
    return dict(object_count=len(paths), object_bytes=size, payload_inventory_sha256=h.hexdigest())


def worker(job):
    traced = job.get('measure_memory',False)
    if tracemalloc.is_tracing(): tracemalloc.stop()
    if traced: tracemalloc.start()
    started = time.perf_counter(); cpu = time.process_time()
    result = {}; directory = Path(job['directory'])
    if job['phase'] == 'export':
        directory.mkdir(mode=0o700)
        rep.copy_artifact(job['source'], directory/'artifact')
        if job['strategy'] == 'flat':
            result['manifest_sha256'] = rep.build_flat(directory, job['pin'])
        result['inventory'] = inventory(directory/'artifact')
        result['total_export_bytes'] = sum(p.stat().st_size for p in directory.rglob('*') if p.is_file())
    elif job['phase'] == 'native':
        output = directory/'native-validation.json'
        completed = subprocess.run(['Rscript', '--vanilla', 'tools/benchmark/representation.R', 'validate',
                                    str(directory/'artifact'), str(output)], cwd=ROOT, capture_output=True, text=True)
        (directory/'native-validation.log').write_text(completed.stdout+completed.stderr); completed.check_returncode()
        native = json.loads(output.read_text()); rep.need(native['status'] == 'passed', 'Native validation failed')
        result['native_elapsed_seconds'] = native['elapsed_seconds']; result['native_cpu_seconds'] = native['cpu_seconds']
        result['child_peak_rss_platform_units'] = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    else:
        initial = time.perf_counter()
        reader = rep.Tree(directory/'artifact', job['pin']) if job['strategy'] == 'tree' else rep.Flat(directory, job['pin'], job['manifest_sha256'])
        result['open_seconds'] = time.perf_counter()-initial
        latencies = []
        try:
            queries = job['queries'][:job['initial_queries']] if job['phase'] == 'fresh_read' else job['queries']
            for query in queries:
                start = time.perf_counter(); sha, raw = reader.lookup(query['branch'], query['key'])
                latencies.append(time.perf_counter()-start)
                rep.need(sha == query['expected_sha256'], 'Routing parity failure')
                if sha is not None: rep.need(rep.digest(raw) == sha, 'Returned byte mismatch')
            result['verified_io'] = dict(reader.pages.stats)
        finally:
            reader.close()
        result['query_seconds'] = latencies
        result['first_lookup_including_open_seconds'] = result['open_seconds']+latencies[0]
        result['initial_view_including_open_seconds'] = result['open_seconds']+sum(latencies[:job['initial_queries']])
        result['read_parity'] = True
    result.update(phase=job['phase'], strategy=job['strategy'], wall_seconds=time.perf_counter()-started,
                  python_cpu_seconds=time.process_time()-cpu, python_peak_traced_bytes=tracemalloc.get_traced_memory()[1] if traced else None,
                  memory_instrumentation_enabled=traced,
                  process_peak_rss_platform_units=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    return result


def run_job(out, name, job):
    rep.need(RUN_CODE == {str(p.relative_to(ROOT)):rep.digest(p.read_bytes()) for p in SCRIPTS}, 'Benchmark code changed during run')
    config = out/(name+'.job.json'); config.write_bytes(rep.canonical(job))
    start = time.perf_counter()
    completed = subprocess.run([sys.executable, str(Path(__file__).resolve()), '--worker', str(config)],
                               cwd=ROOT, capture_output=True, text=True)
    (out/(name+'.log')).write_text(completed.stdout+completed.stderr); completed.check_returncode()
    rep.need(RUN_CODE == {str(p.relative_to(ROOT)):rep.digest(p.read_bytes()) for p in SCRIPTS}, 'Benchmark code changed during worker')
    result = json.loads(completed.stdout); result['fresh_process_total_seconds'] = time.perf_counter()-start
    (out/(name+'.result.json')).write_bytes(rep.canonical(result))
    return result


def query_sample(source, pin, size, seed):
    rng = random.Random(seed); chosen = []; total = 0; person = None; catalogue = None
    tree = rep.Tree(source, pin)
    try:
        for branch, lo, hi, descriptor in tree.routes():
            query = dict(branch=branch, key=lo, expected_sha256=descriptor['sha256'])
            if branch == 'data' and lo.startswith('core.person.count|'): person = query
            if branch == 'metric_catalogue': catalogue = query
            total += 1
            if len(chosen) < size: chosen.append(query)
            elif (index := rng.randrange(total)) < size: chosen[index] = query
    finally:
        tree.close()
    rep.need(chosen, 'No selectable partitions')
    # First query is a real PERSON summary where available; otherwise a
    # deterministic catalogue partition in the explicitly routing-only fixture.
    first = person or chosen[0]
    queries = [first] + ([catalogue] if catalogue else []) + chosen
    return queries, total, 2 if catalogue else 1


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--worker':
        print(json.dumps(worker(json.loads(Path(sys.argv[2]).read_text())))); return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, action='append', default=[])
    parser.add_argument('--catalogues', default='512,65536,131072')
    parser.add_argument('--trials', type=int, choices=range(1,4), default=3)
    parser.add_argument('--queries', type=int, choices=range(1,101), default=64)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    try: sizes = [int(n) for n in args.catalogues.split(',')] if args.catalogues else []
    except ValueError: parser.error('Use comma-separated integer catalogue sizes')
    if len(sizes)>4 or len(set(sizes))!=len(sizes) or any(not 1<=n<=262144 for n in sizes):
        parser.error('Use up to four distinct sizes from 1 to 262144')
    if not sizes and not args.artifact: parser.error('Select at least one input')
    out = args.output_dir.resolve()
    if out.exists() or args.output_dir.is_symlink() or out.is_relative_to(ROOT): parser.error('Use a new private output directory outside the checkout')
    out.mkdir(mode=0o700, parents=True)
    report = dict(code_sha256=RUN_CODE,environment=dict(python=sys.version, sqlite=rep.sqlite3.sqlite_version, platform=platform.platform()),
                  protocol=dict(seed=20261107, trials=args.trials, query_sample=args.queries, decoded_page_cache_bytes=0,
                    sqlite_cache_kib=64, flat_index_max_bytes=rep.INDEX_LIMIT, page_max_bytes=rep.LIMITS,
                    memory='Separate traced session for Python allocations; timing sessions untraced. Process/child ru_maxrss in platform-native units; native allocations not included in tracemalloc',
                    cache='Fresh subprocess and same-process session separately; OS cache uncontrolled, never OS-cold',
                    io='Verified JSON and flat-index bytes; SQLite internal I/O and OS cache I/O not measured',
                    semantic_validation='Native full artifact validation for approved-core copies once per strategy; routing fixtures are not publications'), cases=[])
    sources = []
    for i, path in enumerate(args.artifact): sources.append((f'approved-{i}', path.resolve(strict=True)))
    for size in sizes:
        path = out/f'catalogue-{size}'; path.mkdir(mode=0o700)
        completed = subprocess.run(['Rscript', '--vanilla', 'tools/benchmark/representation.R', 'catalogue', str(path), str(size)],
                                   cwd=ROOT, capture_output=True, text=True)
        (out/f'catalogue-{size}.log').write_text(completed.stdout+completed.stderr)
        completed.check_returncode()
        sources.append((f'catalogue-{size}', path))
    rng = random.Random(20261107)
    for case_id, source in sources:
        pin = rep.origin(source); queries, parts, initial_queries = query_sample(source, pin, args.queries, 20261107)
        case = dict(id=case_id, source=str(source), pin=pin, partitions=parts, queries=queries, exports=[], samples=[], native=[], memory=[])
        for trial in range(args.trials):
            order = ['tree','flat']; rng.shuffle(order)
            case.setdefault('paired_order',[]).append(order)
            inventories = []
            for strategy in order:
                directory = out/f'{case_id}-{trial}-{strategy}'
                job = dict(phase='export',strategy=strategy,source=str(source),directory=str(directory),pin=pin)
                exported = run_job(out,f'{case_id}-{trial}-{strategy}-export',job)
                exported.update(trial=trial); case['exports'].append(exported); inventories.append(exported['inventory'])
                base = dict(strategy=strategy,directory=str(directory),pin=pin,queries=queries,initial_queries=initial_queries,
                            manifest_sha256=exported.get('manifest_sha256'))
                for phase in ['fresh_read','session_read']:
                    sample = run_job(out,f'{case_id}-{trial}-{strategy}-{phase}',dict(base,phase=phase))
                    sample.update(trial=trial); case['samples'].append(sample)
                if trial == 0:
                    case['memory'].append(run_job(out,f'{case_id}-{strategy}-memory',dict(base,phase='session_read',measure_memory=True)))
                if trial == 0 and pin['scope'] == 'approved_core_artifact':
                    native = run_job(out,f'{case_id}-{strategy}-native',dict(base,phase='native'))
                    case['native'].append(native)
            rep.need(inventories[0] == inventories[1], 'Export payloads differ')
        case['summary'] = []
        for strategy in ['tree','flat']:
            fresh = [s for s in case['samples'] if s['strategy']==strategy and s['phase']=='fresh_read']
            session = [s for s in case['samples'] if s['strategy']==strategy and s['phase']=='session_read']
            latencies = sorted(t for s in session for t in s['query_seconds'][1:])
            case['summary'].append(dict(strategy=strategy,
                fresh_first_median_ms=1000*statistics.median(s['first_lookup_including_open_seconds'] for s in fresh),
                initial_view_median_ms=1000*statistics.median(s['initial_view_including_open_seconds'] for s in fresh),
                session_lookup_median_ms=1000*statistics.median(latencies),
                session_lookup_p95_ms=1000*latencies[min(len(latencies)-1,int(len(latencies)*.95))],
                python_peak_traced_bytes=next(s['python_peak_traced_bytes'] for s in case['memory'] if s['strategy']==strategy),
                verified_index_bytes=fresh[0]['verified_io'].get('verified_index_bytes',0),
                export_bytes=next(s['total_export_bytes'] for s in case['exports'] if s['strategy']==strategy)))
        report['cases'].append(case)
        (out/'report.json').write_bytes(rep.canonical(report))
        print(json.dumps(dict(case=case_id,summary=case['summary'])),flush=True)
    report['status'] = 'passed'; (out/'report.json').write_bytes(rep.canonical(report))


if __name__ == '__main__': main()
