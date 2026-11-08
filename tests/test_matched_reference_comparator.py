"""Independent-comparator scope, precision and factual-normalization safeguards."""
import copy
import json
import tempfile
from unittest.mock import Mock,patch
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
_path=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    import matched_reference_sql as SQL
    import matched_reference_compare as COMPARE
    import test_matched_reference as CONTROLLER
    from synthetic_cdm import assets,plan
finally:
    sys.path[:]=_path


def cell(key,values,dimensions=None,kind='metadata'):
    return dict(row_key=key,dimensions=dimensions or {},row_kind=kind,state='computed',reason_code=None,values=values,denominator_refs=[])


def snapshot():
    # Small structural inputs for testing the comparison boundary, not a claim
    # of native-valid complete clinical results. Real native cases are opt-in.
    datasets={mid:dict(metric_id=mid,state='computed',rows='0',completeness=dict(scope_kind='standard_full',complete=True)) for mid in COMPARE.IDS}
    rows={mid:[] for mid in COMPARE.IDS}
    rows['core.source.passport']=[cell('passport',dict(generation=dict(started_at='2020-01-01T00:00:00Z',ended_at='2020-01-01T00:00:01Z'),coverage='full'))]
    rows['core.person.count']=[cell('count',dict(person_count='9007199254740993'),kind='counts')]
    rows['core.measurement.numeric_summary']=[cell('summary',dict(n='2',sum='9007199254740993.125',p50='0.000000000000000000125'),dict(unit_concept_tag=dict(kind='id',value='200')),kind='summary')]
    telemetry=dict(cpu_ms=None,peak_memory_bytes=None,source_rows=None,temp_bytes=None)
    rows[COMPARE.TIMING]=[cell('generation',dict(duration_ms='12',telemetry=telemetry,availability='measured',reason_code=None),dict(operation_id='core.numeric_generation',phase='generation'))]
    for phase in ['validation','projection','export','publication']:
        rows[COMPARE.TIMING].append(cell(phase,dict(duration_ms=None,telemetry=telemetry,availability='unavailable',reason_code='execution.not_started_at_metadata_capture'),dict(operation_id='core.'+phase,phase=phase)))
    for mid in datasets:datasets[mid]['rows']=str(len(rows[mid]))
    return dict(datasets=datasets,rows=rows)


