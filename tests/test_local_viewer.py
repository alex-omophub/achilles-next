"""Installed R viewer boundary tests. Requires explicit local synthetic inputs."""
import contextlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

LIBRARY = os.environ.get('ACHILLES_NEXT_VIEWER_TEST_LIBRARY')
BUNDLES = os.environ.get('TRACER_TEST_BUNDLES')


@unittest.skipUnless(LIBRARY and BUNDLES, 'Set ACHILLES_NEXT_VIEWER_TEST_LIBRARY and TRACER_TEST_BUNDLES for installed-viewer checks')
class LocalViewerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='achilles-next-viewer-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / 'bundle'
        shutil.copytree(Path(BUNDLES) / 'a-5.5', self.bundle)
        self.rscript = subprocess.check_output(['Rscript', '-e', 'cat(file.path(R.home("bin"),"Rscript"))'], text=True).strip()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    @contextlib.contextmanager
    def serving(self, folder=None):
        control = self.root / ('control-' + str(time.monotonic_ns()))
        script = self.root / 'serve.R'
        script.write_text('''args <- commandArgs(TRUE)
library(AchillesNext)
v <- viewResults(args[1], browse=FALSE, block=FALSE, basePath="/nested/results-view/")
writeLines(jsonlite::toJSON(list(url=v$url, shiny_loaded="shiny" %in% loadedNamespaces()),auto_unbox=TRUE),args[2])
while (!file.exists(paste0(args[2],".stop"))) httpuv::service(100)
v$stop(); v$stop()
''')
        fakebin = self.root / 'no-node'; fakebin.mkdir(exist_ok=True)
        sentinel = self.root / 'unexpected-node-call'
        for name in ('node', 'npm', 'npx'):
            executable = fakebin / name
            executable.write_text(f'#!/bin/sh\necho invoked > "{sentinel}"\nexit 97\n')
            executable.chmod(0o700)
        env = dict(os.environ, R_LIBS=str(LIBRARY), PATH=str(fakebin) + os.pathsep + os.defpath)
        with (self.root / 'server.log').open('w') as log:
            process = subprocess.Popen([self.rscript, str(script), str(folder or self.bundle), str(control)],
                                       env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 15
                while not control.exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        self.fail((self.root / 'server.log').read_text())
                    time.sleep(0.05)
                info = json.loads(control.read_text())
                self.assertFalse(info['shiny_loaded'])
                yield info['url']
            finally:
                Path(str(control) + '.stop').touch()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
                self.assertEqual(process.returncode, 0, (self.root / 'server.log').read_text())
                self.assertFalse(sentinel.exists(), 'Installed viewing invoked Node/npm/npx')

    def get(self, url, *, method='GET', headers=None):
        request = urllib.request.Request(url, method=method, headers=headers or {})
        try:
            response = self.opener.open(request, timeout=5)
        except urllib.error.HTTPError as response:
            with response:
                return response.code, response.headers, response.read()
        with response:
            return response.status, response.headers, response.read()

    def status(self, url):
        code, _, body = self.get(url + 'api/status.json')
        self.assertEqual(code, 200)
        return json.loads(body)['state']

    def test_installed_viewer_nonroot_assets_and_no_node(self):
        with self.serving() as url:
            self.assertTrue(url.startswith('http://127.0.0.1:'))
            self.assertTrue(url.endswith('/nested/results-view/'))
            code, headers, body = self.get(url)
            self.assertEqual(code, 200)
            self.assertIn(b'content="served-bundle"', body)
            self.assertNotIn('unsafe-eval', headers['Content-Security-Policy'])
            self.assertEqual(self.status(url), 'ready')
            asset = re.search(rb'src="[.]/(assets/[^" ]+[.]js)"', body).group(1).decode()
            code, asset_headers, asset_body = self.get(url + asset)
            self.assertEqual(code, 200); self.assertIn('javascript', asset_headers['Content-Type'])
            self.assertGreater(len(asset_body), 1000)
            code, _, data = self.get(url + 'api/results/person.count.json')
            self.assertEqual(code, 200)
            self.assertEqual(json.loads(data)['rows'][0]['values']['count'], '4')
            head_code, head_headers, head_body = self.get(url + asset, method='HEAD')
            self.assertEqual(head_code, 200); self.assertEqual(head_body, b'')
            self.assertEqual(int(head_headers['Content-Length']), len(asset_body))

    def test_only_declared_snapshot_and_local_read_methods(self):
        (self.bundle / 'secret.txt').write_text('must-not-be-served')
        (self.bundle / 'results/hidden.json').write_text('must-not-be-served')
        with self.serving() as url:
            for path in ('secret.txt', 'api/secret.txt', 'api/results/hidden.json', 'api/../secret.txt',
                         'api/%2e%2e/secret.txt', 'api/manifest.json?path=../../secret.txt', 'viewer-lock.json'):
                self.assertEqual(self.get(url + path)[0], 404, path)
            self.assertEqual(self.get(url, headers={'Host': 'attacker.example'})[0], 403)
            self.assertEqual(self.get(url + 'api/manifest.json', headers={'Origin': 'https://attacker.example'})[0], 403)
            self.assertEqual(self.get(url + 'api/manifest.json', method='POST')[0], 405)
            before = self.get(url + 'api/results/person.count.json')[2]
            (self.bundle / 'results/person.count.json').write_text('changed after opening')
            self.assertEqual(self.get(url + 'api/results/person.count.json')[2], before)

    @unittest.skipUnless(os.environ.get('OBSERVATION_TEST_BUNDLES'), 'Set OBSERVATION_TEST_BUNDLES for the observation viewer')
    def test_observation_bundle_is_available_under_nested_base(self):
        folder = Path(os.environ['OBSERVATION_TEST_BUNDLES']) / 'tiny_a_2020-5.5'
        with self.serving(folder) as url:
            self.assertEqual(self.status(url), 'ready')
            for metric, expected in [('person.count', '4'), ('observation.person_count', '3'), ('observation.person_days', '24')]:
                code, _, body = self.get(url + 'api/results/' + metric + '.json')
                self.assertEqual(code, 200)
                self.assertEqual(json.loads(body)['rows'][0]['values']['count'], expected)

    @unittest.skipUnless(os.environ.get('MEASUREMENT_TEST_BUNDLES'), 'Set MEASUREMENT_TEST_BUNDLES for the measurement viewer')
    def test_measurement_bundle_is_available_without_node_under_nested_base(self):
        folder = Path(os.environ['MEASUREMENT_TEST_BUNDLES']) / 'numeric-edges'
        with self.serving(folder) as url:
            self.assertEqual(self.status(url), 'ready')
            code, _, body = self.get(url + 'api/results/measurement.numeric_summary.json')
            self.assertEqual(code, 200)
            doc = json.loads(body)
            self.assertEqual(len(doc['rows']), 3)
            self.assertIn('9007199254740995.125', [r['values']['sum'] for r in doc['rows']])
            code, _, body = self.get(url + 'api/terminology.json')
            self.assertEqual(code, 200)
            self.assertEqual(json.loads(body)['provider_id'], 'local-concept-table')

    @unittest.skipUnless(os.environ.get('WEIGHTED_TEST_BUNDLES'), 'Set WEIGHTED_TEST_BUNDLES for the weighted viewer')
    def test_weighted_bundle_uses_same_installed_no_node_viewer(self):
        folder = Path(os.environ['WEIGHTED_TEST_BUNDLES']) / 'tiny_a_2020-5.5'
        with self.serving(folder) as url:
            self.assertEqual(self.status(url), 'ready')
            self.assertEqual(json.loads(self.get(url + 'api/manifest.json')[2])['generator']['name'], 'AchillesNext-measurement-weighted')
            rows = json.loads(self.get(url + 'api/results/measurement.numeric_summary.json')[2])['rows']
            self.assertEqual(next(r['values']['sum'] for r in rows if r['dimensions']['measurement_concept_id'] == 900000001), '100.5')

    def test_missing_invalid_incompatible_have_no_analytical_payload(self):
        cases = [('missing-folder', self.root / 'absent', 'missing'),
                 ('bad-json', self.bundle, 'invalid'), ('wrong-version', self.bundle, 'incompatible')]
        original = (self.bundle / 'manifest.json').read_text()
        for name, folder, expected in cases:
            if name == 'bad-json': (self.bundle / 'manifest.json').write_text('{not-json')
            elif name == 'wrong-version':
                doc = json.loads(original); doc['contract_version'] = '99.0.0'
                (self.bundle / 'manifest.json').write_text(json.dumps(doc))
            with self.subTest(name=name), self.serving(folder) as url:
                self.assertEqual(self.status(url), expected)
                if expected == 'incompatible':
                    message = json.loads(self.get(url + 'api/status.json')[2])['message']
                    self.assertIn('measurement reference/weighted bundles', message)
                self.assertEqual(self.get(url + 'api/results/person.count.json')[0], 404)

    def test_missing_tampered_and_symlinked_partitions_are_not_exposed(self):
        target = self.bundle / 'results/person.count.json'
        original = target.read_bytes()
        target.unlink()
        with self.serving() as url: self.assertEqual(self.status(url), 'missing')
        target.write_text('tampered')
        with self.serving() as url: self.assertEqual(self.status(url), 'invalid')
        target.unlink(); outside = self.root / 'outside.json'; outside.write_bytes(original)
        target.symlink_to(outside)
        with self.serving() as url:
            self.assertEqual(self.status(url), 'invalid')
            self.assertEqual(self.get(url + 'api/results/person.count.json')[0], 404)


if __name__ == '__main__':
    unittest.main()
