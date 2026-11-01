"""The fixture oracle must reject state mistakes even with unchanged values."""
import copy
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import test_domain_baseline as domain


def snapshot(case,version):
    expected=domain.oracle(case,version);rows={};inventory={}
    for mid,values in expected.items():
        state,reason=domain.dataset_state(mid,case,version)
        rows[mid]=[dict(dimensions=json.loads(dims),**domain.cell(value,state,reason)) for dims,value in values.items()]
        inventory[mid]=dict(state=state,reason_code=reason,rows=str(len(values)))
    population,states=domain.population_expected(case,expected)
    rows.update(population)
    for mid,values in population.items():inventory[mid]=dict(state=states[mid][0],reason_code=states[mid][1],rows=str(len(values)))
    return dict(case=case['id'],version=version,rows=rows,context=dict(inventory=inventory))


class OracleRegressions(unittest.TestCase):
    def test_cell_state_and_reason_not_just_values(self):
        case=domain.make_fixture();snap=snapshot(case,'5.5');domain.verify_snapshot(snap,case)
        for key,value in [('state','empty_source'),('reason_code','fixture.wrong_reason')]:
            bad=copy.deepcopy(snap)
            row=next(r for r in bad['rows']['core.condition.capture_count'] if r['values']==dict(record_count='0',person_count='0'))
            row[key]=value
            with self.assertRaises(AssertionError):domain.verify_snapshot(bad,case)
        bad=copy.deepcopy(snap)
        row=next(r for r in bad['rows']['core.drug.quantity_summary'] if r['values'].get('n')=='0')
        row['reason_code']='fixture.wrong_empty_reason'
        with self.assertRaises(AssertionError):domain.verify_snapshot(bad,case)

    def test_empty_frequency_is_not_all_person_histogram(self):
        case=dict(id='empty',person=domain.make_fixture()['person'],events=[],observation_period=[])
        snap=snapshot(case,'5.5');domain.verify_snapshot(snap,case)
        for metric in ['core.condition.frequency_histogram','core.condition.distinct_concepts_histogram']:
            bad=copy.deepcopy(snap);bad['context']['inventory'][metric]['state']='computed' if metric.endswith('.frequency_histogram') else 'empty_source'
            with self.assertRaises(AssertionError):domain.verify_snapshot(bad,case)

    def test_unavailable_cell_reason_and_null_payload(self):
        case=domain.make_fixture();expected=domain.oracle(case,'5.5')['core.visit.care_setting_count'];rows={}
        for dims,value in expected.items():
            d=json.loads(dims);place=d['setting_kind']=='place_of_service'
            if place:d['setting_concept_tag']={'kind':'schema_absent'}
            rows[domain.canon(d)]=dict(dimensions=d,**domain.cell(None if place else value,'unavailable' if place else 'computed','capability.care_site_denied' if place else None))
        rows=list(rows.values());domain.verify_care(case,rows,'capability.care_site_denied')
        for key,value in [('reason_code','capability.wrong'),('state','unsupported'),('values',dict(record_count='0',person_count='0'))]:
            bad=copy.deepcopy(rows);next(r for r in bad if r['state']=='unavailable')[key]=value
            with self.assertRaises(AssertionError):domain.verify_care(case,bad,'capability.care_site_denied')

    def test_compact_calendar_retains_all_nonperiod_reports(self):
        wide=domain.make_fixture();compact=domain.make_fixture(compact_calendar=True)
        for version in ['5.3','5.4','5.5']:
            a=domain.oracle(wide,version);b=domain.oracle(compact,version)
            self.assertEqual(set(a),set(b));self.assertLess(sum(map(len,b.values())),sum(map(len,a.values())))
            for mid in a:
                if not mid.endswith('.capture_count'):self.assertEqual(a[mid],b[mid],mid)
                else:
                    for dims,value in a[mid].items():
                        if json.loads(dims)['period_kind'] in ['full_scope','undated']:self.assertEqual(value,b[mid][dims],mid)

    def test_evidence_path_guard(self):
        with tempfile.TemporaryDirectory() as folder:
            parent=Path(folder);checkout=parent/'checkout';checkout.mkdir();existing=parent/'existing';existing.mkdir()
            sentinel=existing/'input.json';sentinel.write_text('keep this evidence')
            for path in [existing,sentinel,checkout/'new-evidence']:
                with self.assertRaises(ValueError):domain.create_evidence_dir(path,checkout)
            self.assertFalse((checkout/'new-evidence').exists());self.assertEqual(sentinel.read_text(),'keep this evidence')
            link=parent/'link';link.symlink_to(existing,target_is_directory=True)
            with self.assertRaises(ValueError):domain.create_evidence_dir(link,checkout)
            dangling=parent/'dangling';dangling.symlink_to(parent/'missing')
            with self.assertRaises(ValueError):domain.create_evidence_dir(dangling,checkout)
            allowed=domain.create_evidence_dir(parent/'new',checkout)
            self.assertEqual(stat.S_IMODE(allowed.stat().st_mode),0o700)
            cli=subprocess.run([sys.executable,str(ROOT/'tools/test_domain_baseline.py'),'--config',str(parent/'absent.R'),'--output-dir',str(existing)],capture_output=True,text=True)
            self.assertEqual(cli.returncode,2);self.assertIn('new evidence directory outside',cli.stderr)
            self.assertEqual(sentinel.read_text(),'keep this evidence')


if __name__=='__main__':unittest.main()
