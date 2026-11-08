#!/usr/bin/env python3
"""Opt-in resource/phase instrumentation of one tiny matched core pair."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
_saved=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    from postgresql_fixtures import Postgres,guard_database,identifier,literal
    from synthetic_cdm import generate,assets,plan,canonical,sha
    from synthetic_cdm_database import load_preview,drop_preview
    from synthetic_cdm_oracle import read_tables,expected
    from matched_reference_sql import Reference
    from matched_reference_compare import compare_pair,check_metadata,check_expectations,artifact
finally:sys.path[:]=_saved
from resource_telemetry import limits,observe
from telemetry_report import phases

FILES=['tools/benchmark/telemetry.py','tools/benchmark/resource_telemetry.py','tools/benchmark/telemetry_report.py','tools/benchmark/resource_telemetry.R',
 'tests/tracer/resource-telemetry.R','tools/benchmark/matched_reference.R','tools/benchmark/implementation_identity.R',
 'tools/matched_reference_sql.py','tools/matched_reference_compare.py','tools/synthetic_cdm.py','tools/synthetic_cdm_database.py','tools/synthetic_cdm_oracle.py']


def pins():return {p:sha((ROOT/p).read_bytes()) for p in FILES}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--state',type=Path,required=True);p.add_argument('--config',type=Path,required=True);p.add_argument('--output-dir',type=Path,required=True)
    p.add_argument('--with-projected',action='store_true');p.add_argument('--interval',type=float,default=.5);p.add_argument('--wall-seconds',type=float,default=600)
    p.add_argument('--rss-limit-bytes',type=int,default=4*1024**3);p.add_argument('--output-limit-bytes',type=int,default=256*1024**2);p.add_argument('--min-free-bytes',type=int,default=64*1024**2);p.add_argument('--cgroup',type=Path)
    a=p.parse_args();limits(a.interval,a.wall_seconds,a.rss_limit_bytes,a.output_limit_bytes,a.min_free_bytes)
    out=a.output_dir.resolve()
    if out.is_relative_to(ROOT) or a.output_dir.is_symlink():p.error('Use a new output directory outside the package checkout')
    pg=Postgres(a.state.resolve());guard_database(pg);out.mkdir(mode=0o700)
    before=pins();loaded=None
    try:
        source=out/'source';generate(source,people=4,events=24);loaded=load_preview(pg,source)
        _,tables=read_tables(source);cols=assets(plan())[2];model=dict(columns={t:{c['name']:c['type'] for c in cs} for t,cs in cols.items()},tables=tables,denied_tables=[])
        (out/'model.json').write_text(json.dumps(model));(out/'expectations.json').write_text(json.dumps(dict(kind='generated',oracle=expected(source))))
        (out/'compiled.json').write_text(json.dumps(Reference(loaded['schema'],model['columns']).manifest()))
        (out/'input.json').write_bytes(canonical(dict(source=loaded,nonce=secrets.token_hex(6),with_projected=a.with_projected)))
        protocol=out/'protocol';protocol.mkdir(mode=0o700)
        for name in ['tests/tracer/resource-telemetry.R','tools/benchmark/resource_telemetry.R','tools/benchmark/matched_reference.R','tools/benchmark/implementation_identity.R']:
            shutil.copyfile(ROOT/name,protocol/Path(name).name)
            if sha((protocol/Path(name).name).read_bytes())!=before[name]:raise ValueError('Frozen protocol differs')
        env=dict(os.environ,ACHILLES_NEXT_FIXTURE_STATE=str(a.state.resolve()),ACHILLES_NEXT_REFERENCE_PYTHON=sys.executable,ACHILLES_NEXT_TELEMETRY_PROTOCOL_DIR=str(protocol))
        result=observe(['Rscript','--vanilla',str(protocol/'resource-telemetry.R'),str(a.config.resolve()),str(out)],out,env=env,interval=a.interval,wall_seconds=a.wall_seconds,
            rss_limit=a.rss_limit_bytes,output_limit=a.output_limit_bytes,min_free=a.min_free_bytes,cgroup=a.cgroup)
        trace=phases(out/'phases.jsonl') if (out/'phases.jsonl').exists() else dict(complete=False,reason='worker_failed_before_observer')
        (out/'phase-report.json').write_text(json.dumps(trace,indent=2)+'\n')
        if result['status']!='completed':raise RuntimeError('Telemetry worker failed/stopped; measurements retained')
        if not trace['complete'] or trace['summary']['status']!='passed':raise ValueError('Incomplete phase trace/cleanup')
        report=json.loads((out/'results.json').read_text());paths=report['paths'];compare_pair(paths['optimized']['snapshot'],paths['reference']['snapshot'])
        exports={}
        for path,data in paths.items():
            compare_pair(data['snapshot'],report['baseline_paths'][path])
            check_metadata(data['snapshot'],model);check_expectations(data['snapshot'],json.loads((out/'expectations.json').read_text()))
            exports[path]={kind:artifact(out/pub['directory'],pub,data['snapshot']) for kind,pub in report['publications'][path].items()}
        if report['cancel_probe']!=dict(passed=True,previous_publication_preserved=True,after_page_write=True):raise ValueError('Cancellation probe failed')
        if pins()!=before:raise ValueError('Telemetry sources changed during run')
    finally:
        if loaded is not None:drop_preview(pg,loaded)
    state=json.loads((out/'fixture-state.json').read_text());names=[loaded['schema'],state['results_schema'],state['serving_schema']]
    if pg.rows('SELECT nspname FROM pg_namespace WHERE nspname IN ('+','.join(map(literal,names))+')'):raise ValueError('Disposable namespace cleanup incomplete')
    temp=pg.value("SELECT has_database_privilege('achilles_next_runner',current_database(),'TEMPORARY')::text")=='true'
    if temp!=state['runner_had_temp']:raise ValueError('Fixture TEMP not restored')
    receipt=dict(status='passed',qualifying=False,kind='small_fixture_instrumentation_proof',code_sha256=before,profile_sha256=sha((ROOT/'inst/analysis/core-characterization-v2.json').read_bytes()),
        process=result,exports=exports,cancel_probe=report['cancel_probe'],cleanup=dict(namespaces_removed=True,fixture_TEMP_restored=True),
        platform=platform.platform(),cache='fresh R/JVM worker; database/server/OS caches uncontrolled; no restart/drop-cache',
        limits='sampled cooperative stop; no hard OS reservation or automatic SIGKILL',missing='no verified reference allocation, cgroup database/cache inclusion, browser heap, exclusive DB CPU or separately isolated revision-trigger cost',
        phase_trace_sha256=sha((out/'phases.jsonl').read_bytes()),source_manifest_sha256=loaded['manifest_sha256'])
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('PASS: tiny matched142-output telemetry, native publication/export and cancellation cleanup; resource observations scoped; no scale qualification')


if __name__=='__main__':main()
