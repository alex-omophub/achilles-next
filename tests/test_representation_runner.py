"""Failure evidence and source-pin regressions for the local benchmark runner."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools/benchmark'))
import representation as runner


class RepresentationRunnerTests(unittest.TestCase):
    def test_failed_catalogue_generation_keeps_both_output_streams(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)/'new-output'
            def fail(command,**kwargs):
                result = subprocess.CompletedProcess(command,7,stdout='fixture stdout\n',stderr='R failure\n')
                if kwargs.get('check'):result.check_returncode()
                return result
            args = ['representation.py','--catalogues','1','--output-dir',str(output)]
            with patch.object(sys,'argv',args),patch.object(runner.subprocess,'run',side_effect=fail):
                with self.assertRaises(subprocess.CalledProcessError):runner.main()
            self.assertEqual((output/'catalogue-1.log').read_text(),'fixture stdout\nR failure\n')
            self.assertFalse((output/'report.json').exists())

    def test_identity_helper_changes_rejected_before_and_after_worker(self):
        helper = ROOT/'tools/benchmark/implementation_identity.R'
        self.assertIn(helper,runner.SCRIPTS)
        self.assertEqual(runner.RUN_CODE[str(helper.relative_to(ROOT))],runner.rep.digest(helper.read_bytes()))
        original = Path.read_bytes
        for before in [True,False]:
            with self.subTest(changed_before_worker=before),tempfile.TemporaryDirectory() as tmp:
                changed = before
                def read(path):
                    raw = original(path)
                    return raw+b'\n# changed helper\n' if path==helper and changed else raw
                def complete(*args,**kwargs):
                    nonlocal changed
                    changed = True
                    return subprocess.CompletedProcess(args[0],0,stdout='{}',stderr='')
                with patch.object(Path,'read_bytes',read),patch.object(runner.subprocess,'run',side_effect=complete) as run:
                    with self.assertRaisesRegex(ValueError,'Benchmark code changed'):
                        runner.run_job(Path(tmp),'guard',dict(phase='export'))
                    self.assertEqual(run.call_count,0 if before else 1)
                self.assertFalse((Path(tmp)/'guard.result.json').exists())


if __name__=='__main__':unittest.main()
