"""STOP trial contracts; reference capacities/identities are explicit stand-ins."""
from copy import deepcopy
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
saved=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    import resource_admission_trial as V
finally:sys.path[:]=saved
from test_source_execution_resources import reference_fixture


class TrialTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);self.root=Path(temporary.name)
        self.config,self.observed,self.worker=reference_fixture(self.root,'a'*64)
        self.resources=self.root/'resources';self.state=self.root/'state';self.state.mkdir();self.output=self.root/'work/trial'
        self.file=self.root/'allocation.json';self.file.write_bytes(V.S.BASE.canonical(self.config))
        with patch.object(V.Z,'host_observation',return_value=deepcopy(self.observed)):
            self.record=V.Z.register(self.file,self.resources)
        identity=patch.object(V.Z,'worker_identity',return_value=self.worker);identity.start();self.addCleanup(identity.stop)
        temporary=patch.object(V.Z.tempfile,'tempdir',self.config['storage']['temporary']['worker_path']);temporary.start();self.addCleanup(temporary.stop)
        self.probes=[];self.env={};self.answer=dict(database=self.config['database']['database'],owner=self.config['database']['owner'],
            postmaster_started_at=self.config['database']['postmaster_started_at'],read_only='on',ping=1)

    def client(self,*args):
        outer=self
        class Fake:
            env={'PGOPTIONS':'-c statement_timeout=30000'}
            def rows(self,sql):outer.probes.append(sql);return [deepcopy(outer.answer)]
        value=Fake();self.env=value.env;return value

    def run_trial(self,action=None,stop=None):
        def pause(_):
            if action:action()
        with patch.object(V.L,'Client',side_effect=self.client),patch.object(V.L,'check_target'),\
             patch.object(V.Z,'target_identity',return_value=deepcopy(self.config['database'])),patch.object(V.time,'sleep',side_effect=pause):
            return V.run(self.resources,self.state,self.output,seconds=2,stop=stop)

    def operator_stop(self):
        self.assertTrue((self.output/'ready.json').is_file())
        with V.M.open_file(self.resources/'STOP',True):pass

    def test_read_only_probe_then_real_operator_stop_passes_without_mutating_admission(self):
        before={n:(self.resources/n).read_bytes() for n in ('registration.json','lease.json')}
        result=self.run_trial(self.operator_stop)
        self.assertEqual(result['status'],'passed');self.assertEqual(result['samples'],1)
        self.assertEqual(self.probes,[V.PROBE]);self.assertIn('default_transaction_read_only=on',self.env['PGOPTIONS'])
        self.assertFalse(result['qualifying']);self.assertFalse(result['allocation_qualified']);self.assertFalse(result['source_scanned']);self.assertFalse(result['lease_renewed'])
        self.assertEqual(result['journal_bytes'],(self.output/'samples.jsonl').stat().st_size)
        self.assertEqual(result['journal_sha256'],V.S.BASE.sha((self.output/'samples.jsonl').read_bytes()))
        self.assertEqual(before,{n:(self.resources/n).read_bytes() for n in before})
        self.assertTrue((self.resources/'STOP').exists());self.assertFalse(Path(self.config['job_dir']).exists())
        receipt=V.M.read_json(self.output/'trial.json');self.assertEqual(receipt['result_sha256'],V.Z.digest(result))

    def test_admission_revocation_after_probe_passes(self):
        result=self.run_trial(lambda:V.M.atomic_json(self.resources,'revoked.json',dict(registration_sha256=self.record['registration_sha256'],status='revoked',qualifying=False)))
        self.assertEqual(result['status'],'passed');self.assertEqual(result['stop_reason'],'resource_admission_revoked')

    def test_unapproved_registration_refuses_before_connection_or_output(self):
        config=V.Z.template(self.root/'work/job','a'*64,'S1');self.file.write_bytes(V.S.BASE.canonical(config));resources=self.root/'blocked'
        with patch.object(V.Z,'host_observation',return_value=deepcopy(self.observed)):V.Z.register(self.file,resources)
        with patch.object(V.L,'Client',side_effect=AssertionError('no connection')):
            with self.assertRaisesRegex(ValueError,'registered resource admission'):V.run(resources,self.state,self.output)
        self.assertFalse(self.output.exists())

    def test_expired_lease_or_wrong_worker_refuses_before_connection(self):
        with patch.object(V.Z,'now',return_value=V.Z.now()+20),patch.object(V.L,'Client',side_effect=AssertionError('no connection')):
            with self.assertRaisesRegex(V.M.Stopped,'lease_unavailable_or_expired'):V.run(self.resources,self.state,self.output)
        self.worker['boot_id']='different'
        with patch.object(V.L,'Client',side_effect=AssertionError('no connection')):
            with self.assertRaisesRegex(ValueError,'outside registered runner'):V.run(self.resources,self.state,self.output)
        self.assertFalse(self.output.exists())

    def test_preexisting_or_dangling_stop_is_not_a_successful_trial(self):
        control=self.resources/'STOP'
        for alias in (False,True):
            if alias:control.symlink_to(self.root/'missing')
            else:control.touch()
            try:
                with patch.object(V.L,'Client',side_effect=AssertionError('no connection')):
                    with self.assertRaises((V.M.Stopped,ValueError)):V.run(self.resources,self.state,self.output)
            finally:control.unlink()
        self.assertFalse(self.output.exists())

    def test_output_cannot_overlap_job_state_resources_or_projection(self):
        paths=[Path(self.config['job_dir'])/'trial',self.resources/'trial',self.state/'trial',Path(self.config['projection']['evidence_file'])]
        for out in paths:
            with self.subTest(path=out),patch.object(V.L,'Client',side_effect=AssertionError('no connection')):
                with self.assertRaises((ValueError,FileExistsError)):V.run(self.resources,self.state,out)
        with patch.object(V.L,'Client',side_effect=AssertionError('no connection')):
            with self.assertRaisesRegex(ValueError,'separate'):V.run(self.resources,self.root/'work',self.output)

    def test_existing_or_symlink_output_is_preserved(self):
        self.output.mkdir();(self.output/'sentinel').write_text('keep')
        with self.assertRaises(FileExistsError):V.run(self.resources,self.state,self.output)
        alias=self.root/'work/alias';alias.symlink_to(self.output,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'Symlink'):V.run(self.resources,self.state,alias)
        self.assertEqual((self.output/'sentinel').read_text(),'keep')

    def test_wrong_database_identity_refuses_before_output(self):
        changed=dict(self.config['database'],database_oid=999)
        with patch.object(V.L,'Client',side_effect=self.client),patch.object(V.L,'check_target'),patch.object(V.Z,'target_identity',return_value=changed):
            with self.assertRaisesRegex(ValueError,'database identity/settings differ'):V.run(self.resources,self.state,self.output)
        self.assertFalse(self.output.exists())

    def test_wrong_probe_records_failure_and_no_ready_marker(self):
        self.answer['read_only']='off';result=self.run_trial()
        self.assertEqual(result['status'],'failed');self.assertIn('metadata probe differs',result['error'])
        self.assertFalse((self.output/'ready.json').exists());self.assertEqual(result['samples'],0)

    def test_external_callback_cannot_fabricate_operator_stop(self):
        result=self.run_trial(stop=lambda:'resource_operator_stop_file' if (self.output/'ready.json').exists() else None)
        self.assertEqual(result['status'],'failed');self.assertFalse((self.resources/'STOP').exists())

    def test_dangling_stop_after_read_retains_failure_evidence(self):
        result=self.run_trial(lambda:(self.resources/'STOP').symlink_to(self.root/'missing'))
        self.assertEqual(result['status'],'failed');self.assertEqual(result['samples'],1)
        self.assertIn('Unexpected file type',result['error']);self.assertIsNone(result['stop_reason'])

    def test_lease_loss_after_read_fails_and_retains_evidence(self):
        clock=V.time.monotonic;offset=[0.]
        def expire():
            V.M.atomic_json(self.resources,'lease.json',{});offset[0]+=.6
        with patch.object(V.time,'monotonic',side_effect=lambda:clock()+offset[0]):result=self.run_trial(expire)
        self.assertEqual(result['status'],'failed');self.assertEqual(result['samples'],1)
        self.assertIn('lease_unavailable_or_expired',result['error'])

    def test_deadline_without_operator_stop_is_failure(self):
        clock=V.time.monotonic;offset=[0.]
        with patch.object(V.time,'monotonic',side_effect=lambda:clock()+offset[0]):
            result=self.run_trial(lambda:offset.__setitem__(0,3.))
        self.assertEqual(result['status'],'failed');self.assertEqual(result['samples'],1)
        self.assertEqual(result['stop_reason'],'inventory_deadline');self.assertFalse((self.resources/'STOP').exists())

    def test_bounded_journal_or_counter_budget_fails_without_operator_stop(self):
        for constant,limit in [('MAX_JOURNAL',1),('MAX_SAMPLES',0)]:
            self.output=self.root/('work/'+constant)
            with patch.object(V,constant,limit):result=self.run_trial()
            self.assertEqual(result['status'],'failed');self.assertIn('journal budget exceeded',result['error'])
            self.assertEqual(result['journal_bytes'],0)

    def test_changed_trial_code_cannot_attest_success(self):
        code=V.pins()
        with patch.object(V,'pins',side_effect=[code,dict(code,trial='0'*64)]):result=self.run_trial(self.operator_stop)
        self.assertEqual(result['status'],'failed');self.assertIn('pins differ',result['error'])

    def test_hard_duration_bounds_refuse_before_input_access(self):
        for seconds in (0,31,True,1.5,float('nan')):
            with self.subTest(seconds=seconds),self.assertRaisesRegex(ValueError,'1..30 integer seconds'):
                V.run(self.root/'absent',self.state,self.output,seconds=seconds)


