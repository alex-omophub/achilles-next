"""Independent small-data counts, replay tampering and bounded failure cases."""
from collections import Counter
from contextlib import closing
import csv
from decimal import Decimal
import hashlib
import io
import json
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
_saved=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    import source_inventory as I
finally: sys.path[:]=_saved


@unittest.skipUnless(I.M.fcntl is not None,'POSIX source locks')
class InventoryTest(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.home=Path(temp.name); self.source=self.home/'source'; self.output=self.home/'inventory'

    def prepare(self, version='5.5', windows=None, rows=120):
        windows=windows or [dict(table='measurement',start=0,rows=rows)]
        I.M.prepare(self.source,'S2',version,windows,chunk_rows=7)
        self.assertEqual(I.M.run(self.source)['status'],'complete')

    def hashes(self, root):
        return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.iterdir() if p.is_file()}

    def rewrite(self, record):
        db=self.output/'inventory.sqlite'
        record['database']=dict(bytes=db.stat().st_size,sha256=hashlib.sha256(db.read_bytes()).hexdigest())
        I.M.atomic_json(self.output,'inventory.json',record)

    def test_independent_csv_oracle_and_source_isolation_all_versions(self):
        # Separate CSV decoder/counting implementation; no collector row-key helpers.
        for version in ['5.3','5.4','5.5']:
            with self.subTest(version=version):
                self.source=self.home/('source-'+version); self.output=self.home/('out-'+version)
                self.prepare(version,windows=[dict(table='measurement',start=95,rows=12),
                    dict(table='measurement',start=1000,rows=10),dict(table='observation',start=95,rows=12),
                    dict(table='cdm_source',start=0,rows=1)])
                before=self.hashes(self.source); result=I.collect(self.source,self.output)
                complete=I.M.read_json(self.source/'complete.json'); bags=Counter(); bins=Counter()
                encoded={}; rows={}; nulls={}
                for chunk in complete['chunks']:
                    table=chunk['table']; raw=(self.source/chunk['file']).read_bytes()
                    decoded=list(csv.DictReader(io.StringIO(raw.decode())))
                    physical=raw.splitlines(keepends=True)[1:]
                    columns=result['tables'][table]['histogram_columns']
                    for row,line in zip(decoded,physical):
                        row={k:None if v=='\\N' else v for k,v in row.items()}
                        rows[table]=rows.get(table,0)+1; encoded.setdefault(table,[]).append(len(line))
                        counts=nulls.setdefault(table,{k:0 for k in row})
                        for k,v in row.items(): counts[k]+=v is None
                        bags[table,line]+=1
                        bins[table,'encoded_row_bytes',json.dumps(len(line))]+=1
                        def value(name):
                            if name not in row: return {'kind':'not_in_schema'}
                            return {'kind':'null'} if row[name] is None else {'kind':'value','value':row[name]}
                        def key(v): return json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=False)
                        for column in columns: bins[table,'column:'+column,key(value(column))]+=1
                        if table in ('measurement','observation'):
                            number=row['value_as_number']; state='missing' if number is None else 'finite' if Decimal(number).is_finite() else 'non_finite'
                            person=row['person_id']; joint={'concept':value(table+'_concept_id'),'unit':value('unit_concept_id'),
                                'operator':value('operator_concept_id'),'numeric_state':state,
                                'person_bucket':'missing_person' if person is None else 'hot_person' if int(person)<=200000 else 'other_person'}
                            bins[table,'joint:representation',key(joint)]+=1
                with closing(sqlite3.connect(self.output/'inventory.sqlite')) as db,db:
                    actual_bags={(t,bytes(v)):n for t,v,n in db.execute('SELECT * FROM row_bag')}
                    actual_bins={(t,d,v):n for t,d,v,n in db.execute('SELECT * FROM bins')}
                self.assertEqual(dict(bags),actual_bags); self.assertEqual(dict(bins),actual_bins)
                for table,n in rows.items():
                    info=result['tables'][table]
                    self.assertEqual(info['selected_rows'],n); self.assertEqual(info['null_counts'],nulls[table])
                    self.assertEqual(info['row_bytes_min'],min(encoded[table])); self.assertEqual(info['row_bytes_max'],max(encoded[table]))
                    self.assertEqual(info['duplicate_rows'],n-sum(t==table for t,_ in bags))
                self.assertEqual(result['tables']['cdm_source']['coverage'],'full_table')
                self.assertGreater(result['tables']['measurement']['duplicate_rows'],0)
                self.assertIsNone(result['tables']['person']['duplicate_rows'])
                self.assertEqual(result['tables']['person']['coverage'],'not_selected')
                self.assertFalse(result['qualifying']); self.assertFalse(result['full_tier_generated'])
                self.assertEqual(I.verify(self.source,self.output),result)
                self.assertEqual(self.hashes(self.source),before)

    def test_null_empty_zero_and_spaces_have_distinct_tags(self):
        self.assertEqual(len({json.dumps(I.tag({'v':v},'v'),sort_keys=True) for v in [None,'','0',' ']}),4)
        self.assertNotEqual(I.tag({},'v'),I.tag({'v':None},'v'))
        self.assertEqual([I.numeric_state(v) for v in [None,'0','NaN','Infinity','bad']],
                         ['missing','finite','non_finite','non_finite','invalid'])

    def test_buffer_spills_and_conserves_counts(self):
        counts=Counter(); buffer=I.Buffer(lambda key,n:counts.update({key:n}))
        for index in range(10000): buffer.add(('row','t','',str(index%5000).encode()))
        buffer.flush()
        self.assertEqual(len(counts),5000); self.assertEqual(set(counts.values()),{2})
        self.assertLessEqual(buffer.peak_keys,I.BUFFER_KEYS); self.assertLessEqual(buffer.peak_key_bytes,I.BUFFER_BYTES)
        self.assertGreater(buffer.flushes,1)

    def test_buffer_byte_limit_and_empty_selection_are_explicit(self):
        counts=Counter(); buffer=I.Buffer(lambda key,n:counts.update({key:n}))
        for index in range(100): buffer.add(('row','t','',str(index).encode()+b'x'*40000))
        buffer.flush()
        self.assertEqual(len(counts),100); self.assertLessEqual(buffer.peak_key_bytes,I.BUFFER_BYTES)
        self.assertGreater(buffer.flushes,1)
        self.prepare(windows=[dict(table='note',start=0,rows=0)])
        record=I.collect(self.source,self.output); info=record['tables']['note']
        self.assertEqual(info['coverage'],'full_table'); self.assertEqual(info['selected_rows'],0)
        self.assertEqual(info['distinct_rows'],0); self.assertEqual(info['duplicate_rows'],0)
        self.assertEqual(info['histograms'],{}); self.assertIsNone(info['row_bytes_max'])
        self.assertIsNone(record['tables']['measurement']['histograms'])
        I.verify(self.source,self.output)

    def test_limit_validation(self):
        for options in [dict(bins=True),dict(bins=0),dict(database_bytes=I.MAX_DB+1),
                        dict(seconds=float('nan')),dict(seconds=121),dict(min_free=1)]:
            with self.subTest(options=options),self.assertRaises(ValueError): I.limits(**options)
        self.assertEqual(I.limits(database_bytes=65537)['database_bytes'],65536)

    def test_sql_progress_preserves_signal_exit_code(self):
        guard=I.Guard([self.home],I.limits(),lambda:'SIGTERM')
        with closing(sqlite3.connect(':memory:')) as db:
            db.set_progress_handler(guard.progress,1)
            with self.assertRaises(I.M.Stopped) as stopped,I.guarded_sql(guard): db.execute('SELECT 1')
            self.assertEqual(stopped.exception.code,143)

    def test_incomplete_and_corrupt_source_leave_no_output(self):
        I.M.prepare(self.source,'S2','5.5',[dict(table='measurement',start=0,rows=20)],chunk_rows=7)
        I.M.run(self.source,max_chunks=1)
        with self.assertRaises((ValueError,OSError)): I.collect(self.source,self.output)
        self.assertFalse(self.output.exists()); I.M.run(self.source)
        (self.source/'chunk-000000.csv').write_bytes(b'bad')
        with self.assertRaises(ValueError): I.collect(self.source,self.output)
        self.assertFalse(self.output.exists())

    def test_source_lock_prevents_inventory(self):
        self.prepare()
        with I.M.locked(self.source),self.assertRaises(BlockingIOError): I.collect(self.source,self.output)
        self.assertFalse(self.output.exists())

    def test_existing_output_and_aliases_never_overwritten(self):
        self.prepare(); I.collect(self.source,self.output); before=self.hashes(self.output)
        with self.assertRaises(FileExistsError): I.collect(self.source,self.output)
        self.assertEqual(before,self.hashes(self.output))
        for path in [self.source/'nested',self.home,self.home/'alias']:
            if path.name=='alias': path.symlink_to(self.home/'absent')
            with self.assertRaises(ValueError): I.collect(self.source,path)
        self.assertFalse((self.home/'absent').exists())
        alias=self.home/'parent'; alias.symlink_to(self.home,target_is_directory=True)
        I.collect(self.source,alias/'new'); I.verify(self.source,alias/'new')

    def test_bin_and_database_caps_keep_failed_evidence_without_completion(self):
        self.prepare(rows=300)
        for name,controls in [('bins',dict(bins=1)),('pages',dict(database_bytes=65536))]:
            output=self.home/name
            with self.subTest(name=name),self.assertRaises((ValueError,sqlite3.Error)): I.collect(self.source,output,**controls)
            self.assertTrue((output/'failed.json').exists()); self.assertFalse((output/'inventory.json').exists())
            self.assertLessEqual((output/'inventory.sqlite').stat().st_size,controls.get('database_bytes',I.MAX_DB))
            with self.assertRaises(ValueError): I.verify(self.source,output)

    def test_low_disk_deadline_and_cancellation(self):
        self.prepare(); space=shutil.disk_usage(self.home)
        with patch.object(I.shutil,'disk_usage',return_value=space._replace(free=1)),self.assertRaisesRegex(ValueError,'free-space'):
            I.collect(self.source,self.output)
        self.assertFalse(self.output.exists())
        guard=I.Guard([self.home],I.limits())
        with patch.object(I.time,'monotonic',return_value=guard.began+121),self.assertRaises(I.M.Stopped): guard.check()
        for name,code in [('SIGINT',130),('SIGTERM',143)]:
            output=self.home/name; original=I.Sink.apply; calls=[0]
            def apply(sink,key,n):
                calls[0]+=1
                return original(sink,key,n)
            with patch.object(I.Sink,'apply',apply),self.assertRaises(I.M.Stopped) as failure:
                I.collect(self.source,output,stop=lambda:name if calls[0]>0 else None)
            self.assertEqual(failure.exception.code,code)
            self.assertTrue((output/'failed.json').exists()); self.assertFalse((output/'inventory.json').exists())

    def test_rehashed_bin_or_row_tampering_rejected(self):
        self.prepare(); base=I.collect(self.source,self.output)
        for table in ['bins','row_bag']:
            with self.subTest(table=table):
                with closing(sqlite3.connect(self.output/'inventory.sqlite')) as db,db:
                    db.execute('UPDATE '+table+' SET n=n+1')
                self.rewrite(base)
                with self.assertRaisesRegex(ValueError,'bins not explained'): I.verify(self.source,self.output)
                with closing(sqlite3.connect(self.output/'inventory.sqlite')) as db,db:
                    db.execute('UPDATE '+table+' SET n=n-1')
                self.rewrite(base)
        I.verify(self.source,self.output)

    def test_missing_bin_rejected_even_with_rehashed_database(self):
        self.prepare(); result=I.collect(self.source,self.output)
        with closing(sqlite3.connect(self.output/'inventory.sqlite')) as db,db:
            db.execute('DELETE FROM bins WHERE dimension=?',('encoded_row_bytes',))
        self.rewrite(result)
        with self.assertRaisesRegex(ValueError,'differs from replayed'): I.verify(self.source,self.output)

    def test_summary_types_and_unexpected_files_rejected(self):
        self.prepare(); result=I.collect(self.source,self.output)
        result['qualifying']=0; self.rewrite(result)
        with self.assertRaisesRegex(ValueError,'summary differs'): I.verify(self.source,self.output)
        result['qualifying']=False; self.rewrite(result)
        (self.output/'extra').write_text('x')
        with self.assertRaisesRegex(ValueError,'unexpected'): I.verify(self.source,self.output)

    def test_code_binding_and_database_schema_are_verified(self):
        self.prepare(); record=I.collect(self.source,self.output)
        with patch.object(I,'SOURCE_SHA','0'*64),self.assertRaisesRegex(ValueError,'code changed'):
            I.verify(self.source,self.output)
        with closing(sqlite3.connect(self.output/'inventory.sqlite')) as db,db: db.execute('CREATE TABLE extra (n INTEGER)')
        self.rewrite(record)
        with self.assertRaisesRegex(ValueError,'schema differs'): I.verify(self.source,self.output)

    def test_late_source_change_and_receipt_failure_never_publish_success(self):
        self.prepare(); original=I.Sink.apply; changed=[False]
        def change(sink,key,n):
            if not changed[0]:
                changed[0]=True
                complete=I.M.read_json(self.source/'complete.json'); complete['qualifying']=True
                I.M.atomic_json(self.source,'complete.json',complete)
            return original(sink,key,n)
        with patch.object(I.Sink,'apply',change),self.assertRaisesRegex(ValueError,'identity changed'):
            I.collect(self.source,self.output)
        self.assertFalse((self.output/'inventory.json').exists()); self.assertTrue((self.output/'failed.json').exists())
        complete=I.M.read_json(self.source/'complete.json'); complete['qualifying']=False
        I.M.atomic_json(self.source,'complete.json',complete)
        atomic=I.M.atomic_json
        def fail(root,name,value,exclusive=False):
            if name=='inventory.json': raise OSError('receipt write failed')
            return atomic(root,name,value,exclusive)
        output=self.home/'receipt-failure'
        with patch.object(I.M,'atomic_json',fail),self.assertRaisesRegex(OSError,'receipt write failed'):
            I.collect(self.source,output)
        self.assertFalse((output/'inventory.json').exists()); self.assertTrue((output/'failed.json').exists())


if __name__=='__main__': unittest.main()
