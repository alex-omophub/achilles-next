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
import urllib.parse
import urllib.request

LIBRARY = os.environ.get('ACHILLES_NEXT_VIEWER_TEST_LIBRARY')
BUNDLES = os.environ.get('TRACER_TEST_BUNDLES')


class InstalledViewerCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='achilles-next-viewer-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / 'bundle'
        self.rscript = subprocess.check_output(['Rscript', '-e', 'cat(file.path(R.home("bin"),"Rscript"))'], text=True).strip()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    @contextlib.contextmanager
    def serving(self, folder=None, *, trusted_context=None, receipt=None):
        control = self.root / ('control-' + str(time.monotonic_ns()))
        script = self.root / 'serve.R'
        script.write_text('''args <- commandArgs(TRUE)
library(AchillesNext)
dbAttempts <- 0L
assignInNamespace("connect", function(...) {
  dbAttempts <<- dbAttempts + 1L
  stop("Database access is disabled for installed file viewing")
}, ns="DatabaseConnector")
options <- list(bundleDir=args[1], browse=FALSE, block=FALSE, basePath="/nested/results-view/")
if (nzchar(args[3])) {
  trusted <- jsonlite::read_json(args[3])
  options$authorize <- function(context) {
    keys <- c("publication_id", "release_id", "source_id", "access_scope_id")
    !file.exists(paste0(args[3], ".revoked")) && identical(context[keys], trusted[keys]) &&
      identical(context$root$sha256, trusted$root$sha256)
  }
}
if (nzchar(args[4])) options$bundleDir <- jsonlite::read_json(args[4])
v <- do.call(viewResults, options)
writeLines(jsonlite::toJSON(list(url=v$url, shiny_loaded="shiny" %in% loadedNamespaces()),auto_unbox=TRUE),args[2])
while (!file.exists(paste0(args[2],".stop"))) httpuv::service(100)
v$stop(); v$stop()
stopifnot(dbAttempts == 0L)
''')
        fakebin = self.root / 'no-node'; fakebin.mkdir(exist_ok=True)
        sentinel = self.root / 'unexpected-node-call'
        for name in ('node', 'npm', 'npx'):
            executable = fakebin / name
            executable.write_text(f'#!/bin/sh\necho invoked > "{sentinel}"\nexit 97\n')
            executable.chmod(0o700)
        env = dict(os.environ, R_LIBS=str(LIBRARY), PATH=str(fakebin) + os.pathsep + os.defpath)
        with (self.root / 'server.log').open('w') as log:
            args = [self.rscript, str(script), str(folder or self.bundle), str(control),
                    str(trusted_context or ''), str(receipt or '')]
            process = subprocess.Popen(args, env=env, stdout=log, stderr=subprocess.STDOUT)
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


@unittest.skipUnless(LIBRARY and BUNDLES, 'Set ACHILLES_NEXT_VIEWER_TEST_LIBRARY and TRACER_TEST_BUNDLES for installed-viewer checks')
class LocalViewerTests(InstalledViewerCase):
    def setUp(self):
        super().setUp()
        shutil.copytree(Path(BUNDLES) / 'a-5.5', self.bundle)

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

    @unittest.skipUnless(os.environ.get('PUBLICATION_TEST_BUNDLES'), 'Set PUBLICATION_TEST_BUNDLES for complete scope checks')
    def test_complete_scoped_releases_without_node(self):
        root = Path(os.environ['PUBLICATION_TEST_BUNDLES'])
        for scope in ('restricted', 'distributable'):
            store = root / scope
            pointer = json.loads((store / 'current.json').read_text())
            folder = store / pointer['path']
            with self.subTest(scope=scope), self.serving(folder) as url:
                self.assertEqual(self.status(url), 'ready')
                m = json.loads(self.get(url + 'api/manifest.json')[2])
                self.assertEqual(m['publication'], 'complete')
                self.assertEqual(m['disclosure']['scope'], scope)
                doc = json.loads(self.get(url + 'api/results/measurement.numeric_summary.json')[2])
                if scope == 'distributable':
                    self.assertEqual(doc['state'], 'suppressed')
                    self.assertIsNone(doc['rows'])
                    self.assertEqual(json.loads(self.get(url + 'api/terminology.json')[2])['concepts'], [])
                self.assertEqual(self.get(url + 'api/plan.json')[0], 404)
                self.assertEqual(self.get(url + 'api/current.json')[0], 404)

    def test_contract_10_rejects_distributable_scope_before_serving_payload(self):
        path = self.bundle / 'manifest.json'
        doc = json.loads(path.read_text())
        self.assertEqual(doc['contract_version'], '1.0.0')
        doc['request']['output_scope'] = 'distributable'
        doc['disclosure']['scope'] = 'distributable'
        path.write_text(json.dumps(doc))
        with self.serving() as url:
            self.assertEqual(self.status(url), 'invalid')
            self.assertEqual(self.get(url + 'api/results/person.count.json')[0], 404)

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


