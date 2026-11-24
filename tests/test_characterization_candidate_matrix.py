"""Declared bridge coverage must not shrink to the snapshots a runner returned."""
from copy import deepcopy
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from test_characterization_candidate_sql import verify_matrix_coverage
import test_core_characterization as core


class CandidateMatrixTests(unittest.TestCase):
    def setUp(self):
        source = dict(id='nonempty')
        self.matrix = [(source, version) for version in ('5.3', '5.4', '5.5')] + [
            (dict(id='empty_source'), '5.5'), (dict(id='observation_tail'), '5.5')]
        self.report = dict(snapshots=[dict(case=case['id'], version=version, strategy=strategy)
                                     for case, version in self.matrix for strategy in ('weighted', 'reference')])

    def rejects(self, snapshots):
        with self.assertRaises(AssertionError):
            verify_matrix_coverage(dict(snapshots=snapshots), self.matrix)

    def test_exact_full_and_default_matrices_accept_arbitrary_order(self):
        expected = {(case['id'], version, strategy) for case, version in self.matrix
                    for strategy in ('weighted', 'reference')}
        self.assertEqual(verify_matrix_coverage(self.report, self.matrix), expected)
        self.assertEqual(verify_matrix_coverage(dict(snapshots=self.report['snapshots'][::-1]), self.matrix), expected)
        default = [self.matrix[2], self.matrix[3]]
        snapshots = [s for s in self.report['snapshots'] if s['version'] == '5.5' and s['case'] != 'observation_tail']
        self.assertEqual(len(verify_matrix_coverage(dict(snapshots=snapshots), default)), 4)

    def test_missing_whole_version_case_operator_and_empty_report_are_rejected(self):
        snapshots = self.report['snapshots']
        for missing in ([s for s in snapshots if s['version'] != '5.3'],
                        [s for s in snapshots if s['case'] != 'empty_source'], snapshots[:-1], []):
            with self.subTest(missing=len(snapshots) - len(missing)):
                self.rejects(missing)

    def test_duplicate_with_extra_or_same_cardinality_is_rejected(self):
        snapshots = self.report['snapshots']
        self.rejects(snapshots + snapshots[:1])
        self.rejects(snapshots[:-1] + snapshots[:1])

    def test_unexpected_case_version_or_strategy_cannot_replace_expected_attempt(self):
        for key, value in [('case', 'unexpected'), ('version', '5.6'), ('strategy', 'approximate')]:
            snapshots = deepcopy(self.report['snapshots'])
            snapshots[-1][key] = value
            with self.subTest(key=key):
                self.rejects(snapshots)

    def test_existing_publication_oracle_still_requires_refresh_by_default(self):
        for marker in (None, False):
            snapshot = dict(source_id='fixture:test')
            if marker is not None:
                snapshot['refresh_executed'] = marker
            report = dict(publication=dict(snapshot_source_id='fixture:test'), snapshots=[snapshot])
            with self.subTest(marker=marker), self.assertRaisesRegex(AssertionError, 'Expected executed refresh'):
                core.verify_publication(None, report)

    def test_publication_version_selects_only_the_requested_populated_source(self):
        case = dict(id='populated', person=[{'person_id': '1'}], observation_period=[])
        for version in ('5.3', '5.4', '5.5'):
            self.assertEqual(core.fixture_matrix(case, False, version), [(case, version)])
        for full, versions in ((False, ['5.3']), (True, ['5.3', '5.4', '5.5'])):
            matrix = core.fixture_matrix(case, full, None)
            self.assertEqual([(entry['id'], v) for entry, v in matrix], [('populated', v) for v in versions]
                             + [('empty_source', '5.5'), ('observation_tail', '5.5')])

    def test_invalid_publication_mode_refuses_before_creating_output(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'output'
            cli = [sys.executable, str(core.ROOT / 'tools/test_core_characterization.py'),
                   '--output-dir', str(output), '--config', 'unused', '--publication-version', '5.4']
            for options, message in [([], 'requires --with-publication'),
                                     (['--with-publication'], 'requires --state'),
                                     (['--with-publication', '--full-matrix'], 'not allowed with argument')]:
                result = subprocess.run(cli + options, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)
                self.assertFalse(output.exists())

    def test_publication_uses_validated_release_even_for_a_reused_source_id(self):
        source = 'fixture:reused'
        snapshots = [dict(source_id=source, release_id='first', validated=True),
                     dict(source_id=source, release_id='second', validated=True),
                     dict(source_id=source, candidate={'release_id': 'compiled'}, validated=True)]
        for index, release in enumerate(['first', 'second', 'compiled']):
            proof = dict(snapshot_source_id=source, release_id=release)
            self.assertIs(core.publication_snapshot(snapshots, proof), snapshots[index])
        proof = dict(snapshot_source_id=source, release_id='second')
        for invalid in (snapshots[:1], snapshots + snapshots[1:2], [dict(snapshots[1], source_id='other')],
                        [dict(snapshots[1], validated=False)]):
            with self.assertRaises(AssertionError):
                core.publication_snapshot(invalid, proof)

    def test_missing_identity_and_duplicate_declaration_are_rejected(self):
        snapshots = deepcopy(self.report['snapshots'])
        del snapshots[-1]['version']
        self.rejects(snapshots)
        with self.assertRaises(AssertionError):
            verify_matrix_coverage(self.report, self.matrix + self.matrix[:1])


if __name__ == '__main__':
    unittest.main()
