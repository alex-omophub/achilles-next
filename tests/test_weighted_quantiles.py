"""Independent hand answers check the parity oracle, not a copy of SQL logic."""
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools/benchmark'))
from weighted_quantiles import sorted_oracle, compressed_oracle, exact_sum, validate_budgets


class QuantileOracleTests(unittest.TestCase):
    def test_small_n_and_duplicate_weights_have_discrete_ranks(self):
        r = sorted_oracle(['-5', '1', '1'])
        self.assertEqual({k: r[k] for k in ('n', 'sum', 'p10', 'p25', 'p50', 'p75', 'p90')},
                         dict(n='3', sum='-3', p10='-5', p25='-5', p50='1', p75='1', p90='1'))
        self.assertEqual(sorted_oracle(['1', '9'])['p50'], '1')

    def test_decimal_sum_does_not_use_float_or_finite_precision_context(self):
        large = '900719925474099312345678901234567890.125'
        self.assertEqual(exact_sum([(large, 1), ('-' + large, 1), ('0.000000000000000000000000001', 1)]),
                         '0.000000000000000000000000001')
        self.assertEqual(sorted_oracle(['-0.0', '1.00', '1'])['sum'], '2')

    def test_empty_observed_group_is_distinct_from_no_group(self):
        self.assertIsNone(sorted_oracle([]))
        r = sorted_oracle([None, 'NaN', 'Infinity', '-Infinity'])
        self.assertEqual(r['n'], '0')
        self.assertTrue(all(v is None for k, v in r.items() if k != 'n'))

    def test_unreviewed_or_nonfinite_budgets_cannot_promote_a_strategy(self):
        validate_budgets({})
        for value in [float('nan'), float('inf'), True, -1]:
            with self.assertRaises(ValueError):
                validate_budgets({'numeric_compute_materialize_ms': {'example': value}})
        with self.assertRaises(ValueError):
            validate_budgets({'validated_slice_regression': {'multiplier': 0.5, 'allowance_ms': 20}})

    def test_huge_weights_cross_exact_rank_without_expansion(self):
        r = compressed_oracle([['-5', '9007199254740993'], ['1.125', '1']])
        self.assertEqual(r['n'], '9007199254740994')
        self.assertEqual(r['p90'], '-5')
        self.assertEqual(r['max'], '1.125')
        self.assertEqual(r['sum'], '-45035996273704963.875')


if __name__ == '__main__':
    unittest.main()
