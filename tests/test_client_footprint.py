"""Offline client-path coverage and failed-baseline evidence retention."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMMAND = [sys.executable, str(ROOT/'tools/benchmark/client_footprint.py')]


class ClientFootprintCLI(unittest.TestCase):
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
