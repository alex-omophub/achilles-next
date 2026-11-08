"""Resource scope, missing-counter, budget and failure-retention regressions."""
import json
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

    def test_failed_owned_child_preserves_log_and_wait4_metrics(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);value=SAMPLE.observe([sys.executable,'-c','print("expected failure");raise SystemExit(7)'],root,interval=.1,wall_seconds=5)
            self.assertEqual(value['exit_code'],7);self.assertEqual(value['status'],'failed_or_stopped')
            self.assertEqual(value['worker_peak_rss_bytes']['state'],'available');self.assertFalse(value['qualifying'])
            self.assertIn('expected failure',(root/'worker.log').read_text());self.assertTrue((root/'process-telemetry.json').exists())

    def test_deadline_requests_cooperative_stop_even_with_clean_worker_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            code='import pathlib,time; p=pathlib.Path('+repr(str(root/'stop.json'))+');\nwhile not p.exists(): time.sleep(.01)\n'
            value=SAMPLE.observe([sys.executable,'-c',code],root,interval=.1,wall_seconds=1)
            self.assertEqual(value['exit_code'],0);self.assertNotEqual(value['status'],'completed');self.assertIsNotNone(value['stop_reason'])
            self.assertTrue((root/'stop.json').exists())

    def test_sampler_failure_reaps_its_child_before_propagating(self):
        with tempfile.TemporaryDirectory() as folder,patch.object(SAMPLE.shutil,'disk_usage',side_effect=OSError('probe failed')):
            root=Path(folder)
            with self.assertRaises(OSError):SAMPLE.observe([sys.executable,'-c','import time;time.sleep(10)'],root,interval=.1,wall_seconds=5)
            report=json.loads((root/'process-telemetry.json').read_text());self.assertIsNotNone(report['exit_code']);self.assertEqual(report['stop_reason'],'sampler_error')

    def test_phase_tree_rejects_double_counting_context_and_keeps_incomplete_trace(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'phases.jsonl';start=dict(event='begin',id=1,parent=None,phase='generation',elapsed_seconds=0)
            p.write_text(json.dumps(start)+'\n');self.assertFalse(REPORT.phases(p)['complete'])
            end=dict(event='end',id=1,parent=None,phase='generation',elapsed_seconds=2,wall_seconds=2,R_self_CPU_seconds=1,status='completed',before=None,after=None)
            p.write_text('\n'.join(map(json.dumps,[start,end,dict(event='summary',status='passed')]))+'\n')
            result=REPORT.phases(p);self.assertTrue(result['complete']);self.assertIn('never add',result['accounting'])
            end['parent']=2;p.write_text('\n'.join(map(json.dumps,[start,end]))+'\n')
            with self.assertRaises(ValueError):REPORT.phases(p)

    def test_output_scan_refuses_symlinks_and_does_not_overwrite_records(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder);(p/'link').symlink_to(ROOT/'README.md')
            with self.assertRaises(ValueError):SAMPLE.directory_bytes(p)
            (p/'link').unlink();(p/'worker.log').write_text('keep')
            with self.assertRaises(FileExistsError):SAMPLE.observe(['not-executed'],p)
            self.assertEqual((p/'worker.log').read_text(),'keep')


if __name__=='__main__':unittest.main()
