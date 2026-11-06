#!/usr/bin/env python3
"""Independent metadata expectations and exact numeric parity for complete candidates."""
import argparse
import hashlib
from decimal import getcontext
import json
from pathlib import Path
import re
import subprocess
import sys
import test_measurement_baseline as measurement

ROOT = measurement.ROOT


def verify_publication(out, report):
    """Compare exported rows with independently checked generated rows, not report flags alone."""
    proof = report['publication']
    snapshot = next(s for s in report['snapshots'] if s['source_id'] == proof['snapshot_source_id'])
    assert all(s['refresh_executed'] is True for s in report['snapshots'])
    for flag in ['source_and_aggregate_denied', 'exact_serving_bytes', 'context_mismatch_rejected',
                 'scope_revocation_isolated', 'offline_copy_retained']:
        assert proof[flag] is True, flag
    total_objects = 0
    for kind, publication in proof['publications'].items():
        directory = out / publication['directory']
        pointer = json.loads((directory / 'publication.json').read_text())
        assert pointer['root'] == publication['root']
        seen, catalogue, data = set(), {}, {}
        concepts, terminology = [], []
        expected_context = dict(contract_version='2.0.0', source_id=snapshot['source_id'],
                                publication_id=publication['publication_id'], release_id=proof['release_id'],
                                access_scope_id=publication['access_scope_id'], profile_id='core-characterization-v2',
                                profile_revision='2.0.0', profile_sha256=hashlib.sha256(
                                    (ROOT / 'inst/analysis/core-characterization-v2.json').read_bytes()).hexdigest())
        for key in ['publication_id', 'source_id', 'access_scope_id']:
            assert pointer[key] == expected_context[key], key

        def visit(descriptor):
            sha = descriptor['sha256']
            assert sha not in seen
            seen.add(sha)
            raw = (directory / 'objects' / (sha + '.json')).read_bytes()
            assert hashlib.sha256(raw).hexdigest() == sha
            assert str(len(raw)) == descriptor['bytes']
            doc = json.loads(raw)
            assert doc['kind'] == descriptor['kind']
            for key, value in expected_context.items():
                assert doc[key] == value, key
            if doc['kind'] == 'root':
                assert doc['scope_kind'] == publication['scope_kind']
                assert doc['expected_metric_count'] == '142'
                for key in ['catalogue', 'data', 'concepts', 'terminology']:
                    visit(doc[key])
            elif doc['kind'] == 'index':
                for child in doc['children']:
                    visit(child['object'])
            elif doc['kind'] == 'metric_catalogue':
                for entry in doc['entries']:
                    assert entry['metric_id'] not in catalogue
                    catalogue[entry['metric_id']] = entry
            elif doc['kind'] == 'data':
                data.setdefault(doc['metric_id'], []).extend(doc['rows'])
            elif doc['kind'] == 'concept_catalogue':
                concepts.extend(doc['entries'])
            elif doc['kind'] == 'terminology':
                terminology.extend(doc['entries'])
            else:
                raise AssertionError('Unhandled artifact kind: ' + doc['kind'])

        visit(pointer['root'])
        assert {p.name for p in (directory / 'objects').iterdir()} == {sha + '.json' for sha in seen}
        assert catalogue.keys() == snapshot['datasets'].keys()
        allowed = set(catalogue) if kind == 'full' else {'core.person.count', 'core.person.gender_count'}
        # Saved browse metadata is derived only from retained typed dimensions.
        # Raw source labels/values and omitted metrics cannot add concepts.
        ids = set()
        for mid in allowed:
            for row in snapshot['rows'][mid]:
                if row['state'] == 'suppressed':
                    continue
                for key, value in row['dimensions'].items():
                    if key.endswith('_tag') and isinstance(value, dict) and value['kind'] == 'id':
                        ids.add(value['value'])
                    elif key.endswith('_concept_id') and isinstance(value, str) and value != 'null':
                        ids.add(value)
        expected_concepts = [dict(concept_tag=dict(kind='id', value=value), label=None, label_state='unavailable')
                             for value in sorted(ids, key=int)]
        assert concepts == expected_concepts, 'Concept catalogue differs from retained dimensions'
        assert terminology == [dict(entry, domain_id=None) for entry in expected_concepts], \
            'Terminology differs from retained dimensions'
        for mid, dataset in catalogue.items():
            if mid in allowed:
                assert dataset == snapshot['datasets'][mid], mid
                assert sorted(measurement.base.canon(r) for r in data.get(mid, [])) == sorted(
                    measurement.base.canon(r) for r in snapshot['rows'][mid]), mid
            else:
                assert dataset == dict(snapshot['datasets'][mid], state='suppressed',
                                       reason_code='policy.output_omitted', rows='0'), mid
                assert mid not in data, mid
        if kind == 'projected':
            assert set(data) == allowed
            assert 'core.execution.output_status' not in data
            assert 'core.condition.observation_qualification_count' not in data
        total_objects += len(seen)
    assert proof['approved_objects_read'] == str(total_objects)
    return dict(status='passed', exports=2, exact_objects=total_objects, full_metrics=142,
                projected_metrics=2, denominator_closure=True, source_denied_serving=True)


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
                pgtype = dict(bigint='bigint',text='text',numeric='numeric',date='date',timestamp='timestamp without time zone')[typ]
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
    p.add_argument('--full-matrix',action='store_true')
    p.add_argument('--with-publication',action='store_true')
    p.add_argument('--state',type=Path);p.add_argument('--admin-host',default='/tmp')
    p.add_argument('--admin-user');p.add_argument('--port',type=int,default=5432);a = p.parse_args()
    if a.with_publication and not a.state:p.error('--with-publication requires --state')
    out = measurement.base.create_evidence_dir(a.output_dir)
    getcontext().prec = 256
    case = measurement.fixture();empty = dict(case,id='empty_source',person=[],events=[],observation_period=[])
    cases = {case['id']:case,empty['id']:empty}
    matrix = [(case,v) for v in (['5.3','5.4','5.5'] if a.full_matrix else ['5.3'])]+[(empty,'5.5')]
    (out/'input.json').write_text(json.dumps([dict(case=c['id'],version=v,**physical(c,v)) for c,v in matrix]))
    if a.with_publication:
        cmd=[sys.executable,'tools/test_result_serving.py','--test-script','core-characterization','--state',str(a.state.resolve()),
             '--config',str(a.config.resolve()),'--output-dir',str(out),'--admin-host',a.admin_host,'--port',str(a.port)]
        if a.admin_user:cmd.extend(['--admin-user',a.admin_user])
    else:cmd=['Rscript','--vanilla','tests/tracer/core-characterization.R',str(a.config.resolve()),str(out)]
    subprocess.run(cmd,cwd=ROOT,check=True)
    report = json.loads((out/'report.json').read_text())
    assert len(report['snapshots'])==len(matrix)
    for snap in report['snapshots']:verify(snap,cases[snap['case']])
    summary = dict(status='passed',cases=len(matrix),metrics=142,numeric_parity='138 exact outputs',native_validation=True,
                   metadata='independent fixture expectations',source_denied=True,metadata_budget_rollback=True)
    if a.with_publication:summary['publication']=verify_publication(out,report)
    (out/'oracle.json').write_text(json.dumps(summary,indent=2)+'\n');print(summary)


if __name__=='__main__':main()
