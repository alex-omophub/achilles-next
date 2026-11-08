#!/usr/bin/env python3
"""Opt-in tiny CDM preview load and installed candidate validation; no large tiers."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from postgresql_fixtures import Postgres, guard_database
from synthetic_cdm import generate, verify, canonical
from synthetic_cdm_database import load_preview, drop_preview
from synthetic_cdm_oracle import expected, check_snapshot


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state',type=Path,required=True)
    parser.add_argument('--config',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True)
    parser.add_argument('--full-matrix',action='store_true')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1];pg=Postgres(args.state.resolve());guard_database(pg)
    args.output_dir.mkdir(mode=0o700);out=args.output_dir.resolve()
    loaded=[];proofs=[];oracles=[];cases=[]
    matrix=[('populated',v,20,1000) for v in (['5.3','5.4','5.5'] if args.full_matrix else ['5.5'])]+[('empty','5.5',0,0)]
    try:
        for kind,version,people,events in matrix:
            directory=out/(kind+'-'+version)
            manifest=generate(directory,people=people,events=events,version=version)
            verify(directory);oracle=expected(directory)
            for domain,spec in json.loads((root/'inst/analysis/core-characterization-v2.json').read_bytes())['domains'].items():
                if oracle['source_rows'][spec['table']]!=manifest['rows_per_domain'][domain]:raise ValueError('Source event apportionment mismatch')
                if oracle['actual_duplicate_rows'][domain]<manifest['scheduled_duplicate_rows'][domain]:raise ValueError('Duplicate bag rows lost')
            one=load_preview(pg,directory);loaded.append(one);cases.append((manifest,oracle))
            counts={table:int(pg.value('SELECT count(*) FROM "'+one['schema']+'"."'+table+'"')) for table in oracle['source_rows']}
            if counts!=oracle['source_rows']:raise ValueError('Loaded source row counts differ')
            oracles.append(oracle)
        (out/'input.json').write_bytes(canonical(loaded))
        env=dict(os.environ,ACHILLES_NEXT_FIXTURE_STATE=str(args.state.resolve()))
        subprocess.run(['Rscript','--vanilla','tests/tracer/synthetic-cdm.R',str(args.config.resolve()),str(out)],cwd=root,env=env,check=True)
        result=json.loads((out/'results.json').read_bytes())
        if len(result['snapshots'])!=len(cases):raise ValueError('Missing preview case')
        for one,snapshot,oracle in zip(loaded,result['snapshots'],oracles):
            if snapshot['manifest_sha256']!=one['manifest_sha256'] or not snapshot['validated'] or not snapshot['producer_source_access_revoked']:
                raise ValueError('Unverified preview result')
            if len(snapshot['datasets'])!=142:raise ValueError('Incomplete generated inventory')
            proofs.append(dict(version=one['version'],manifest_sha256=one['manifest_sha256'],**check_snapshot(snapshot,oracle)))
        report=dict(status='passed',cases=proofs,source_oracles=oracles,
                    qualification='tiny source generation/load/native validation and selected independent expectations only; no full execution comparator or scale evidence')
    finally:
        cleanup_errors=[]
        for one in reversed(loaded):
            try:drop_preview(pg,one)
            except Exception as error:cleanup_errors.append(error)
        if cleanup_errors:raise RuntimeError('Preview cleanup failed; inspect owned synthetic schemas') from cleanup_errors[0]
    report['source_cleanup_completed']=True
    (out/'oracle.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'PASS: {len(proofs)} tiny synthetic CDM cases; source row counts, duplicate lower bounds, selected independent counts/day sets/exact summaries and complete native validation; disposable sources removed; no full comparator or scale evidence')


if __name__=='__main__':main()
