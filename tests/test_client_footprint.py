"""Offline client-path coverage and failed-baseline evidence retention."""
import json
import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
COMMAND = [sys.executable, str(ROOT/'tools/benchmark/client_footprint.py')]
_saved_path = sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools/benchmark'))
    import client_footprint as CLIENT
finally:
    sys.path[:] = _saved_path


class ClientFootprintCLI(unittest.TestCase):
    def checkout(self,base):
        root=base/'checkout';tools=root/'tools/benchmark';tools.mkdir(parents=True)
        for name in ['client_footprint.py','client_footprint.R','resource_telemetry.py','implementation_identity.R']:
            (tools/name).write_bytes((ROOT/'tools/benchmark'/name).read_bytes())
        return root

    def test_checkout_output_and_resolved_symlink_alias_are_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder).resolve();root=self.checkout(base);alias=base/'alias';alias.symlink_to(root,target_is_directory=True)
            for output in [root,root/'evidence/run',alias/'evidence/run']:
                with self.subTest(output=output),patch.object(CLIENT,'__file__',str(root/'tools/benchmark/client_footprint.py')), \
                     patch.object(sys,'argv',['baseline','--output',str(output),'--rscript',sys.executable]), \
                     patch.object(CLIENT,'observe') as launch,contextlib.redirect_stderr(io.StringIO()) as errors:
                    with self.assertRaises(SystemExit) as stopped:CLIENT.main()
                    self.assertEqual(stopped.exception.code,2)
                    self.assertIn('outside the checkout',errors.getvalue());launch.assert_not_called()
                    self.assertFalse((root/'evidence').exists())

    def test_harness_edits_or_removal_during_worker_preserve_failed_evidence(self):
        for name in ['client_footprint.py','client_footprint.R','resource_telemetry.py','implementation_identity.R']:
            for remove in [False,True]:
                with self.subTest(name=name,remove=remove),tempfile.TemporaryDirectory() as folder:
                    base=Path(folder).resolve();root=self.checkout(base);output=base/'output'
                    def observe(command,run,**kwargs):
                        (run/'worker.log').write_text('retained worker evidence')
                        target=root/'tools/benchmark'/name
                        if remove:target.unlink()
                        else:target.write_bytes(target.read_bytes()+b'\n# changed\n')
                        return dict(status='completed')
                    with patch.object(CLIENT,'__file__',str(root/'tools/benchmark/client_footprint.py')), \
                         patch.object(sys,'argv',['baseline','--output',str(output),'--rscript',sys.executable]), \
                         patch.object(CLIENT,'observe',side_effect=observe) as launch:
                        with self.assertRaisesRegex(RuntimeError,'Harness changed'):CLIENT.main()
                        self.assertEqual(launch.call_count,1)
                    manifest=json.loads((output/'manifest.json').read_text())
                    self.assertEqual(manifest['status'],'failed');self.assertIn(name,manifest['error'])
                    self.assertEqual(len(manifest['runs']),1)
                    self.assertEqual((output/'1-plan/worker.log').read_text(),'retained worker evidence')
                    self.assertFalse((output/'1-primitives').exists())

    def test_harness_change_before_launch_stops_without_worker(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder).resolve();root=self.checkout(base);output=base/'output';mkdir=Path.mkdir
            def create(path,*args,**kwargs):
                value=mkdir(path,*args,**kwargs)
                if path==output/'1-plan/tmp':
                    target=root/'tools/benchmark/client_footprint.R';target.write_bytes(target.read_bytes()+b'\n# changed\n')
                return value
            with patch.object(CLIENT,'__file__',str(root/'tools/benchmark/client_footprint.py')), \
                 patch.object(sys,'argv',['baseline','--output',str(output),'--rscript',sys.executable]), \
                 patch.object(Path,'mkdir',create),patch.object(CLIENT,'observe') as launch:
                with self.assertRaisesRegex(RuntimeError,'Harness changed'):CLIENT.main()
                launch.assert_not_called()
            manifest=json.loads((output/'manifest.json').read_text())
            self.assertEqual(manifest['status'],'failed');self.assertEqual(manifest['runs'],[])

    def test_invalid_inputs_do_not_create_output(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)/'output'
            for flags in [['--repeats','0'],['--artifact',folder],['--context',folder],['--rscript','missing-client-rscript']]:
                result = subprocess.run(COMMAND+['--output',str(output)]+flags,capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(output.exists())

    @unittest.skipUnless(os.environ.get('ACHILLES_NEXT_CLIENT_TEST')=='1','opt-in installed R package; no DB required')
    def test_native_offline_paths_and_failed_admission(self):
        with tempfile.TemporaryDirectory() as folder:
            temp = Path(folder); fixture = temp/'fixture'; context = temp/'context.json'; output = temp/'baseline'
            # Use the independent reduced-scope fixture, never a real CDM.
            script = temp/'fixture.R'
            script.write_text('library(AchillesNext)\nsource("tests/tracer/saved-result-fixture.R")\n'
                'a<-commandArgs(TRUE);x<-makeSavedResultFixture(a[[1]],savedLabels=list("123"="Synthetic condition"));'
                'jsonlite::write_json(x$context,a[[2]],auto_unbox=TRUE,null="null")\n')
            subprocess.run(['Rscript','--vanilla',str(script),str(fixture),str(context)],cwd=ROOT,check=True,capture_output=True)
            def run(destination):
                return subprocess.run(COMMAND+['--output',str(destination),'--repeats','1',
                    '--artifact',str(fixture),'--context',str(context)],cwd=ROOT,capture_output=True,text=True)
            result = run(output)
            logs = '\n'.join(p.read_text() for p in output.glob('*/worker.log')) if output.exists() else ''
            self.assertEqual(result.returncode,0,result.stderr+'\n'+logs)
            manifest = json.loads((output/'manifest.json').read_text())
            self.assertEqual(manifest['status'],'completed');self.assertFalse(manifest['qualifying'])
            self.assertEqual(len(manifest['runs']),3)
            for mode in ['plan','primitives','saved']:
                worker = json.loads((output/f'1-{mode}'/'worker.json').read_text())
                self.assertEqual(worker['status'],'completed');self.assertEqual(worker['connector_attempts'],0)
                if mode!='saved':
                    self.assertFalse(worker['connector_namespace_loaded'])
                    self.assertFalse(worker['JVM']['initialized'])
            plans = json.loads((output/'1-plan/products.json').read_text())
            self.assertEqual(set(plans),{f'{v}-{s}' for v in ['5.3','5.4','5.5'] for s in ['reference','shared']})
            primitives = json.loads((output/'1-primitives/products.json').read_text())
            self.assertEqual(set(primitives),{'5.3','5.4','5.5'})
            for sql in primitives.values():
                self.assertEqual(set(sql),{'interval','condition','drug','procedure','visit','device',
                    'observation','death','specimen','measurement','capture','coverage','numeric_reference','numeric_weighted'})
                self.assertNotIn('{{',''.join(sql.values()))
            saved = json.loads((output/'1-saved/worker.json').read_text())
            self.assertEqual(len(saved['reads']),100)
            self.assertLessEqual(saved['reader']['cache_bytes'],4194304)
            self.assertGreater(saved['reader']['cache_hits'],0)
            # Corruption must fail admission and retain both process and R evidence.
            pointer = json.loads((fixture/'publication.json').read_text())
            (fixture/'objects'/f"{pointer['root']['sha256']}.json").write_text('{}')
            failed = temp/'failed'; result = run(failed)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(json.loads((failed/'manifest.json').read_text())['status'],'failed')
            worker = json.loads((failed/'1-saved/worker.json').read_text())
            self.assertEqual(worker['status'],'failed');self.assertEqual(worker['connector_attempts'],0)
            self.assertEqual(worker['error'],'Result artifact validation failed')
            self.assertEqual(json.loads((failed/'1-saved/process-telemetry.json').read_text())['status'],'failed_or_stopped')
            # Force connector loading/use to prove the deferred hook rejects it.
            worker_source = (ROOT/'tools/benchmark/client_footprint.R').read_text()
            self.assertEqual(worker_source.count('products <- list()'),1)
            injected = temp/'injected.R'
            injected.write_text(worker_source.replace('products <- list()','DatabaseConnector::connect(NULL); products <- list()'))
            rejected = temp/'rejected';rejected.mkdir()
            result = subprocess.run(['Rscript','--vanilla',str(injected),'plan',str(ROOT),str(rejected),'',''],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            worker = json.loads((rejected/'worker.json').read_text())
            self.assertEqual(worker['connector_attempts'],1)
            self.assertIn('Offline worker attempted',worker['error'])
