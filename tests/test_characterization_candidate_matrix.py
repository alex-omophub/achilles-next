"""Declared bridge coverage must not shrink to the snapshots a runner returned."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from test_characterization_candidate_sql import verify_matrix_coverage


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

    def test_missing_identity_and_duplicate_declaration_are_rejected(self):
        snapshots = deepcopy(self.report['snapshots'])
        del snapshots[-1]['version']
        self.rejects(snapshots)
        with self.assertRaises(AssertionError):
            verify_matrix_coverage(self.report, self.matrix + self.matrix[:1])


if __name__ == '__main__':
    unittest.main()
