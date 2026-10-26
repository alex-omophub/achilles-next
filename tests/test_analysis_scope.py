"""Bounds and semantic completeness checks for the specified alpha profile."""

import copy
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("analysis_scope", ROOT / "tools/check_analysis_scope.py")
scope = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scope)


class AnalysisScopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.profile, cls.cases = scope.check()
        cls.request = scope.load_json(ROOT / "tests/fixtures/analysis/valid-request.json")

    def test_supplied_fixture_requests_are_in_scope(self):
        for case in self.cases:
            with self.subTest(case=case["id"]):
                scope.validate_request(case["request"], self.profile)

    def test_rejects_arbitrary_joint_filters(self):
        request = copy.deepcopy(self.request)
        request["cohort_filter"] = {"age": ">65", "drug": "any"}
        with self.assertRaisesRegex(ValueError, "exactly the declared keys"):
            scope.validate_request(request, self.profile)

    def test_rejects_unsafe_or_implicit_concept_ids(self):
        for values in ([True], [1.0], ["1"], [-1], [2147483648], [], [1, 1], list(range(11))):
            with self.subTest(values=values):
                request = copy.deepcopy(self.request)
                request["measurement_concept_ids"] = values
                with self.assertRaises(ValueError):
                    scope.validate_request(request, self.profile)

    def test_explicit_zero_concept_is_allowed(self):
        request = copy.deepcopy(self.request)
        request["measurement_concept_ids"] = [0]
        scope.validate_request(request, self.profile)

    def test_partial_edge_months_count_toward_the_bound(self):
        request = copy.deepcopy(self.request)
        request["window"] = {"start": "2020-01-31", "end": "2029-12-01"}
        scope.validate_request(request, self.profile)
        request["window"]["start"] = "2019-12-31"
        with self.assertRaisesRegex(ValueError, "120 touched"):
            scope.validate_request(request, self.profile)

    def test_rejects_invalid_or_ambiguous_calendar_dates(self):
        for start, end in [("2021-02-29", "2021-03-01"), ("2020-02-01", "2020-01-31"),
                           ("20200101", "2020-12-31"), ("2020-01-01T00:00:00Z", "2020-12-31")]:
            with self.subTest(start=start):
                request = copy.deepcopy(self.request)
                request["window"] = {"start": start, "end": end}
                with self.assertRaises(ValueError):
                    scope.validate_request(request, self.profile)

    def test_synthetic_policy_does_not_authorize_a_live_source(self):
        request = copy.deepcopy(self.request)
        request["source_id"] = "institution:live-source"
        with self.assertRaisesRegex(ValueError, "Synthetic policy"):
            scope.validate_request(request, self.profile)
        request["disclosure_policy_id"] = "institution-policy:revision-1"
        scope.validate_request(request, self.profile)  # Syntax only; execution authorization is separate.

    def test_unrestricted_export_is_out_of_scope(self):
        request = copy.deepcopy(self.request)
        request["output_scope"] = "public"
        with self.assertRaisesRegex(ValueError, "restricted"):
            scope.validate_request(request, self.profile)

    def test_missing_denominator_definition_is_rejected(self):
        profile = copy.deepcopy(self.profile)
        del next(metric for metric in profile["metrics"] if metric["id"] == "measurement.person_count")["denominator"]
        with self.assertRaisesRegex(ValueError, "Incomplete semantic"):
            scope.validate_profile(profile)

    def test_dependency_cycles_are_rejected(self):
        profile = copy.deepcopy(self.profile)
        profile["metrics"][0]["dependencies"] = [profile["metrics"][0]["id"]]
        with self.assertRaisesRegex(ValueError, "Cyclic"):
            scope.validate_profile(profile)


if __name__ == "__main__":
    unittest.main()
