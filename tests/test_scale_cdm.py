"""Independent indexed-source facts and bounded-work/failure controls."""
import csv
from datetime import date
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
_path = sys.path[:]
try:
    sys.path.insert(0, str(ROOT/'tools'))
    import scale_cdm as SCALE
finally: sys.path[:] = _path


def draw(seed, domain, row, slot, size):
    # Independent implementation of the declared integer stream, with no calls
    # to the generator's mixer/event-row helper.
    value = (seed ^ ((domain+1)*0x9e3779b97f4a7c15) ^ (row*0xd1b54a32d192ed03) ^ slot) % 2**64
    value = ((value ^ (value >> 30))*0xbf58476d1ce4e5b9) % 2**64
    value = ((value ^ (value >> 27))*0x94d049bb133111eb) % 2**64
    return (value ^ (value >> 31)) % size


class IndexedScaleTest(unittest.TestCase):
    def test_exact_tier_counts_include_auxiliary_vocabulary_work(self):
        source = SCALE.Source(); plan = source.plan()
        self.assertEqual(plan['rows_per_domain'], dict(condition=12000000, drug=18000000, procedure=8000000,
            visit=6000000, device=2000000, observation=10000000, death=100000, specimen=1900000, measurement=42000000))
        self.assertEqual(plan['table_rows']['person'], 1000000)
        self.assertEqual(plan['table_rows']['observation_period'], 1200000)
        self.assertEqual(plan['table_rows']['concept'], 14850017)
        self.assertEqual(plan['auxiliary_rows'], 17050021)
        s1 = SCALE.Source('S1').plan()
        self.assertEqual(sum(s1['rows_per_domain'].values()), 5000000)
        self.assertEqual(s1['table_rows']['concept'], 1485017)
        self.assertFalse(plan['execution_enabled']); self.assertFalse(plan['full_tier_generated'])
        self.assertFalse(plan['qualifying'])

    def test_high_offsets_are_direct_indexed_and_follow_independent_stream(self):
        source = SCALE.Source(); d = 8; n = 41999994
        row = source.row('measurement', n)
        hot = 10000
        c = draw(2026103102, d, n, 2, hot) if n%100 < 80 else hot+draw(2026103102, d, n, 2, 40000)
        self.assertEqual(row['measurement_concept_id'], 1800000+c if n%97 else 0)
        self.assertEqual(row['measurement_source_concept_id'], 100000000+(400000+c)*32+draw(2026103102, d, n, 6, 32))
        self.assertEqual(row['measurement_id'], n+1)
        self.assertTrue(date(2010,1,1) <= date.fromisoformat(row['measurement_date']) <= date(2024,12,31))
        self.assertEqual(source.row('person', 999999)['person_id'], 1000000)

    def test_no_concept_collisions_and_full_source_fanout_ranges(self):
        source = SCALE.Source()
        ids = set()
        for d in range(9):
            for c in [0, 9999, 10000, 49999]:
                values = [source.standard(d,c)]+[source.source_concept(d,c,s) for s in range(32)]
                self.assertEqual(len(set(values)),33); self.assertTrue(all(0 < i < 2**31 for i in values))
                self.assertFalse(ids.intersection(values)); ids.update(values)
        for index in [0, 1, 50000, 450000, 450001, 450016, 450017, 14850016]:
            row = source.row('concept', index)
            self.assertNotIn(row['concept_id'], source.units if row['domain_id'] != 'Unit' else [])
        self.assertEqual(source.row('concept', 14850016)['concept_id'], 114399999)
        self.assertEqual(source.row('concept', 450001)['concept_id'], 9000001)

    def test_duplicate_bags_and_skew_schedule_survive_window_boundaries(self):
        source = SCALE.Source()
        self.assertEqual(source.row('measurement',98), source.row('measurement',99))
        self.assertEqual(source.row('measurement',41999998), source.row('measurement',41999999))
        for n in range(100, 200):
            row = source.row('measurement',n)
            base = n-1 if n%100 == 99 else n
            if base%97:
                c = row['measurement_concept_id']-1800000
                self.assertEqual(c < 10000, base%100 < 80)
            self.assertTrue(1 <= int(row['person_id']) <= 1000000)
            if base%5 != 4: self.assertLessEqual(int(row['person_id']), 200000)

    def test_period_union_shape_is_indexed_including_last_person_block(self):
        source = SCALE.Source()
        first = [source.row('observation_period', i) for i in range(12)]
        self.assertEqual([r['person_id'] for r in first],[1,1,2,2,3,3,4,5,6,7,8,9])
        self.assertGreater(first[5]['observation_period_start_date'],first[5]['observation_period_end_date'])
        self.assertEqual(source.row('observation_period',1199999)['person_id'],999999)
        self.assertEqual(source.row('observation_period',1199999)['observation_period_id'],1200000)

    def test_all_version_columns_encode_first_last_rows_without_required_nulls(self):
        for version, count in [('5.3',37),('5.4',39),('5.5',42)]:
            source = SCALE.Source(version=version)
            self.assertEqual(len(source.columns),count)
            for table, rows in source.counts.items():
                if not rows: continue
                for index in [0,rows-1]:
                    row = source.row(table,index)
                    raw = SCALE.BASE.encode_row(row,source.columns[table])
                    values = next(csv.reader(io.StringIO(raw.decode())))
                    self.assertEqual(len(values),len(source.columns[table]))
                    for col, value in zip(source.columns[table],values):
                        if col['required']: self.assertNotEqual(value,'\\N')

    def test_probe_reads_only_requested_tail_rows_and_replays_byte_identically(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); original = SCALE.Source.row
            with patch.object(SCALE.Source,'row',autospec=True,side_effect=original) as call:
                a = SCALE.probe(root/'a','S2','5.5','measurement',41999990,10)
                self.assertEqual(call.call_count,10)
                self.assertEqual([x.args[2] for x in call.call_args_list],list(range(41999990,42000000)))
            self.assertEqual(SCALE.verify(root/'a'),a)
            b = SCALE.probe(root/'b','S2','5.5','measurement',41999990,10)
            self.assertEqual(a,b)
            self.assertEqual((root/'a/measurement.csv').read_bytes(),(root/'b/measurement.csv').read_bytes())

    def test_windows_partition_without_skips_and_empty_tables_have_header_only(self):
        source = SCALE.Source()
        a,b,whole = io.BytesIO(),io.BytesIO(),io.BytesIO()
        for start,rows,out in [(95,5,a),(100,5,b),(95,10,whole)]: SCALE.render(source,'measurement',start,rows,out)
        self.assertEqual(whole.getvalue(),a.getvalue()+b.getvalue().split(b'\n',1)[1])
        result = SCALE.render(source,'note',0,0)
        self.assertEqual(result['rows'],0); self.assertIsNone(result['row_bytes_min'])
        self.assertEqual(SCALE.render(source,'measurement',0,1,io.BytesIO())['rows'],1)

    def test_invalid_windows_and_large_requests_refuse_before_output(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'out'
            for table,start,rows in [('measurement',0,10001),('measurement',41999999,2),('measurement',-1,1),
                                     ('measurement',False,1),('person',1000000,1),('unknown',0,1),('note',0,1)]:
                with self.subTest(table=table,start=start,rows=rows),self.assertRaises(ValueError):
                    SCALE.probe(path,'S2','5.5',table,start,rows)
                self.assertFalse(path.exists())

    def test_budget_or_interrupt_preserves_failed_partial_never_complete(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name, patcher in [('bytes',patch.object(SCALE,'MAX_BYTES',1)),
                                  ('time',patch.object(SCALE.time,'monotonic',side_effect=[0,31])),
                                  ('interrupt',patch.object(SCALE.Source,'row',side_effect=KeyboardInterrupt))]:
                with self.subTest(name=name),patcher,self.assertRaises((ValueError,KeyboardInterrupt)):
                    SCALE.probe(root/name,'S2','5.5','measurement',0,1)
                self.assertTrue((root/name/'failed.json').exists()); self.assertFalse((root/name/'probe.json').exists())
            with patch.object(SCALE.shutil,'disk_usage',return_value=type('Usage',(),{'free':0})()),self.assertRaises(ValueError):
                SCALE.probe(root/'disk','S2','5.5','measurement',0,1)
            self.assertFalse((root/'disk').exists())

    def test_recipe_source_drift_existing_outputs_and_csv_tampering_refuse(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); path = root/'out'
            result = SCALE.probe(path,'S2','5.5','measurement',1,1)
            raw = (path/'measurement.csv').read_bytes()
            with self.assertRaises(FileExistsError): SCALE.probe(path,'S2','5.5','measurement',1,1)
            (path/'measurement.csv').write_bytes(raw.replace(b'2.5',b'3.5'))
            with self.assertRaises(ValueError): SCALE.verify(path)
            (path/'measurement.csv').write_bytes(raw)
            changed = dict(result,rows=2); (path/'probe.json').write_bytes(SCALE.BASE.canonical(changed))
            with self.assertRaises(ValueError): SCALE.verify(path)
            (path/'probe.json').write_bytes(SCALE.BASE.canonical(result)); (path/'extra').touch()
            with self.assertRaises(ValueError): SCALE.verify(path)
            with patch.object(SCALE,'SOURCE_SHA','0'*64),self.assertRaises(ValueError): SCALE.Source()

    def test_preview_caps_are_unchanged_and_no_full_build_cli_exists(self):
        with self.assertRaises(ValueError): SCALE.BASE.plan(1000000,100000000)
        result = subprocess.run([sys.executable,str(ROOT/'tools/scale_cdm.py'),'build'],capture_output=True,text=True)
        self.assertEqual(result.returncode,2)
        self.assertNotIn('Traceback',result.stderr)

    def test_receipt_budget_and_growing_csv_are_detected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'probe'; SCALE.probe(path,'S2','5.5','measurement',1,2)
            receipt = (path/'probe.json').read_bytes(); data = path/'measurement.csv'; raw = data.read_bytes()
            (path/'probe.json').write_bytes(b' '*262145)
            with self.assertRaises(ValueError): SCALE.verify(path)
            (path/'probe.json').write_bytes(receipt)
            original = Path.open
            def growing(target,*args,**kwargs):
                if target == data: return io.BytesIO(raw+b'extra')
                return original(target,*args,**kwargs)
            with patch.object(Path,'open',growing),self.assertRaisesRegex(ValueError,'grew'): SCALE.verify(path)

    def test_recipe_mutations_and_output_inside_checkout_are_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); recipe = json.loads(SCALE.RECIPE.read_bytes())
            for name, value in [('people',1000001),('seed',True),('events',-1)]:
                changed = json.loads(json.dumps(recipe)); changed['tiers']['S2'][name] = value
                target = root/'recipe.json'; target.write_text(json.dumps(changed))
                with patch.object(SCALE,'RECIPE',target),self.assertRaises(ValueError): SCALE.Source()
            with self.assertRaises(ValueError): SCALE.probe(ROOT/'.local/forbidden-probe','S2','5.5','person',0,1)


if __name__ == '__main__': unittest.main()