@unittest.skipUnless(os.environ.get('ACHILLES_NEXT_TEST_STATE'),'Set ACHILLES_NEXT_TEST_STATE for marked PostgreSQL integration')
class NativeTrialTests(unittest.TestCase):
    def test_real_read_only_probe_and_stop_with_simulated_resource_envelope(self):
        with tempfile.TemporaryDirectory(prefix='achillesnext-resource-trial-') as directory:
            root=Path(directory);state=Path(os.environ['ACHILLES_NEXT_TEST_STATE']);pg=V.L.Client(state,V.L.Guard([root]),'achillesnext-trial-test')
            V.L.check_target(pg);target=V.Z.target_identity(pg)
            config,observed,worker=reference_fixture(root,'a'*64,target=target);file=root/'allocation.json';file.write_bytes(V.S.BASE.canonical(config));resources=root/'resources';output=root/'work/trial'
            with patch.object(V.Z,'host_observation',return_value=observed):V.Z.register(file,resources)
            def stop_when_ready():
                if (output/'ready.json').exists() and not (resources/'STOP').exists():
                    with V.M.open_file(resources/'STOP',True):pass
            with patch.object(V.Z,'worker_identity',return_value=worker),patch.object(V.Z.tempfile,'tempdir',config['storage']['temporary']['worker_path']):
                result=V.run(resources,state,output,seconds=10,stop=stop_when_ready)
            self.assertEqual(result['status'],'passed');self.assertEqual(result['samples'],1)
            self.assertFalse(result['qualifying']);self.assertFalse(result['source_scanned'])
            row=V.Z.json.loads((output/'samples.jsonl').read_text());self.assertEqual(row['probe']['read_only'],'on')
            self.assertFalse(Path(config['job_dir']).exists());self.assertTrue((resources/'STOP').exists())
            evidence=os.environ.get('ACHILLES_NEXT_TRIAL_EVIDENCE')
            if evidence:
                import shutil
                target=V.S.outside(Path(evidence)).resolve();target.mkdir(mode=0o700)
                for name in ('request.json','ready.json','samples.jsonl','trial.json'):
                    V.M.regular(output/name,V.MAX_JOURNAL);shutil.copy2(output/name,target/name)
                V.M.atomic_json(target,'scope.json',dict(simulated_resource_envelope=True,actual_read_only_PostgreSQL_probe=True,
                    actual_reference_allocation=False,qualifying=False),exclusive=True)


if __name__=='__main__':unittest.main()
