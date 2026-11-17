"""Resource scope, missing-counter, budget and failure-retention regressions."""
import contextlib
import errno
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
_saved=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools/benchmark'))
    import resource_telemetry as SAMPLE
    import telemetry_report as REPORT
finally:sys.path[:]=_saved


class ResourceTelemetryTest(unittest.TestCase):
    def test_limits_refuse_nonfinite_oversize_and_boolean_before_launch(self):
        for values in [(float('nan'),2,1,1,1),(.01,2,1,1,1),(.5,901,1,1,1),(.5,2,True,1,1)]:
            with self.subTest(values=values),self.assertRaises(ValueError):SAMPLE.limits(*values)

    def test_missing_cgroup_is_not_a_zero_peak(self):
        value=SAMPLE.cgroup_snapshot(None,1)
        self.assertEqual(value['state'],'unavailable');self.assertIsNone(value['value'])
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)
            for key,value in {'memory.current':'12','memory.peak':'34','cpu.stat':'usage_usec 7\nuser_usec 4\nsystem_usec 3','io.stat':'8:0 rbytes=100 wbytes=50','cgroup.procs':'123'}.items():(p/key).write_text(value)
            result=SAMPLE.cgroup_snapshot(p,123)
            self.assertTrue(result['value']['worker_member']);self.assertEqual(result['value']['memory_peak_bytes'],34)
            (p/'memory.peak').write_text('-1');self.assertEqual(SAMPLE.cgroup_snapshot(p,123)['state'],'unavailable')

    def test_counter_epochs_missing_fields_and_disabled_io_are_explicit(self):
        def m(values):return SAMPLE.metric(values,scope='shared counter')
        a=m(dict(stats_reset='epoch',count='9007199254740993',gone='5',track_io_timing='off',blk_read_time_ms='0'))
        b=m(dict(stats_reset='epoch',count='9007199254741000',track_io_timing='off',blk_read_time_ms='0'))
        d=REPORT.delta(a,b,'database')
        self.assertEqual(d['value']['count']['value'],'7');self.assertEqual(d['value']['gone']['reason'],'counter_missing')
        self.assertEqual(d['value']['blk_read_time_ms']['reason'],'track_io_timing_disabled')
        b['value']['stats_reset']='new';self.assertEqual(REPORT.delta(a,b,'database')['reason'],'counter_reset_or_unknown_epoch')
        self.assertEqual(REPORT.delta(SAMPLE.metric(reason='denied'),b,'database')['state'],'unavailable')

    def test_storage_shrink_is_not_a_counter_reset(self):
        self.assertEqual(REPORT.delta(SAMPLE.metric(dict(bytes='8')),SAMPLE.metric(dict(bytes='3')),'storage')['value']['bytes']['value'],'-5')
        self.assertEqual(REPORT.delta(SAMPLE.metric(dict(stats_reset='e',count='8')),SAMPLE.metric(dict(stats_reset='e',count='3')),'database')['state'],'unavailable')

    @unittest.skipUnless(hasattr(os,'wait4'),'Unix process telemetry')
    def test_failed_owned_child_preserves_log_and_wait4_metrics(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);value=SAMPLE.observe([sys.executable,'-c','print("expected failure");raise SystemExit(7)'],root,interval=.1,wall_seconds=5)
            self.assertEqual(value['exit_code'],7);self.assertEqual(value['status'],'failed_or_stopped')
            self.assertEqual(value['worker_peak_rss_bytes']['state'],'available');self.assertFalse(value['qualifying'])
            self.assertIn('expected failure',(root/'worker.log').read_text());self.assertTrue((root/'process-telemetry.json').exists())

    @unittest.skipUnless(hasattr(os,'wait4'),'Unix process telemetry')
    def test_deadline_requests_cooperative_stop_even_with_clean_worker_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            code='import pathlib,time; p=pathlib.Path('+repr(str(root/'stop.json'))+');\nwhile not p.exists(): time.sleep(.01)\n'
            value=SAMPLE.observe([sys.executable,'-c',code],root,interval=.1,wall_seconds=1)
            self.assertEqual(value['exit_code'],0);self.assertNotEqual(value['status'],'completed');self.assertIsNotNone(value['stop_reason'])
            self.assertTrue((root/'stop.json').exists())

    @unittest.skipUnless(hasattr(os,'wait4'),'Unix process telemetry')
    def test_sampler_failure_reaps_its_child_before_propagating(self):
        with tempfile.TemporaryDirectory() as folder,patch.object(SAMPLE.shutil,'disk_usage',side_effect=OSError('probe failed')):
            root=Path(folder)
            with self.assertRaises(OSError):SAMPLE.observe([sys.executable,'-c','import time;time.sleep(10)'],root,interval=.1,wall_seconds=5)
            report=json.loads((root/'process-telemetry.json').read_text());self.assertIsNotNone(report['exit_code']);self.assertEqual(report['stop_reason'],'sampler_error')

    def test_single_stat_observes_real_file_before_unlink_without_extra_probes(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'stable').write_bytes(b'a'*17);(root/'ephemeral').write_bytes(b'x'*3)
            actual_scandir=SAMPLE.os.scandir;probes=[]
            class Entry:
                def __init__(self,entry):self.entry=entry;self.path=entry.path
                def is_symlink(self):probes.append('is_symlink');return self.entry.is_symlink()
                def is_dir(self,**kwargs):probes.append('is_dir');return self.entry.is_dir(**kwargs)
                def is_file(self,**kwargs):
                    probes.append('is_file');value=self.entry.is_file(**kwargs)
                    if Path(self.path).name=='ephemeral':Path(self.path).unlink()
                    return value
                def stat(self,**kwargs):
                    probes.append(('stat',kwargs));value=self.entry.stat(**kwargs)
                    if Path(self.path).name=='ephemeral':Path(self.path).unlink()
                    return value
            @contextlib.contextmanager
            def moving(path):
                with actual_scandir(path) as entries:yield (Entry(e) for e in entries)
            with patch.object(SAMPLE.os,'scandir',moving):value=SAMPLE.directory_bytes(root)
            self.assertEqual(value,20);self.assertEqual((root/'stable').stat().st_size,17)
            self.assertFalse((root/'ephemeral').exists())
            self.assertEqual(probes,[('stat',{'follow_symlinks':False})]*2)

    def test_inventory_retries_fresh_walk_after_real_unlink_and_keeps_safe_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'stable').write_bytes(b'a'*17);(root/'ephemeral').write_bytes(b'x')
            actual_scandir=SAMPLE.os.scandir;lost=False;delays=[]
            class Entry:
                def __init__(self,entry):self.entry=entry;self.path=entry.path
                def stat(self,**kwargs):
                    nonlocal lost
                    if Path(self.path).name=='ephemeral' and not lost:
                        lost=True;Path(self.path).unlink()
                    return self.entry.stat(**kwargs)
            @contextlib.contextmanager
            def moving(path):
                with actual_scandir(path) as entries:yield (Entry(e) for e in entries)
            def backoff(seconds):
                delays.append(seconds);(root/'stable').write_bytes(b'a'*23);(root/'new').write_bytes(b'z'*7)
            with patch.object(SAMPLE.os,'scandir',moving),patch.object(SAMPLE.time,'sleep',backoff):
                value,details=SAMPLE.output_inventory(root)
            self.assertEqual(value['value'],30);self.assertEqual(value['state'],'available')
            self.assertEqual(details['attempts'],2);self.assertEqual(delays,[.01])
            self.assertEqual(details['first_failure'],dict(exception_class='FileNotFoundError',errno=errno.ENOENT))
            self.assertEqual(details['last_failure'],details['first_failure']);self.assertGreaterEqual(details['elapsed_seconds'],0)
            self.assertNotIn(str(root),json.dumps(details))

    def test_inventory_exhausts_three_actual_unlink_walks_without_inventing_zero(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'stable').write_bytes(b'a'*40)
            actual_scandir=SAMPLE.os.scandir;walks=0;delays=[]
            class Entry:
                def __init__(self,entry):self.entry=entry;self.path=entry.path
                def stat(self,**kwargs):
                    if Path(self.path).name=='ephemeral':Path(self.path).unlink()
                    return self.entry.stat(**kwargs)
            @contextlib.contextmanager
            def churning(path):
                nonlocal walks
                walks+=1;(root/'ephemeral').write_bytes(b'x')
                with actual_scandir(path) as entries:yield (Entry(e) for e in entries)
            with patch.object(SAMPLE.os,'scandir',churning),patch.object(SAMPLE.time,'sleep',delays.append):
                value,details=SAMPLE.output_inventory(root)
            self.assertEqual(value['reason'],'output_inventory_unavailable');self.assertIsNone(value['value'])
            self.assertEqual(walks,3);self.assertEqual(details['attempts'],3);self.assertEqual(delays,[.01,.02])
            self.assertEqual(details['last_failure']['errno'],errno.ENOENT)
            self.assertEqual(SAMPLE.directory_bytes(root),40)

    def test_inventory_retries_actual_directory_replaced_by_file(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);child=root/'child';child.mkdir();(child/'payload').write_bytes(b'x'*3)
            actual_scandir=SAMPLE.os.scandir;replaced=False;delays=[]
            class Entry:
                def __init__(self,entry):self.entry=entry;self.path=entry.path
                def stat(self,**kwargs):
                    nonlocal replaced
                    value=self.entry.stat(**kwargs)
                    if Path(self.path)==child and not replaced:
                        replaced=True;(child/'payload').unlink();child.rmdir();child.write_bytes(b'replaced')
                    return value
            @contextlib.contextmanager
            def moving(path):
                with actual_scandir(path) as entries:yield (Entry(e) for e in entries)
            def backoff(seconds):
                delays.append(seconds);child.unlink();child.mkdir();(child/'new').write_bytes(b'y'*11)
            with patch.object(SAMPLE.os,'scandir',moving),patch.object(SAMPLE.time,'sleep',backoff):
                value,details=SAMPLE.output_inventory(root)
            self.assertEqual(value['value'],11);self.assertEqual(details['attempts'],2)
            self.assertEqual(details['first_failure']['errno'],errno.ENOTDIR);self.assertEqual(delays,[.01])

    def test_inventory_hard_refusals_are_not_retried_or_leaked(self):
        for failure in [PermissionError(errno.EACCES,'SECRET_PATH_AND_MESSAGE'),ValueError('SECRET_PATH_AND_MESSAGE'),OSError(errno.EIO,'SECRET_PATH_AND_MESSAGE'),FileNotFoundError()]:
            with self.subTest(kind=type(failure).__name__),patch.object(SAMPLE,'directory_bytes',side_effect=failure) as walk,patch.object(SAMPLE.time,'sleep') as sleep:
                value,details=SAMPLE.output_inventory('unused')
                self.assertEqual(walk.call_count,1);sleep.assert_not_called();self.assertIsNone(value['value'])
                self.assertEqual(details['attempts'],1);self.assertNotIn('SECRET',json.dumps(details))
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            for i in range(3):(root/str(i)).write_bytes(b'x')
            with patch.object(SAMPLE,'MAX_OUTPUT_ENTRIES',2),patch.object(SAMPLE.time,'sleep') as sleep:
                value,details=SAMPLE.output_inventory(root)
                self.assertEqual(details['attempts'],1);self.assertIsNone(value['value']);sleep.assert_not_called()
            (root/'link').symlink_to(ROOT/'README.md')
            with patch.object(SAMPLE.time,'sleep') as sleep:
                value,details=SAMPLE.output_inventory(root)
                self.assertEqual(details['attempts'],1);self.assertIsNone(value['value']);sleep.assert_not_called()

    @unittest.skipUnless(hasattr(os,'wait4'),'Unix process telemetry')
    def test_unavailable_inventory_preserves_diagnostics_coverage_and_stop(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            code='import pathlib,time; p=pathlib.Path('+repr(str(root/'stop.json'))+');\nwhile not p.exists(): time.sleep(.01)\n'
            with patch.object(SAMPLE,'directory_bytes',side_effect=PermissionError(errno.EACCES,'SECRET_DIRECTORY')):
                value=SAMPLE.observe([sys.executable,'-c',code],root,interval=.1,wall_seconds=5)
            self.assertEqual(value['stop_reason'],'output_measurement_failed');self.assertEqual(value['exit_code'],0)
            self.assertIsNone(value['sampled_output_peak_bytes']);self.assertFalse(value['qualifying'])
            coverage=value['output_inventory_coverage'];self.assertEqual(coverage['successful_samples'],0)
            self.assertEqual(coverage['unavailable_samples'],value['samples']);self.assertGreater(value['samples'],0)
            failure=coverage['first_failure'];self.assertEqual(failure['attempts'],1)
            self.assertEqual(failure['exception_class'],'PermissionError');self.assertEqual(failure['errno'],errno.EACCES)
            self.assertEqual(coverage['last_failure']['exception_class'],failure['exception_class'])
            self.assertEqual(coverage['last_failure']['errno'],failure['errno'])
            self.assertGreaterEqual(failure['elapsed_seconds'],0)
            samples=[json.loads(line) for line in (root/'samples.jsonl').read_text().splitlines()]
            self.assertTrue(all(x['output_bytes']['value'] is None for x in samples))
            self.assertNotIn('SECRET',json.dumps(value));self.assertNotIn(str(root),json.dumps(value))

    @unittest.skipUnless(hasattr(os,'wait4'),'Unix process telemetry')
    def test_recovered_inventory_keeps_worker_running_and_counts_sample_coverage(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);walk=SAMPLE.directory_bytes;calls=0
            def transient(path):
                nonlocal calls
                calls+=1
                if calls==1:raise FileNotFoundError(errno.ENOENT,'SECRET_PATH_AND_MESSAGE')
                return walk(path)
            with patch.object(SAMPLE,'directory_bytes',transient):
                value=SAMPLE.observe([sys.executable,'-c','import time;time.sleep(.3)'],root,interval=.1,wall_seconds=5)
            self.assertEqual(value['status'],'completed');self.assertIsNone(value['stop_reason'])
            coverage=value['output_inventory_coverage'];self.assertGreater(value['samples'],0)
            self.assertEqual(coverage['successful_samples'],value['samples']);self.assertEqual(coverage['unavailable_samples'],0)
            self.assertEqual(coverage['retried_samples'],1);self.assertEqual(coverage['walk_attempts'],value['samples']+1)
            self.assertEqual(coverage['first_failure']['errno'],errno.ENOENT);self.assertEqual(coverage['first_failure']['attempts'],2)
            self.assertEqual(calls,coverage['walk_attempts']);self.assertNotIn('SECRET',json.dumps(value))
            samples=[json.loads(line) for line in (root/'samples.jsonl').read_text().splitlines()]
            self.assertEqual(samples[0]['output_inventory']['attempts'],2)
            self.assertTrue(all(x['output_bytes']['state']=='available' for x in samples))

    def test_phase_tree_rejects_double_counting_context_and_keeps_incomplete_trace(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'phases.jsonl';start=dict(event='begin',id=1,parent=None,phase='generation',elapsed_seconds=0)
            p.write_text(json.dumps(start)+'\n');self.assertFalse(REPORT.phases(p)['complete'])
            end=dict(event='end',id=1,parent=None,phase='generation',elapsed_seconds=2,wall_seconds=2,R_self_CPU_seconds=1,status='completed',before=None,after=None)
            p.write_text('\n'.join(map(json.dumps,[start,end,dict(event='summary',status='passed')]))+'\n')
            result=REPORT.phases(p);self.assertTrue(result['complete']);self.assertIn('never add',result['accounting'])
            end['parent']=2;p.write_text('\n'.join(map(json.dumps,[start,end]))+'\n')
            with self.assertRaises(ValueError):REPORT.phases(p)

    @unittest.skipUnless(hasattr(os,'wait4'),'Unix process telemetry')
    def test_output_scan_refuses_symlinks_and_does_not_overwrite_records(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder);(p/'link').symlink_to(ROOT/'README.md')
            with self.assertRaises(ValueError):SAMPLE.directory_bytes(p)
            (p/'link').unlink();(p/'worker.log').write_text('keep')
            with self.assertRaises(FileExistsError):SAMPLE.observe(['not-executed'],p)
            self.assertEqual((p/'worker.log').read_text(),'keep')


if __name__=='__main__':unittest.main()
