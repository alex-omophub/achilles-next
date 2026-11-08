#!/usr/bin/env python3
"""Opt-in full-profile paired comparator on capped synthetic fixtures, never scale tiers."""
import argparse
from decimal import getcontext,localcontext
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from postgresql_fixtures import Postgres,guard_database,identifier,literal,grants_sql,MARKER
from synthetic_cdm import generate,canonical,assets,plan,sha
from synthetic_cdm_database import load_preview,drop_preview
from synthetic_cdm_oracle import read_tables,expected,check_snapshot
from matched_reference_sql import Reference,PROFILE
from matched_reference_compare import compare_pair,check_metadata,check_expectations,artifact,need
import test_core_characterization as adversarial

ROOT=Path(__file__).resolve().parents[1]
TOOL_INPUTS=('tools/matched_reference_sql.py','tools/matched_reference_compare.py','tools/test_matched_reference.py',
    'tools/benchmark/matched_reference.R','tests/tracer/matched-reference.R','tools/test_result_serving.py',
    'tools/synthetic_cdm.py','tools/synthetic_cdm_database.py','tools/synthetic_cdm_oracle.py',
    'tools/test_core_characterization.py','tools/test_measurement_baseline.py','tools/test_domain_baseline.py','tools/test_population_baseline.py')


def tool_pins():return {p:sha((ROOT/p).read_bytes()) for p in TOOL_INPUTS}


def numerical_expectations(case,version):
    with localcontext() as context:
        context.prec=256
        base=adversarial.measurement.base;want=adversarial.measurement.oracle(case,version);rows={}
        for mid,groups in want.items():
            state,reason=base.dataset_state(mid,case,version)
            rows[mid]=[dict(dimensions=json.loads(dims),**base.cell(values,state,reason)) for dims,values in groups.items()]
        population,_=base.population_expected(case,want)
        rows.update({mid:[{k:r[k] for k in ['dimensions','values','state','reason_code']} for r in rs] for mid,rs in population.items()})
        need(len(rows)==138,'Incomplete independent adversarial expectations')
        return dict(kind='adversarial',rows=rows)