@unittest.skipUnless(LIBRARY, 'Set ACHILLES_NEXT_VIEWER_TEST_LIBRARY for installed publication viewer checks')
class PublicationViewerTests(InstalledViewerCase):
    def setUp(self):
        super().setUp()
        self.trusted_context = self.root / 'approved-context.json'
        self.make_publication(self.bundle, self.trusted_context)

    def make_publication(self, folder, context, *, labelled=False):
        fixture = Path(__file__).parent / 'tracer' / 'saved-result-fixture.R'
        subprocess.run([self.rscript, '--vanilla', '-e',
                        'args <- commandArgs(TRUE); library(AchillesNext); source(args[1]); '
                        'ids <- as.character(0:12); labels <- if (args[4]=="yes") '
                        'setNames(as.list(paste("Shared + µ",ids)),ids) else NULL; '
                        'x <- makeSavedResultFixture(args[2], pageRows=32L, extraConceptIds=ids[-1], '
                        'savedLabels=labels, saveCalendar=TRUE); '
                        'jsonlite::write_json(x$context, args[3], auto_unbox=TRUE)',
                        str(fixture.resolve()), str(folder), str(context), 'yes' if labelled else 'no'],
                       check=True, env=dict(os.environ, R_LIBS=LIBRARY))

    def test_installed_catalogue_and_people_are_bounded_and_pinned(self):
        with self.serving(trusted_context=self.trusted_context) as url:
            self.assertIn(b'content="served-publication"', self.get(url)[2])
            code, _, body = self.get(url + 'api/people.json')
            self.assertEqual(code, 200)
            people = json.loads(body)
            self.assertFalse(people['generation_requested'])
            self.assertEqual(people['rows'][0]['values']['person_count'], '10')
            self.assertEqual(people['context']['source_id'], 'fixture:semantic')
            head_code, headers, head_body = self.get(url + 'api/people.json', method='HEAD')
            self.assertEqual(head_code, 200)
            self.assertEqual(head_body, b'')
            # Provider budget counters may change once the page is cached.
            self.assertGreater(int(headers['Content-Length']), 0)
            metrics = []
            path = 'api/catalogue.json'
            first_cursor = None
            while True:
                code, _, body = self.get(url + path)
                self.assertEqual(code, 200)
                self.assertLessEqual(len(body), 1024 * 1024)
                page = json.loads(body)
                self.assertEqual(page['context'], people['context'])
                self.assertFalse(page['generation_requested'])
                self.assertGreater(len(page['metrics']), 0)
                self.assertLessEqual(len(page['metrics']), 12)
                metrics.extend(page['metrics'])
                self.assertLessEqual(len(metrics), 142)
                if page['complete']:
                    self.assertIsNone(page['cursor'])
                    break
                self.assertTrue(page['cursor'])
                if first_cursor is None:
                    first_cursor = page['cursor']
                path = 'api/catalogue.json?' + urllib.parse.urlencode({'cursor': page['cursor']})
            ids = [entry['metric_id'] for entry in metrics]
            self.assertEqual(len(ids), 142)
            self.assertEqual(ids, sorted(set(ids)))
            drug = next(entry for entry in metrics if entry['metric_id'] == 'core.drug.capture_count')
            self.assertEqual(drug['state'], 'suppressed')
            self.assertIsNotNone(first_cursor)
            for path in ['publication.json', 'api/publication.json', 'api/results/person.count.json']:
                self.assertEqual(self.get(url + path)[0], 404)
            self.assertEqual(self.get(url + 'api/catalogue.json', headers={'Origin': 'https://different.example'})[0], 403)
            self.assertEqual(self.get(url + 'api/people.json', method='POST')[0], 405)
            for query in ['?limit=1000000', '?cursor=invalid', '?cursor=x&cursor=y']:
                self.assertGreaterEqual(self.get(url + 'api/catalogue.json' + query)[0], 400)
        # Even opening the same artifact again creates a separate viewing instance.
        with self.serving(trusted_context=self.trusted_context) as reopened:
            path = 'api/catalogue.json?' + urllib.parse.urlencode({'cursor': first_cursor})
            self.assertGreaterEqual(self.get(reopened + path)[0], 400)

    def test_saved_report_pages_preserve_values_and_verify_dependencies(self):
        with self.serving(trusted_context=self.trusted_context) as url:
            def report(metric, query=''):
                code, _, body = self.get(url + 'api/reports/' + metric + '.json' + query)
                self.assertEqual(code, 200)
                self.assertLessEqual(len(body), 1024 * 1024)
                result = json.loads(body)
                self.assertEqual(result['dataset']['metric_id'], metric)
                self.assertFalse(result['generation_requested'])
                return result

            gender = 'core.person.gender_count'
            first = report(gender)
            self.assertFalse(first['complete'])
            self.assertTrue(first['cursor'])
            query = '?' + urllib.parse.urlencode({'cursor': first['cursor']})
            second = report(gender, query)
            self.assertTrue(second['complete'])
            self.assertIsNone(second['cursor'])
            self.assertEqual([len(first['rows']), len(second['rows'])], [12, 2])
            self.assertEqual(first['context'], second['context'])
            counts = {}
            for page in [first, second]:
                denominator, = page['dependencies']
                self.assertEqual(denominator['metric_id'], 'core.person.count')
                for row in page['rows']:
                    self.assertEqual(row['state'], 'computed')
                    self.assertEqual(row['denominator_refs'][0]['row_key'], denominator['row']['row_key'])
                    counts[row['dimensions']['gender_concept_id']] = row['values']['person_count']
            expected = {str(i): '0' for i in range(1, 13)}
            expected.update({'0': '6', '9007199254740993': '4'})
            self.assertEqual(counts, expected)
            for suffix in ['core.person.count.json' + query, 'core.unknown.metric.json',
                           'core.person.count.json?maxRows=1', 'core.person.count.json?cursor=x&cursor=y']:
                code, _, body = self.get(url + 'api/reports/' + suffix)
                self.assertEqual(code, 400)
                self.assertEqual(set(json.loads(body)), {'error'})
            self.assertEqual(self.get(url + 'api/reports/extra/directory.json')[0], 404)

            summary = report('core.measurement.numeric_summary')
            self.assertTrue(all(row['row_kind'] == 'summary' for row in summary['rows']))
            medians = {row['dimensions']['unit_concept_tag']['value']: row['values']['p50']
                       for row in summary['rows']}
            self.assertEqual(medians, {'456': '2.5', '777': None, '9007199254740993': '2.5'})
            suppressed = report('core.drug.capture_count')
            self.assertEqual((suppressed['state'], suppressed['rows'], suppressed['dependencies']),
                             ('suppressed', [], []))
            empty = report('core.specimen.capture_count')['rows'][0]
            self.assertEqual((empty['state'], empty['values']['record_count']), ('empty_source', '0'))
            unavailable = report('core.visit.care_setting_count')['rows'][0]
            self.assertEqual((unavailable['state'], unavailable['values']), ('unavailable', None))

    def test_saved_filters_preserve_exact_strata_calendar_and_unavailable_selections(self):
        with self.serving(trusted_context=self.trusted_context) as url:
            def report(metric, filters, cursor=None, cursor_first=False):
                params = [('filters', json.dumps(filters))]
                if cursor is not None:
                    params.insert(0 if cursor_first else 1, ('cursor', cursor))
                return self.get(url + 'api/reports/' + metric + '.json?' + urllib.parse.urlencode(params))

            gender = 'core.person.gender_count'
            _, _, body = report(gender, {})
            cursor = json.loads(body)['cursor']
            self.assertTrue(cursor)
            for first in [True, False]:
                code, _, body = report(gender, {}, cursor, first)
                self.assertEqual(code, 200)
                self.assertEqual(len(json.loads(body)['rows']), 2)
            self.assertEqual(report(gender, {'gender_concept_id': '0'}, cursor)[0], 400)
            code, _, body = report(gender, {'gender_concept_id': '9007199254740993'})
            self.assertEqual((code, json.loads(body)['rows'][0]['values']['person_count']), (200, '4'))
            period = {'period_kind': 'calendar_month', 'period_start': '2020-02-01', 'period_end': '2020-02-29'}
            filters = dict(period, concept_tag={'kind': 'id', 'value': '123'})
            code, _, body = report('core.condition.capture_count', filters)
            monthly = json.loads(body)
            self.assertEqual(code, 200)
            self.assertEqual(monthly['selection']['filters'], filters)
            self.assertEqual([r['values']['record_count'] for r in monthly['rows']], ['2'])
            metric = 'core.measurement.numeric_summary'
            code, _, body = report(metric, {'unit_concept_tag': {'kind': 'id', 'value': '777'},
                                            'raw_operator_tag': {'kind': 'null'}})
            self.assertEqual(code, 200)
            summary = json.loads(body)
            self.assertEqual(summary['rows'][0]['values']['n'], '0')
            self.assertEqual(summary['dependencies'][0]['row']['values']['record_count'], '0')
            for selector in [period, {'eligibility_reason': 'eligible'}]:
                code, _, body = report(metric, selector)
                page = json.loads(body)
                self.assertEqual((code, page['state'], page['generation_requested']),
                                 (200, 'additional_batch_job_required', False))
            code, _, body = report(gender, {'gender_concept_id': '98765'})
            self.assertEqual((code, json.loads(body)['state']), (200, 'not_saved'))
            for bad in [[], None, {'gender_concept_id': 0}, {'gender_concept_id': '00'},
                        {'gender_concept_id': '0\x00ignored'}, {'period_kind': 'calendar_month'}]:
                self.assertEqual(report(gender, bad)[0], 400)
            path = url + 'api/reports/' + gender + '.json?'
            duplicate = urllib.parse.urlencode({'filters': '{"gender_concept_id":"1","gender_concept_id":"2"}'})
            for bad in [duplicate, 'filters=%7B%7D&filters=%7B%7D', 'filters=%ZZ', 'filters=%FF',
                        'filters=%00', 'filters=%7B%7D&', 'cursor=bad&extra=1', 'filters=1&cursor=']:
                code, _, body = self.get(path + bad)
                self.assertEqual((code, json.loads(body)), (400, {'error': 'invalid_request'}))

    def test_lookup_and_prefix_search_use_only_authorized_saved_terminology(self):
        def concepts(base, method, **params):
            code, _, body = self.get(base + 'api/concepts/' + method + '.json?' + urllib.parse.urlencode(params))
            self.assertLessEqual(len(body), 1024 * 1024)
            return code, json.loads(body)

        with self.serving(trusted_context=self.trusted_context) as url:
            code, search = concepts(url, 'search', q='Shared')
            self.assertEqual((code, search['state'], search['searched'], search['reason_code']),
                             (200, 'unavailable', False, 'terminology.name_index_not_saved'))
            code, lookup = concepts(url, 'lookup', id='9007199254740993')
            self.assertEqual((code, lookup['concepts'][0]['state'], lookup['concepts'][0]['label']),
                             (200, 'available', None))

        folder = self.root / 'labelled'
        context = self.root / 'labelled-context.json'
        self.make_publication(folder, context, labelled=True)
        with self.serving(folder, trusted_context=context) as url:
            query = 'Shared + µ'
            code, first = concepts(url, 'search', q=query)
            self.assertEqual((code, first['state'], first['query'], first['searched']), (200, 'available', query, True))
            self.assertEqual(len(first['concepts']), 12)
            code, last = concepts(url, 'search', cursor=first['cursor'], q=query)
            self.assertEqual((code, last['complete'], len(last['concepts'])), (200, True, 1))
            names = {v['label'] for v in first['concepts'] + last['concepts']}
            self.assertEqual(names, {query + ' ' + str(i) for i in range(13)})
            self.assertEqual(concepts(url, 'search', q='other', cursor=first['cursor'])[0], 400)
            self.assertEqual(concepts(url, 'lookup', id='1')[1]['concepts'][0]['label'], query + ' 1')
            self.assertEqual(concepts(url, 'lookup', id='-100')[1]['concepts'][0]['state'], 'not_saved')
            for path in ['search.json', 'search.json?q=a&q=b', 'search.json?q=%00', 'search.json?q=%FF',
                         'lookup.json?id=1&id=2', 'lookup.json?id=01', 'lookup.json?id=1&cursor=x',
                         'lookup.json?id=1.0', 'lookup.json?q=x']:
                self.assertEqual(self.get(url + 'api/concepts/' + path)[0], 400)
            Path(str(context) + '.revoked').touch()
            self.assertEqual(concepts(url, 'lookup', id='1'), (403, {'error': 'inaccessible'}))
            self.assertEqual(concepts(url, 'search', q=query), (403, {'error': 'inaccessible'}))

    def test_authorization_is_required_and_rechecked_for_cached_results(self):
        path = 'api/reports/core.person.gender_count.json'
        with self.serving() as url:
            self.assertEqual(self.status(url), 'inaccessible')
            self.assertGreaterEqual(self.get(url + 'api/people.json')[0], 400)
            self.assertEqual(self.get(url + path)[0], 403)
        with self.serving(trusted_context=self.trusted_context) as url:
            self.assertEqual(self.get(url + 'api/people.json')[0], 200)
            self.assertEqual(self.get(url + path)[0], 200)
            Path(str(self.trusted_context) + '.revoked').touch()
            code, _, body = self.get(url + path)
            self.assertEqual((code, json.loads(body)), (403, {'error': 'inaccessible'}))
            self.assertGreaterEqual(self.get(url + 'api/people.json')[0], 400)
            self.assertGreaterEqual(self.get(url + 'api/catalogue.json')[0], 400)

    def test_receipt_opens_only_its_pinned_publication(self):
        trusted = json.loads(self.trusted_context.read_bytes())
        receipt = self.root / 'receipt.json'
        pin = {'export_dir': str(self.bundle), 'publication_id': trusted['publication_id'],
               'root': trusted['root'], 'revision': '1'}
        receipt.write_text(json.dumps(pin))
        with self.serving(receipt=receipt) as url:
            self.assertEqual(self.status(url), 'ready')
            code, _, body = self.get(url + 'api/people.json')
            self.assertEqual(code, 200)
            self.assertEqual(json.loads(body)['context']['publication_id'], pin['publication_id'])
        with self.serving(receipt=receipt, trusted_context=self.trusted_context) as url:
            Path(str(self.trusted_context) + '.revoked').touch()
            self.assertGreaterEqual(self.get(url + 'api/people.json', method='HEAD')[0], 400)
        for different_pin in (dict(pin, root=dict(pin['root'], sha256='e' * 64)),
                              dict(pin, publication_id='00000000-0000-4000-8000-000000000099')):
            receipt.write_text(json.dumps(different_pin))
            with self.serving(receipt=receipt) as url:
                self.assertNotEqual(self.status(url), 'ready')
                self.assertGreaterEqual(self.get(url + 'api/people.json')[0], 400)

    @unittest.skipUnless(BUNDLES, 'Set TRACER_TEST_BUNDLES for dual-format downgrade check')
    def test_missing_receipt_pointer_never_opens_colocated_v1_payload(self):
        trusted = json.loads(self.trusted_context.read_bytes())
        receipt = self.root / 'receipt.json'
        receipt.write_text(json.dumps({'export_dir': str(self.bundle), 'publication_id': trusted['publication_id'],
                                       'root': trusted['root'], 'revision': '1'}))
        (self.bundle / 'publication.json').unlink()
        shutil.copytree(Path(BUNDLES) / 'a-5.5', self.bundle, dirs_exist_ok=True)
        with self.serving(receipt=receipt) as url:
            self.assertNotEqual(self.status(url), 'ready')
            self.assertGreaterEqual(self.get(url + 'api/people.json')[0], 400)
            self.assertGreaterEqual(self.get(url + 'api/results/person.count.json')[0], 400)

    def test_corrupt_unrequested_data_is_checked_on_read(self):
        leaf = next(p for p in (self.bundle / 'objects').glob('*.json')
                    if json.loads(p.read_bytes()).get('metric_id') == 'core.person.count')
        leaf.write_bytes(b'{}')
        with self.serving(trusted_context=self.trusted_context) as url:
            self.assertEqual(self.get(url + 'api/catalogue.json')[0], 200)
            code, _, body = self.get(url + 'api/people.json')
            self.assertGreaterEqual(code, 400)
            self.assertNotIn(b'person_count', body)
            self.assertNotIn(str(self.bundle).encode(), body)


if __name__ == '__main__':
    unittest.main()
