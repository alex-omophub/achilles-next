"""Verify resource attribution fails closed on namespace, identity and scope drift."""
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('docker_resource_audit', ROOT/'tools/docker/resource_audit.py')
AUDIT = importlib.util.module_from_spec(spec); spec.loader.exec_module(AUDIT)


class DockerResourceAuditTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.root, self.proc = self.home/'cgroup', self.home/'proc'
        self.parent = '/achillesnext-validation-test'
        self.containers = dict(runner=dict(id='a'*64, pid=101), postgres=dict(id='b'*64, pid=202))
        self.paths = {role: self.parent+'/'+data['id'] for role, data in self.containers.items()}
        self.make_group(self.parent, '')
        for role, data in self.containers.items():
            self.make_group(self.paths[role], str(data['pid']))
            self.process(data['pid'], self.paths[role])
        # Children intentionally have different counters from the parent, so
        # selecting either container as the source cannot pass attribution tests.
        for role, peak, cache, written in [('runner', 250, 80, 10), ('postgres', 350, 120, 20)]:
            directory = self.root/self.paths[role].lstrip('/')
            (directory/'memory.current').write_text('200\n')
            (directory/'memory.peak').write_text(str(peak)+'\n')
            (directory/'memory.stat').write_text('anon 100\nfile '+str(cache)+'\n')
            (directory/'cpu.stat').write_text('usage_usec '+str(written*2)+'\n')
            (directory/'io.stat').write_text('8:0 rbytes=4 wbytes='+str(written)+'\n')
        self.make_group('/observer', str(os.getpid()))
        (self.proc/'self').mkdir(parents=True)
        (self.proc/'self/cgroup').write_text('0::/observer\n')
        (self.proc/'self/ns').mkdir()
        (self.proc/'self/ns/pid').symlink_to('pid:[1000]')
        self.clock = 0

    def make_group(self, group, pids):
        directory = self.root/group.lstrip('/'); directory.mkdir(parents=True)
        files = dict(zip(AUDIT.COUNTERS, ['500\n', '900\n', '1048576\n', 'anon 100\nfile 400\n',
            'oom 0\noom_kill 0\n', '0\n', '0\n', 'usage_usec 100\n', '100000 100000\n',
            '8:0 rbytes=40 wbytes=60 rios=1 wios=1\n', '2\n', '128\n']))
        files['cgroup.procs'] = pids+'\n'
        for name, value in files.items(): (directory/name).write_text(value)

    def process(self, pid, group, start=123, namespace=None):
        directory = self.proc/str(pid); directory.mkdir(parents=True, exist_ok=True)
        (directory/'cgroup').write_text('0::'+group+'\n')
        (directory/'stat').write_text(str(pid)+' (name with ) spaces) S '+'0 '*18+str(start)+' 0\n')
        if namespace is None:
            namespace = 1001 if group.startswith(self.paths['runner']) else 1002
        (directory/'ns').mkdir(exist_ok=True)
        link = directory/'ns/pid'; link.unlink(missing_ok=True)
        link.symlink_to('pid:['+str(namespace)+']')

    def audit(self):
        return AUDIT.Audit(self.root, self.proc, self.parent, self.containers)

    def tick(self, amount):
        self.clock += amount

    def capture(self, **kwargs):
        with patch.object(AUDIT.time, 'monotonic', side_effect=lambda:self.clock), patch.object(AUDIT.time, 'sleep', side_effect=self.tick):
            return AUDIT.capture(self.root, self.proc, self.parent, self.containers, self.home/'out', seconds=1, **kwargs)

    def test_parent_peak_includes_cache_and_is_not_sum_of_children(self):
        result = self.capture()
        self.assertEqual(result['status'], 'observed')
        self.assertEqual(result['memory_lifetime_peak_bytes'], 900)
        self.assertNotEqual(result['memory_lifetime_peak_bytes'], 250+350)
        self.assertEqual(result['cpu_interval_usec'], 0)
        self.assertFalse(result['qualifying']); self.assertFalse(result['allocation_verified'])
        samples = [json.loads(line) for line in (self.home/'out/samples.jsonl').read_text().splitlines()]
        self.assertEqual(samples[0]['metrics']['memory_current_bytes'], 500)
        self.assertEqual(samples[0]['metrics']['cpu']['usage_usec'], 100)
        self.assertEqual(samples[0]['metrics']['memory']['file'], 400)
        self.assertEqual(samples[0]['metrics']['io']['8:0']['wbytes'], 60)
        self.assertEqual(samples[0]['membership']['processes'], dict(runner=1, postgres=1))

    def test_nested_workers_are_counted_without_host_process_scan(self):
        self.make_group(self.paths['postgres']+'/workers', '203\n204')
        for pid in [203, 204]: self.process(pid, self.paths['postgres']+'/workers')
        self.assertEqual(self.audit().sample()['membership']['processes']['postgres'], 3)

    def test_outside_process_and_observer_do_not_enter_parent_totals(self):
        self.make_group('/unrelated', '303')
        self.assertEqual(self.audit().sample()['membership']['processes'], dict(runner=1, postgres=1))

    def test_unrelated_child_and_parent_process_are_refused(self):
        audit = self.audit(); self.make_group(self.parent+'/foreign', '')
        with self.assertRaisesRegex(ValueError, 'Unrelated'): audit.sample()
        (self.root/self.parent.lstrip('/')/'cgroup.procs').write_text('303\n')
        with self.assertRaisesRegex(ValueError, 'Unattributed'): audit.sample()

    def test_pid_reuse_move_and_exit_are_refused(self):
        audit = self.audit()
        for group, start in [(self.paths['runner'], 999), ('/elsewhere', 123)]:
            self.process(101, group, start)
            with self.assertRaisesRegex(ValueError, 'identity'): audit.sample()
        (self.proc/'101/stat').unlink()
        with self.assertRaises(OSError): audit.sample()

    def test_observer_inclusion_and_namespace_mismatch_are_refused(self):
        (self.proc/'self/cgroup').write_text('0::'+self.paths['runner']+'\n')
        with self.assertRaisesRegex(ValueError, 'outside'): self.audit()
        (self.proc/'self/cgroup').write_text('0::/observer\n')
        (self.root/'observer/cgroup.procs').write_text('999\n')
        with self.assertRaisesRegex(ValueError, 'namespace'): self.audit()

    def test_wrong_container_id_and_parent_are_refused(self):
        self.containers['runner']['id'] = 'c'*64
        with self.assertRaisesRegex(ValueError, 'direct child'): self.audit()
        for parent in ['/', '/system.slice', '/achillesnext-validation-test/../other', '//achillesnext-validation-test']:
            with self.subTest(parent=parent), self.assertRaises(ValueError):
                AUDIT.Audit(self.root, self.proc, parent, self.containers)

    def test_both_roles_referencing_same_valid_container_are_refused(self):
        self.containers['postgres'] = dict(self.containers['runner'])
        with self.assertRaisesRegex(ValueError, 'distinct containers'): self.audit()

    def test_foreign_pid_namespace_in_recognized_cgroup_is_refused(self):
        audit = self.audit()
        self.process(303, self.paths['runner'], namespace=9999)
        (self.root/self.paths['runner'].lstrip('/')/'cgroup.procs').write_text('101\n303\n')
        result = self.capture()
        self.assertEqual(result['status'], 'failed'); self.assertIn('Unrelated PID namespace', result['error'])
        with self.assertRaisesRegex(ValueError, 'Unrelated PID namespace'): audit.sample()

    def test_missing_namespace_permission_fails_instead_of_accepting_membership(self):
        with patch.object(AUDIT.os, 'readlink', side_effect=PermissionError('namespace denied')):
            result = self.capture()
        self.assertEqual(result['status'], 'failed'); self.assertIn('namespace denied', result['error'])

    def test_invalid_or_shared_pid_namespaces_are_refused(self):
        for namespace in [1000, 1001]:
            self.process(202, self.paths['postgres'], namespace=namespace)
            with self.subTest(namespace=namespace), self.assertRaisesRegex(ValueError, 'separate PID namespaces'): self.audit()
        with patch.object(AUDIT.os, 'readlink', return_value=''):
            with self.assertRaisesRegex(ValueError, 'namespace identifier unavailable'): self.audit()

    def test_exited_worker_is_not_counted_and_process_move_is_refused(self):
        audit = self.audit(); directory = self.root/self.paths['runner'].lstrip('/')
        (directory/'cgroup.procs').write_text('101\n303\n')
        self.assertEqual(audit.sample()['membership']['processes']['runner'], 1)
        self.process(303, '/other', namespace=1001)
        with self.assertRaisesRegex(ValueError, 'process cgroup changed'): audit.sample()

    def test_symlink_and_replaced_cgroup_fail(self):
        audit = self.audit(); group = self.root/self.paths['runner'].lstrip('/')
        original = self.home/'original'; group.rename(original); group.symlink_to(original, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Symlink'): audit.sample()
        group.unlink(); self.make_group(self.paths['runner'], '101')
        with self.assertRaisesRegex(ValueError, 'identity'): audit.sample()

    def test_missing_counter_retained_as_unavailable_with_failed_receipt(self):
        (self.root/self.parent.lstrip('/')/'memory.peak').unlink()
        result = self.capture()
        self.assertEqual(result['status'], 'failed'); self.assertNotIn('memory_lifetime_peak_bytes', result)
        sample = json.loads((self.home/'out/samples.jsonl').read_text())
        self.assertIsNone(sample['raw']['memory.peak']); self.assertIn('memory.peak', sample['unavailable'])
        self.assertEqual(json.loads((self.home/'out/audit.json').read_text()), result)

    def test_unbounded_limits_remain_explicit_without_allocation_claim(self):
        directory = self.root/self.parent.lstrip('/')
        (directory/'memory.max').write_text('max\n'); (directory/'cpu.max').write_text('max 100000\n')
        sample = self.audit().sample()
        self.assertIsNone(sample['metrics']['controls']['memory_bytes'])
        self.assertIsNone(sample['metrics']['controls']['cpu_quota_usec'])

    def test_malformed_and_oversize_files_fail_instead_of_zero(self):
        directory = self.root/self.parent.lstrip('/')
        for name, value in [('memory.peak', '-1'), ('cpu.stat', 'usage_usec 1\nusage_usec 2\n'),
                            ('io.stat', 'bad rbytes=1\n'), ('cpu.max', '1 0\n'), ('memory.stat', 'x'*65537)]:
            with self.subTest(name=name):
                target = directory/name; before = target.read_text(); target.write_text(value)
                with self.assertRaises(ValueError): self.audit().sample()
                target.write_text(before)

    def test_inventory_count_bounds_and_absent_init_pid(self):
        audit = self.audit(); path = self.root/self.paths['runner'].lstrip('/')/'cgroup.procs'
        path.write_text('303\n')
        with self.assertRaisesRegex(ValueError, 'init PID absent'): audit.sample()
        path.write_text('1\n'*1025)
        with self.assertRaisesRegex(ValueError, 'budget'): audit.sample()
        path.write_text('101\n')
        with patch.object(AUDIT, 'MAX_GROUPS', 2), self.assertRaisesRegex(ValueError, 'budget'): audit.sample()

    def test_cumulative_reset_fails_and_preserves_prior_samples(self):
        original = AUDIT.Audit.sample
        def decreasing(audit):
            result = original(audit)
            result['metrics']['cpu']['usage_usec'] = 100 if self.clock == 0 else 1
            return result
        with patch.object(AUDIT.Audit, 'sample', decreasing): result = self.capture()
        self.assertEqual(result['status'], 'failed'); self.assertIn('regressed', result['error'])
        self.assertEqual(result['samples'], 2)

    def test_exclusive_output_and_duration_bounds(self):
        for args in [dict(seconds=float('nan')), dict(seconds=61), dict(interval=.1)]:
            values = dict(seconds=1, interval=.5, **{})
            values.update(args)
            with self.subTest(args=args), self.assertRaises(ValueError):
                AUDIT.capture(self.root, self.proc, self.parent, self.containers, self.home/'out', **values)
        self.capture()
        with self.assertRaises(FileExistsError): self.capture()

    def test_journal_limit_and_interruption_keep_failed_record(self):
        with patch.object(AUDIT, 'MAX_JOURNAL', 1): result = self.capture()
        self.assertEqual(result['status'], 'failed'); self.assertIn('journal', result['error'])
        (self.home/'out').rename(self.home/'saved')
        with patch.object(AUDIT.Audit, 'sample', side_effect=KeyboardInterrupt): result = self.capture()
        self.assertEqual(result['status'], 'failed'); self.assertFalse(result['qualifying'])

    def test_source_drift_is_refused_before_observation(self):
        with patch.object(AUDIT, 'SOURCE_SHA256', '0'*64): result = self.capture()
        self.assertEqual(result['status'], 'failed'); self.assertIn('source changed', result['error'])
        self.assertEqual(result['samples'], 0)

    def test_membership_change_during_counter_read_is_refused(self):
        audit = self.audit(); original = AUDIT.read
        def move(path):
            value = original(path)
            if path.name == 'memory.current': self.process(101, '/other')
            return value
        with patch.object(AUDIT, 'read', side_effect=move), self.assertRaisesRegex(ValueError, 'identity'): audit.sample()

    def test_cpu_delta_uses_only_observed_interval(self):
        original = AUDIT.Audit.sample
        def increasing(audit):
            result = original(audit)
            result['metrics']['cpu']['usage_usec'] = 10000+int(self.clock*100)
            return result
        with patch.object(AUDIT.Audit, 'sample', increasing): result = self.capture()
        self.assertEqual(result['cpu_interval_usec'], 100)
        self.assertEqual(result['status'], 'observed')

    def test_cli_nonfinite_and_out_of_range_times_are_usage_errors(self):
        base = ['resource_audit.py', '--parent', self.parent, '--runner', 'a'*64+':101',
                '--postgres', 'b'*64+':202', '--output', str(self.home/'out')]
        for option, value in [(name, value) for name in ['seconds', 'interval'] for value in ['nan', 'inf', '-inf']]+[('seconds', '61'), ('interval', '.1')]:
            with self.subTest(option=option, value=value), patch.object(AUDIT.sys, 'argv', base+['--'+option+'='+value]), patch.object(AUDIT.sys, 'platform', 'linux'), patch.object(AUDIT, 'capture') as capture, patch('sys.stderr', new_callable=io.StringIO) as errors:
                with self.assertRaises(SystemExit) as raised: AUDIT.main()
                self.assertEqual(raised.exception.code, 2)
                self.assertIn('error:', errors.getvalue()); self.assertNotIn('Traceback', errors.getvalue())
                capture.assert_not_called(); self.assertFalse((self.home/'out').exists())


if __name__ == '__main__': unittest.main()