def load_model(pg,model,version):
    """Create only new marked schemas from the bundled adversarial fixture model."""
    guard_database(pg)
    raw=canonical(model)
    need(len(raw)<=32*1024**2 and len(model['tables'])<=64 and sum(len(rs) for rs in model['tables'].values())<=20000,'Fixture model budget exceeded')
    schema='cdm_synthetic_'+secrets.token_hex(6);q=identifier(schema);digest=sha(raw);marker=MARKER+': preview:'+digest
    commands=['BEGIN;',"SET LOCAL statement_timeout='30s'; SET LOCAL lock_timeout='2s';",f'CREATE SCHEMA {q}; REVOKE ALL ON SCHEMA {q} FROM PUBLIC; COMMENT ON SCHEMA {q} IS {literal(marker)};']
    for table,cols in model['columns'].items():
        need(table in model['tables'],'Missing fixture table')
        for typ in cols.values():need(typ in ['bigint','text','numeric','date','timestamp'],'Unapproved fixture column type')
        fields=','.join(identifier(c)+' '+typ for c,typ in cols.items());target=q+'.'+identifier(table)
        commands.append(f'CREATE TABLE {target} ({fields});')
        if model['tables'][table]:commands.append(f'INSERT INTO {target} SELECT * FROM jsonb_to_recordset({literal(json.dumps(model["tables"][table]))}::jsonb) x({fields});')
    commands.append(grants_sql(schema))
    for table in model.get('denied_tables',[]):commands.append(f'REVOKE SELECT ON {q}.{identifier(table)} FROM achilles_next_runner;')
    commands.append('COMMIT;');pg.run('\n'.join(commands))
    return dict(schema=schema,marker=marker,manifest_sha256=digest,version=version)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--state',type=Path,required=True);p.add_argument('--config',type=Path,required=True);p.add_argument('--output-dir',type=Path,required=True)
    p.add_argument('--full-matrix',action='store_true');p.add_argument('--admin-host',default='/tmp');p.add_argument('--admin-user');p.add_argument('--port',type=int,default=5432)
    a=p.parse_args();pg=Postgres(a.state.resolve());guard_database(pg)
    a.output_dir.mkdir(mode=0o700);out=a.output_dir.resolve();getcontext().prec=256
    pins=tool_pins()
    versions=['5.3','5.4','5.5'] if a.full_matrix else ['5.5'];loaded=[];inputs=[];models={};case_oracles={};receipts=[]
    try:
        for version in versions:
            case_id='generated-'+version;directory=out/case_id
            generate(directory,version=version);one=load_preview(pg,directory);loaded.append(one)
            manifest,tables=read_tables(directory)
            cols=assets(plan(version=version))[2]
            models[case_id]=dict(columns={t:{c['name']:c['type'] for c in cs} for t,cs in cols.items()},tables=tables,denied_tables=[])
            inputs.append(dict(one,case_id=case_id));case_oracles[case_id]=expected(directory)
        directory=out/'empty-5.5';generate(directory,people=0,events=0);one=load_preview(pg,directory);loaded.append(one)
        _,tables=read_tables(directory);models['empty-5.5']=dict(models['generated-'+versions[-1]],tables=tables)
        inputs.append(dict(one,case_id='empty-5.5'));case_oracles['empty-5.5']=expected(directory)
        case=adversarial.measurement.fixture()
        for version in versions:
            case_id='adversarial-'+version;model=adversarial.physical(case,version);models[case_id]=model
            one=load_model(pg,model,version);loaded.append(one);inputs.append(dict(one,case_id=case_id))
        for one in inputs:
            model=models[one['case_id']];compiled=Reference(one['schema'],model['columns'],model.get('denied_tables',[])).manifest()
            name=one['case_id']+'-reference.json';(out/name).write_text(json.dumps(compiled,indent=2)+'\n');one['compiled']=name
            one['model']=one['case_id']+'-model.json';(out/one['model']).write_text(json.dumps(model,indent=2)+'\n')
            expectations=numerical_expectations(case,one['version']) if one['case_id'].startswith('adversarial-') else dict(kind='generated',oracle=case_oracles[one['case_id']])
            one['expectations']=one['case_id']+'-expectations.json';(out/one['expectations']).write_text(json.dumps(expectations,indent=2)+'\n')
        (out/'input.json').write_bytes(canonical(inputs))
        env=dict(os.environ,ACHILLES_NEXT_FIXTURE_STATE=str(a.state.resolve()),ACHILLES_NEXT_REFERENCE_PYTHON=sys.executable)
        cmd=[sys.executable,'tools/test_result_serving.py','--test-script','matched-reference','--state',str(a.state.resolve()),'--config',str(a.config.resolve()),'--output-dir',str(out),'--admin-host',a.admin_host,'--port',str(a.port)]
        if a.admin_user:cmd+=['--admin-user',a.admin_user]
        subprocess.run(cmd,cwd=ROOT,env=env,check=True)
        report=json.loads((out/'results.json').read_text());pairs=report['pairs']
        need(len(pairs)==len(inputs),'Missing paired fixture')
        for one,pair in zip(inputs,pairs):
            case_id=one['case_id'];need(pair['case_id']==case_id and pair['version']==one['version'] and pair['source_id']=='fixture:matched:'+one['manifest_sha256'],'Source binding differs')
            need(pair['imported_witnesses']==[pair['snapshot_witness']]*2 and int(pair['latest_people_after_capture'])==int(pair['captured_people'])+1,'Matched snapshot import proof failed')
            need(pair['producer_denied'] and pair['serving_source_and_aggregate_denied'],'Source isolation proof missing')
            paths=pair['paths'];need(set(paths)=={'optimized','reference'},'Missing execution path')
            comparison=compare_pair(paths['optimized']['snapshot'],paths['reference']['snapshot']);exports={}
            for path,execution in paths.items():
                snap=execution['snapshot'];need(snap['validated'],'Native candidate was not validated')
                check_metadata(snap,models[case_id])
                if case_id.startswith('adversarial-'):adversarial.verify(snap,case)
                else:check_snapshot(snap,case_oracles[case_id])
                check_expectations(snap,json.loads((out/one['expectations']).read_text()))
                need(set(execution['publications'])=={'full','projected'},'Missing publication scope')
                exports[path]={}
                for kind,pub in execution['publications'].items():
                    want=list(snap['datasets']) if kind=='full' else ['core.person.count','core.person.gender_count']
                    need(set(pub['policy']['allow_metrics'])==set(want) and pub['served_objects']==2,'Publication/serving scope mismatch')
                    need(pub['policy']==paths['optimized']['publications'][kind]['policy'],'Unequal paired policies')
                    exports[path][kind]=artifact(out/pub['directory'],pub,snap)
            receipts.append(dict(case_id=case_id,version=one['version'],source_sha256=one['manifest_sha256'],**comparison,exports=exports,
                imported_snapshot=pair['captured_snapshot'],snapshot_witness=pair['snapshot_witness'],post_snapshot_write_excluded=True))
        need(tool_pins()==pins,'Comparator inputs changed during execution')
    finally:
        failures=[]
        for one in reversed(loaded):
            try:drop_preview(pg,one)
            except Exception as e:failures.append(e)
        if failures:raise RuntimeError('Matched comparator cleanup failed') from failures[0]
    result=dict(status='passed',cases=receipts,source_cleanup_completed=True,tool_pins=pins,
        qualification='complete small-fixture matched 142-output/validation/projection/publication/export parity only; no scale, CPU/memory or speedup qualification',
        profile_sha256=hashlib.sha256((ROOT/'inst/analysis/core-characterization-v2.json').read_bytes()).hexdigest(),
        shared_boundary=['source capability preflight/provenance serialization','row keys/denominator binding/exact codec','bounded aggregate writer/store','native validation','policy/projection/publication/export and serving API'],
        independent_analysis='per-output unfused SQL, multirange observation union and raw-row integer-rank summaries; no producer classification/report SQL')
    (out/'oracle.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'PASS: {len(receipts)} matched small-fixture pairs; all142 outputs, complete full/projected exports, imported snapshots and independent expectations; sources removed; no scale qualification')


if __name__=='__main__':main()