class MatchedReferenceTest(unittest.TestCase):
    def test_all_versions_compile_complete_pinned_numerical_inventory(self):
        for version in ['5.3','5.4','5.5']:
            columns=assets(plan(version=version))[2]
            ref=SQL.Reference('cdm_synthetic_'+'a'*12,{t:{c['name']:c['type'] for c in cs} for t,cs in columns.items()})
            result=ref.manifest()
            self.assertEqual(set(result['queries']),COMPARE.IDS-set(SQL.METADATA))
            self.assertEqual(len(result['queries']),138)
            unsupported={mid for mid,spec in result['queries'].items() if spec['unsupported_reason']}
            self.assertEqual(len(unsupported),{'5.3':3,'5.4':1,'5.5':0}[version])
            self.assertEqual(result['profile_sha256'],json.loads((ROOT/'inst/contracts/v2/rows.json').read_bytes())['profile_sha256'])
            for spec in result['queries'].values():self.assertTrue(spec['sql'])

    def test_unknown_outputs_and_unsafe_source_identifiers_are_refused(self):
        for schema in ['public; DROP SCHEMA x','a"b','../source','x'*64]:
            with self.assertRaises(ValueError):SQL.Reference(schema,{})
        ref=SQL.Reference('synthetic',{})
        for mid in ['unknown','core.source.passport']:
            with self.assertRaises(ValueError):ref.compile(mid)

    def test_factual_timestamps_durations_and_topology_can_differ(self):
        a=snapshot();b=copy.deepcopy(a)
        b['rows']['core.source.passport'][0]['values']['generation']=dict(started_at='2021-01-01T00:00:00Z',ended_at='2021-01-01T00:00:01Z')
        timing=b['rows'][COMPARE.TIMING];timing[0]['values']['duration_ms']='1000'
        timing.append(cell('stage',copy.deepcopy(timing[0]['values']),dict(operation_id='stage.reference.numeric',phase='materialization')))
        b['datasets'][COMPARE.TIMING]['rows']=str(len(timing))
        self.assertEqual(COMPARE.compare_pair(a,b)['metric_count'],142)
        self.assertNotEqual(a,b) # The comparison does not modify its inputs.

    def test_precision_states_denominators_and_null_tags_are_not_normalized(self):
        for change in ['decimal','count','state','reason','denominator','tag','row_key','schema']:
            with self.subTest(change=change):
                a=snapshot();b=copy.deepcopy(a);r=b['rows']['core.measurement.numeric_summary'][0]
                if change=='decimal':r['values']['sum']='9007199254740992'
                if change=='count':b['rows']['core.person.count'][0]['values']['person_count']='9007199254740992'
                if change=='state':r['state']='empty_population'
                if change=='reason':r['reason_code']='summary.no_eligible'
                if change=='denominator':r['denominator_refs']=[dict(value='1',row_key='wrong')]
                if change=='tag':r['dimensions']['unit_concept_tag']=dict(kind='null')
                if change=='row_key':r['row_key']='changed'
                if change=='schema':b['datasets']['core.person.count']['definition_sha256']='changed'
                with self.assertRaises(ValueError):COMPARE.compare_pair(a,b)

    def test_profile_coverage_and_row_inventory_must_match(self):
        for change in ['metric','count','coverage','passport','duplicate']:
            with self.subTest(change=change):
                a=snapshot();b=copy.deepcopy(a)
                if change=='metric':del b['datasets']['core.person.count']
                if change=='count':b['datasets']['core.person.count']['rows']='0'
                if change=='coverage':b['datasets']['core.person.count']['completeness']['complete']=False
                if change=='passport':b['rows']['core.source.passport'][0]['values']['coverage']='reduced'
                if change=='duplicate':
                    b['rows']['core.person.count']*=2;b['datasets']['core.person.count']['rows']='2'
                with self.assertRaises(ValueError):COMPARE.compare_pair(a,b)

    def test_normalized_timing_still_rejects_fabrication_and_missing_phases(self):
        for change in ['cpu','duration','missing','duplicate','state','chronology']:
            with self.subTest(change=change):
                a=snapshot();b=copy.deepcopy(a);t=b['rows'][COMPARE.TIMING]
                if change=='cpu':t[0]['values']['telemetry']['cpu_ms']='0'
                if change=='duration':t[0]['values']['duration_ms']='1.2'
                if change=='missing':t.pop()
                if change=='duplicate':t.append(copy.deepcopy(t[0]));t[-1]['row_key']='new-key'
                if change=='state':t[0]['state']='suppressed'
                if change=='chronology':b['rows']['core.source.passport'][0]['values']['generation']['ended_at']='1900'
                b['datasets'][COMPARE.TIMING]['rows']=str(len(t))
                with self.assertRaises(ValueError):COMPARE.compare_pair(a,b)

    def test_equal_paths_still_require_independent_numerical_expectations(self):
        a=snapshot();expected=dict(kind='adversarial',rows={mid:[{k:r[k] for k in ['dimensions','values','state','reason_code']} for r in rows] for mid,rows in a['rows'].items() if mid not in SQL.METADATA})
        self.assertEqual(COMPARE.check_expectations(a,expected)['metrics'],138)
        b=copy.deepcopy(a);b['rows']['core.measurement.numeric_summary'][0]['values']['sum']='1'
        self.assertEqual(COMPARE.compare_pair(b,b)['metric_count'],142)
        with self.assertRaisesRegex(ValueError,'Independent adversarial'):COMPARE.check_expectations(b,expected)
        del expected['rows']['core.person.count']
        with self.assertRaisesRegex(ValueError,'Incomplete independent'):COMPARE.check_expectations(a,expected)

    def test_bundled_adversarial_expectations_cover_every_numerical_output(self):
        case=CONTROLLER.adversarial.measurement.fixture()
        for version in ['5.3','5.4','5.5']:
            expected=CONTROLLER.numerical_expectations(case,version)
            self.assertEqual(set(expected['rows']),COMPARE.IDS-set(SQL.METADATA))
            self.assertTrue(any(r['values'].get('sum') and len(r['values']['sum'])>18 for r in expected['rows']['core.measurement.numeric_summary']))

    def test_failed_worker_attempts_all_source_cleanup_and_never_writes_success(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);out=root/'out';pg=Mock();pg.rows.return_value=[dict(db='achilles_next_fixtures',usr='achilles_next_fixture_owner',marker=CONTROLLER.MARKER)]
            loaded=[]
            def load(*args):
                one=dict(schema='cdm_synthetic_'+str(len(loaded))*12,marker=CONTROLLER.MARKER+': preview:'+'a'*64,manifest_sha256='a'*64,version='5.5')
                loaded.append(one);return one
            argv=['test_matched_reference.py','--state',str(root),'--config',str(root/'config.R'),'--output-dir',str(out)]
            with patch.object(sys,'argv',argv),patch.object(CONTROLLER,'Postgres',return_value=pg),\
                 patch.object(CONTROLLER,'load_preview',side_effect=load),patch.object(CONTROLLER,'load_model',side_effect=load),\
                 patch.object(CONTROLLER.subprocess,'run',side_effect=RuntimeError('worker failed')),\
                 patch.object(CONTROLLER,'drop_preview',side_effect=[RuntimeError('cleanup denied'),None,None]) as cleanup:
                with self.assertRaisesRegex(RuntimeError,'cleanup failed'):CONTROLLER.main()
            self.assertEqual(len(loaded),3);self.assertEqual(cleanup.call_count,3)
            self.assertFalse((out/'oracle.json').exists())

    def test_capability_expectations_distinguish_absence_denial_and_empty(self):
        model=dict(columns=dict(cdm_source=dict(cdm_source_name='text'),measurement=dict(value_as_number='numeric'),person=dict(person_id='bigint')),tables=dict(cdm_source=[],measurement=[],person=[dict(person_id='1')]),denied_tables=[])
        empty=COMPARE.expected_capabilities(model)
        self.assertEqual(empty['measurement.value_as_number']['state'],'available_empty')
        self.assertEqual(empty['measurement.unit_concept_id']['state'],'absent')
        model['denied_tables']=['measurement'];denied=COMPARE.expected_capabilities(model)
        self.assertEqual(denied['measurement.value_as_number']['state'],'inaccessible')
        self.assertEqual(denied['measurement.value_as_number']['reason_code'],'capability.select_denied')
        self.assertEqual(denied['person.person_id']['state'],'available')


if __name__=='__main__':unittest.main()
