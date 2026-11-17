#!/usr/bin/env python3
"""Independent metadata expectations and exact numeric parity for complete candidates."""
import argparse
from copy import deepcopy
from datetime import date
from collections import defaultdict
import hashlib
from decimal import getcontext
import json
from pathlib import Path
import re
import subprocess
import sys
import test_measurement_baseline as measurement

ROOT = measurement.ROOT

# Independent OMOP physical inputs: no report definitions or report totals enter
# the audit oracle. Duplicate physical event/observation rows remain countable.
AUDIT_DOMAINS = {
    'condition': ('condition_occurrence', 'condition_start_date'),
    'drug': ('drug_exposure', 'drug_exposure_start_date'),
    'procedure': ('procedure_occurrence', 'procedure_date'),
    'visit': ('visit_occurrence', 'visit_start_date'),
    'device': ('device_exposure', 'device_exposure_start_date'),
    'observation': ('observation', 'observation_date'),
    'death': ('death', 'death_date'),
    'specimen': ('specimen', 'specimen_date'),
    'measurement': ('measurement', 'measurement_date'),
}


def audit_finite_date(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', value):
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        return None


def source_audit_expected(model):
    """Counts from raw physical fixture rows and independently merged endpoints."""
    tables = model['tables']
    person_rows = tables['person']
    people = {p['person_id'] for p in person_rows if p['person_id'] is not None}
    intervals = defaultdict(list)
    raw_observations = tables['observation_period']
    for row in raw_observations:
        person = row['person_id']
        lo = audit_finite_date(row['observation_period_start_date'])
        hi = audit_finite_date(row['observation_period_end_date'])
        if person in people and lo is not None and hi is not None and lo <= hi:
            intervals[person].append((lo, hi))
    merged = {}
    for person, pairs in intervals.items():
        groups = []
        for lo, hi in sorted(pairs):
            # Difference rather than hi+one-day also handles9999-12-31 safely.
            if groups and (lo - groups[-1][1]).days <= 1:
                groups[-1][1] = max(groups[-1][1], hi)
            else:
                groups.append([lo, hi])
        merged[person] = groups
    population = dict(person_count=str(len(person_rows)),
                      nonnull=str(sum(p['person_id'] is not None for p in person_rows)),
                      distinct=str(len(people)), raw_observation_count=str(len(raw_observations)),
                      merged_interval_count=str(sum(len(groups) for groups in merged.values())))
    domains = {}
    for domain, (table, date_column) in AUDIT_DOMAINS.items():
        rows = tables[table]
        finite = [day for row in rows if (day := audit_finite_date(row[date_column])) is not None]
        observed = 0
        for row in rows:
            day = audit_finite_date(row[date_column])
            if day is not None and any(lo <= day <= hi for lo, hi in merged.get(row['person_id'], [])):
                observed += 1
        domains[domain] = dict(raw=str(len(rows)), linked=str(sum(row['person_id'] in people for row in rows)),
                               observed=str(observed), start=min(finite).isoformat() if finite else None,
                               end=max(finite).isoformat() if finite else None)
    return dict(population=population, domains=domains)


def verify_source_audits(snapshot, model):
    expected = source_audit_expected(model)
    audits = snapshot['source_audits']
    assert set(audits) == {'weighted', 'reference'}, 'Both exact operators must expose source audits'
    for strategy, actual in audits.items():
        assert actual == expected, ('physical source audit mismatch', snapshot['case'], snapshot['version'], strategy, actual, expected)
    # Required capture/observed states still follow the source independently of
    # optional field support; an unsupported unit/end/link report cannot erase it.
    for domain, totals in expected['domains'].items():
        core = snapshot['datasets']['core.' + domain + '.capture_count']
        observed = snapshot['datasets']['observed.' + domain + '.capture_count']
        assert core['state'] == ('computed' if totals['raw'] != '0' else 'empty_source')
        want_observed = ('empty_source' if totals['raw'] == '0' else
                         'empty_population' if totals['observed'] == '0' else 'computed')
        assert observed['state'] == want_observed
    conditional = {
        'core.device.unit_count': ('device_exposure', ['unit_concept_id', 'unit_source_value', 'unit_source_concept_id']),
        'core.procedure.end_precision_count': ('procedure_occurrence', ['procedure_end_date', 'procedure_end_datetime']),
        'core.specimen.visit_link_presence_count': ('specimen', ['visit_occurrence_id', 'visit_detail_id']),
    }
    for metric, (table, fields) in conditional.items():
        if any(field not in model['columns'][table] for field in fields):
            assert snapshot['datasets'][metric]['state'] == 'unsupported', metric
    return expected


def check_source_audit_oracle():
    """Literal adversarial counts guard independence before any native run."""
    model = dict(tables=dict(person=[dict(person_id='1'), dict(person_id='9007199254740993')],
                 observation_period=[]), columns={})
    def interval(person, lo, hi):
        return dict(person_id=person, observation_period_start_date=lo, observation_period_end_date=hi)
    model['tables']['observation_period'] = [
        interval('1', '2020-01-01', '2020-01-02'), interval('1', '2020-01-01', '2020-01-02'),
        interval('1', '2020-01-02', '2020-01-03'), interval('1', '2020-01-04', '2020-01-04'),
        interval('1', '2020-01-06', '2020-01-06'), interval('9007199254740993', '9999-12-31', '9999-12-31'),
        interval('99', '2020-01-01', '2020-01-31'), interval(None, '2020-01-01', '2020-01-31'),
        interval('1', None, '2020-01-03'), interval('1', '2020-02-02', '2020-02-01')]
    events = [('1', '2020-01-01'), ('1', '2020-01-05'), ('1', None), ('99', '0001-01-01'),
              (None, '2020-01-07'), ('9007199254740993', '9999-12-31'),
              ('9007199254740993', 'infinity'), ('1', '-infinity'), ('1', '2020-01-01')]
    for table, column in AUDIT_DOMAINS.values():
        model['tables'][table] = [dict(person_id=person, **{column: day}) for person, day in events]
    expected = dict(population=dict(person_count='2', nonnull='2', distinct='2',
                    raw_observation_count='10', merged_interval_count='3'),
                    domains={domain: dict(raw='9', linked='7', observed='3', start='0001-01-01', end='9999-12-31')
                             for domain in AUDIT_DOMAINS})
    assert source_audit_expected(model) == expected
    # A matching audit remains valid even when unrelated derived report totals
    # are nonsense; changing one source-audit count must fail independently.
    model['columns'] = {table: {} for table, _ in AUDIT_DOMAINS.values()}
    snapshot = dict(case='literal_physical', version='5.5',
                    source_audits={strategy: deepcopy(expected) for strategy in ['weighted', 'reference']},
                    rows={'unrelated_report': [{'record_count': '999999999999999999999'}]}, datasets={})
    for domain in AUDIT_DOMAINS:
        snapshot['datasets']['core.' + domain + '.capture_count'] = dict(state='computed')
        snapshot['datasets']['observed.' + domain + '.capture_count'] = dict(state='computed')
    for metric in ['core.device.unit_count', 'core.procedure.end_precision_count', 'core.specimen.visit_link_presence_count']:
        snapshot['datasets'][metric] = dict(state='unsupported')
    assert verify_source_audits(snapshot, model) == expected
    corrupted = deepcopy(snapshot)
    corrupted['source_audits']['weighted']['domains']['condition']['raw'] = '8'
    try:
        verify_source_audits(corrupted, model)
    except AssertionError:
        pass
    else:
        raise AssertionError('A corrupted audit count was accepted')
    unobserved = deepcopy(model); unobserved['tables']['observation_period'] = []
    want = deepcopy(expected); want['population'].update(raw_observation_count='0', merged_interval_count='0')
    for total in want['domains'].values():
        total['observed'] = '0'
    assert source_audit_expected(unobserved) == want
    empty = deepcopy(model)
    for table in empty['tables']:
        empty['tables'][table] = []
    want = dict(population={key: '0' for key in expected['population']},
                domains={domain: dict(raw='0', linked='0', observed='0', start=None, end=None) for domain in AUDIT_DOMAINS})
    assert source_audit_expected(empty) == want
    # Identity counts remain distinct concepts even though execution rejects a
    # source containing NULL/duplicate PERSON IDs before returning any receipt.
    invalid_identity = deepcopy(model)
    invalid_identity['tables']['person'] += [dict(person_id=None), dict(person_id='1')]
    assert source_audit_expected(invalid_identity)['population'] == dict(
        person_count='4', nonnull='3', distinct='2', raw_observation_count='10', merged_interval_count='3')
    return dict(status='passed', physical_domains=9, cases=['duplicates_overlap_adjacency_orphans_extreme_dates',
                'nonempty_unobserved', 'empty', 'separate_identity_counts'])


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


def observation_tail_fixture(case):
    """Observation extends beyond every recorded event, retaining zero calendar cells."""
    extended=deepcopy(case);extended['id']='observation_tail'
    for interval in extended['observation_period']:
        start=interval.get('observation_period_start_date');end=interval.get('observation_period_end_date')
        if start is not None and end is not None and start<=end:
            interval['observation_period_end_date']='2020-05-31'
    return extended


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
    audit_oracle = check_source_audit_oracle()
    case = measurement.fixture();empty = dict(case,id='empty_source',person=[],events=[],observation_period=[])
    extended=observation_tail_fixture(case)
    cases = {case['id']:case,empty['id']:empty,extended['id']:extended}
    matrix = [(case,v) for v in (['5.3','5.4','5.5'] if a.full_matrix else ['5.3'])]+[(empty,'5.5'),(extended,'5.5')]
    (out/'input.json').write_text(json.dumps([dict(case=c['id'],version=v,**physical(c,v)) for c,v in matrix]))
    subprocess.run(['Rscript','--vanilla','tests/tracer/characterization-render-offline.R',str(out/'input.json')],cwd=ROOT,check=True)
    subprocess.run(['Rscript','--vanilla','tests/tracer/characterization-execute-offline.R',str(out/'input.json')],cwd=ROOT,check=True)
    if a.with_publication:
        cmd=[sys.executable,'tools/test_result_serving.py','--test-script','core-characterization','--state',str(a.state.resolve()),
             '--config',str(a.config.resolve()),'--output-dir',str(out),'--admin-host',a.admin_host,'--port',str(a.port)]
        if a.admin_user:cmd.extend(['--admin-user',a.admin_user])
    else:cmd=['Rscript','--vanilla','tests/tracer/core-characterization.R',str(a.config.resolve()),str(out)]
    subprocess.run(cmd,cwd=ROOT,check=True)
    report = json.loads((out/'report.json').read_text())
    assert len(report['snapshots'])==len(matrix)
    for snap in report['snapshots']:
        verify(snap,cases[snap['case']])
        verify_source_audits(snap, physical(cases[snap['case']], snap['version']))
    summary = dict(status='passed',cases=len(matrix),metrics=142,numeric_parity='138 exact outputs',native_validation=True,
                   metadata='independent fixture expectations',source_denied=True,metadata_budget_rollback=True,
                   source_audits='independent physical tables, both exact operators',audit_oracle=audit_oracle)
    if a.with_publication:summary['publication']=verify_publication(out,report)
    (out/'oracle.json').write_text(json.dumps(summary,indent=2)+'\n');print(summary)


if __name__=='__main__':main()
