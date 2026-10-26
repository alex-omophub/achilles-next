"""Offline checks for the independent benchmark oracle and evidence parser."""
import json
from decimal import Decimal
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools/benchmark'))
import reference_baseline as baseline


class ReferenceBaselineTests(unittest.TestCase):
    def test_overlap_multiplies_legacy_records_but_not_alpha_membership(self):
        data = {'people': [1], 'periods': [[1, '2020-01-01', '2020-01-31'],
                                         [1, '2020-01-15', '2020-02-01']],
                'measurements': [[1, 101, 201, 0, '1.125', '2020-01-20'],
                                 [1, 101, 201, 301, '9.125', '2020-01-10']]}
        result = baseline.oracle(data)
        self.assertEqual(result['records'], {'101': '3'})
        self.assertEqual(result['alpha_membership_records'], {'101': '2'})
        self.assertEqual(result['tested_people'], {'101': '1'})
        self.assertEqual(result['numeric'][0], {'concept': '101', 'unit': '201', 'n': '3',
                         'min': '1.125', 'max': '9.125', 'p10': '1.125', 'p25': '1.125',
                         'p50': '1.125', 'p75': '9.125', 'p90': '9.125'})

    def test_orphan_people_and_null_units_retain_legacy_scope(self):
        data = {'people': [], 'periods': [[1, '2020-01-01', '2020-12-31']],
                'measurements': [[1, 101, None, None, '1', '2020-01-15']]}
        actual = baseline.oracle(data)
        self.assertEqual(actual['person_count'], '0')
        self.assertEqual(actual['records'], {'101': '1'})
        self.assertEqual(actual['alpha_membership_records'], {})
        self.assertEqual(actual['numeric'], [])

    def test_numeric_text_is_normalized_without_decimal_context_rounding(self):
        exact = '900719925474099312345678901234567890.12500'
        self.assertEqual(baseline.normalize(exact), exact[:-2])
        self.assertEqual(baseline.normalize('-0.00'), '0')

    def test_timing_parser_separates_generation_and_export(self):
        text = '\n'.join(['@@input', '{}', '@@generation', 'Time: 1.25 ms', 'Time: 2.75 ms',
                          '@@result', '{}', '@@export', '[]', 'Time: 0.5 ms'])
        values, times = baseline.parse_output(text)
        self.assertEqual(sum(times['generation']), 4.0)
        self.assertEqual(times['export'], [0.5])
        self.assertEqual(values['export'], [])
        with self.assertRaises(ValueError):
            baseline.parse_output(text.replace('Time: 0.5 ms', ''))

    def test_config_refuses_nonfixture_sources_and_unbounded_scales(self):
        config = json.loads(baseline.CONFIG.read_text())
        baseline.check_config(config)
        config['fixtures'].append('clinical_production')
        with self.assertRaises(ValueError):
            baseline.check_config(config)
        config = json.loads(baseline.CONFIG.read_text())
        config['scales'][0]['records'] = True
        with self.assertRaises(ValueError):
            baseline.check_config(config)

    def test_export_bytes_and_decimal_values_survive_without_float_conversion(self):
        payload = '[{"max_value": 9007199254740993.125}]'
        text = '\n'.join(['@@input', '{}', '@@generation', 'Time: 1 ms',
                          '@@result', '{}', '@@export', payload, 'Time: 1 ms'])
        values, _ = baseline.parse_output(text)
        self.assertEqual(values['_export_bytes'], payload.encode())
        self.assertEqual(values['export'][0]['max_value'], Decimal('9007199254740993.125'))

    def test_export_quantile_rounding_is_rejected(self):
        row = {'concept_id': 101, 'unit_concept_id': '201',
               **{key: Decimal('9007199254740993.125') for key in ['min_value','max_value','p10_value','p25_value','median_value','p75_value','p90_value']}}
        expected = {'numeric': [{'concept':'101','unit':'201',
                     **{key:'9007199254740993.125' for key in ['min','max','p10','p25','p50','p75','p90']}}]}
        baseline.check_export([row],expected)
        row['p75_value'] = 9007199254740994.0
        with self.assertRaises(ValueError):
            baseline.check_export([row],expected)
        del row['unit_concept_id']
        row['category'] = 'ambiguous unit label'
        with self.assertRaisesRegex(ValueError, 'unambiguous'):
            baseline.check_export([row],expected,{})

    def test_mismatch_cannot_be_accepted_as_timing_truth(self):
        empty = baseline.oracle({'people': [], 'periods': [], 'measurements': []})
        with self.assertRaises(ValueError):
            baseline.check_result({'person_count': '1'}, empty)


if __name__ == '__main__':
    unittest.main()
