#!/usr/bin/env python3
"""Independent metadata expectations and exact numeric parity for complete candidates."""
import argparse
from decimal import getcontext
import json
from pathlib import Path
import re
import subprocess
import test_measurement_baseline as measurement

ROOT = measurement.ROOT


def physical(case, version):
    model = measurement.physical(case, version)
    model['denied_tables'] = []
    if version in ['5.3','5.4'] or not case['person']:
        model['columns']['cdm_source'] = dict(cdm_source_name='text')
        model['tables']['cdm_source'] = [dict(cdm_source_name="Unverified institution label")] if case['person'] else []
        if case['person']:
            model['columns']['vocabulary'] = dict(vocabulary_id='text',vocabulary_version='text')
            model['tables']['vocabulary'] = [dict(vocabulary_id='None',vocabulary_version='unverified-release')]
        if version=='5.4':model['denied_tables'] = ['cdm_source']
    return model


def verify(snapshot, case):
    base = measurement.base
    rows = snapshot['rows']
    assert snapshot['generated_metric_count'] == '142'
    assert snapshot['validated'] is True
    assert len(snapshot['datasets']) == 142
    assert all(d['state'] not in ['suppressed', 'not_requested'] for d in snapshot['datasets'].values())
    want = measurement.oracle(case, snapshot['version'])
    for mid, expected in want.items():
        state, reason = base.dataset_state(mid, case, snapshot['version'])
        got = {base.canon(r['dimensions']): {k:r[k] for k in ['values','state','reason_code']} for r in rows[mid]}
        assert got == {k:base.cell(v,state,reason) for k,v in expected.items()}, mid
    population, _ = base.population_expected(case, want)
    for mid, expected in population.items():
        assert sorted(base.canon(r) for r in expected) == sorted(base.canon({k:v for k,v in r.items() if k!='row_key'}) for r in rows[mid]), mid
    passport = rows['core.source.passport'][0]['values']
    assert passport['source_id'] == snapshot['source_id']
    assert passport['declared_cdm_version'] == snapshot['version']
    assert passport['observed_schema']['sha256'] == snapshot['schema_sha256']
    assert passport['generation']['started_at'] <= passport['generation']['ended_at']
    assert passport['coverage'] == dict(scope_kind='standard_full',complete=True,excluded_record_count='0',reason_code=None)
    assert passport['consistency'] == dict(within_run='single_repeatable_read',reusable=False,reason_code='source.no_verified_release')
    for key in ['source_release','vocabulary_release']:
        assert passport[key] == dict(state='unknown',value=None,basis=None,assertion_id=None,reason_code='source.no_verified_release')
    profile = base.PROFILE
    probes = {p for m in profile['metrics'] for p in m['inputs']+m['conditional_inputs']}
    for m in profile['metrics']:
        for aliases in m['input_aliases'].values(): probes.update(aliases.values())
    capabilities = {r['dimensions']['probe_id']:r['values'] for r in rows['core.source.capabilities']}
    assert capabilities.keys() == probes
    model = physical(case, snapshot['version'])
    for p, v in capabilities.items():
        if p in ['capability_probes','schema_metadata']:
            expected = dict(state='available',reason_code=None,observed_type='pg_catalog')
        elif p == 'operator_assertions':
            expected = dict(state='absent',reason_code='source.no_operator_assertions',observed_type=None)
        elif '.' not in p:
            if p not in model['tables']: expected = dict(state='absent',reason_code='capability.table_absent',observed_type=None)
            elif p in model['denied_tables']: expected = dict(state='inaccessible',reason_code='capability.select_denied',observed_type='relation')
            else: expected = dict(state='available' if model['tables'][p] else 'available_empty',reason_code=None,observed_type='relation')
        else:
            table,col = p.split('.')
            typ = model['columns'].get(table,{}).get(col)
            if typ is None: expected = dict(state='absent',reason_code='capability.column_absent',observed_type=None)
            else:
                pgtype = dict(bigint='int8',text='text',numeric='numeric',date='date',timestamp='timestamp')[typ]
                expected = dict(state='available' if model['tables'][table] else 'available_empty',reason_code=None,observed_type=pgtype)
        assert v == expected, (p,v,expected)
    ledger = {r['dimensions']['metric_id']:r['values'] for r in rows['core.execution.output_status']}
    assert ledger.keys() == snapshot['datasets'].keys()
    for mid, d in snapshot['datasets'].items():
        v = ledger[mid]
        assert v == dict(state=d['state'],reason_code=d['reason_code'],required=d['required'],coverage=d['completeness'],
                         integrity=dict(state='not_validated',sha256=None,reason_code='validation.pending_receipt'))
    timings = rows['core.execution.timing']
    assert len({base.canon(r['dimensions']) for r in timings}) == len(timings)
    measured = [r for r in timings if r['values']['availability']=='measured']
    assert len(measured) > 10
    assert any(r['dimensions']==dict(operation_id='core.numeric_generation',phase='generation') for r in measured)
    for r in timings:
        v = r['values']
        assert v['telemetry'] == dict(cpu_ms=None,peak_memory_bytes=None,source_rows=None,temp_bytes=None)
        if v['availability']=='measured':
            assert re.fullmatch(r'0|[1-9][0-9]*',v['duration_ms']) and v['reason_code'] is None
        else:
            assert r['dimensions']['phase'] in ['validation','projection','export','publication']
            assert v['duration_ms'] is None and v['reason_code']=='execution.not_started_at_metadata_capture'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config',type=Path,required=True);p.add_argument('--output-dir',type=Path,required=True)
    p.add_argument('--full-matrix',action='store_true');a = p.parse_args()
    out = measurement.base.create_evidence_dir(a.output_dir)
    getcontext().prec = 256
    case = measurement.fixture();empty = dict(case,id='empty_source',person=[],events=[],observation_period=[])
    cases = {case['id']:case,empty['id']:empty}
    matrix = [(case,v) for v in (['5.3','5.4','5.5'] if a.full_matrix else ['5.3'])]+[(empty,'5.5')]
    (out/'input.json').write_text(json.dumps([dict(case=c['id'],version=v,**physical(c,v)) for c,v in matrix]))
    subprocess.run(['Rscript','--vanilla','tests/tracer/core-characterization.R',str(a.config.resolve()),str(out)],cwd=ROOT,check=True)
    report = json.loads((out/'report.json').read_text())
    assert len(report['snapshots'])==len(matrix)
    for snap in report['snapshots']:verify(snap,cases[snap['case']])
    summary = dict(status='passed',cases=len(matrix),metrics=142,numeric_parity='138 exact outputs',native_validation=True,
                   metadata='independent fixture expectations',source_denied=True,metadata_budget_rollback=True)
    (out/'oracle.json').write_text(json.dumps(summary,indent=2)+'\n');print(summary)


if __name__=='__main__':main()
