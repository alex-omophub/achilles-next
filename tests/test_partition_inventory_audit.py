"""Independent regeneration, corruption refusal and real SQLite audit restart."""
from contextlib import closing,contextmanager
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
saved=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    import partition_inventory_audit as V
finally:sys.path[:]=saved
A=V.A


@unittest.skipUnless(A.M.fcntl is not None,'POSIX inventory/audit locks')
class AuditTest(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);self.home=Path(temporary.name)
        self.source,self.plan=self.build(self.home,'5.5');self.out=self.home/'audit'

    def build(self,root,version,all_partitions=False,size=1):
        reg=root/'registration';schedule=root/'schedule';out=root/'reducer'
        A.R.register(reg,'audit-test','S2',version,{r:str(root) for r in A.R.ROLES})
        plan=A.P.create(reg,schedule,rows_per_partition=size,chunk_rows=min(size,10000));A.prepare(schedule,out)
        first=next(t['first_partition'] for t in plan['tables'] if t['table']=='measurement')
        indices=range(plan['partition_count']) if all_partitions else [first+98,first+99]
        for index in indices:
            stage=root/('stage-'+str(index));stage.mkdir();source=stage/'source';inventory=stage/'inventory'
            expected=A.P.materialization_plan(plan,index);A.M.prepare(source,'S2',version,expected['windows'],chunk_rows=plan['controls']['chunk_rows'])
            A.M.run(source);A.I.collect(source,inventory);A.append(out,index,source,inventory);shutil.rmtree(stage)
        return out,plan

    def prepare(self,**kwargs):return V.prepare(self.source,self.out,**kwargs)

    def complete(self,**kwargs):
        for _ in range(1000):
            result=V.run(self.out,**kwargs)
            if result['status']=='complete':return result['receipt']
        self.fail('audit did not complete')

    def checkpoint(self):
        with closing(sqlite3.connect(self.out/'audit.sqlite')) as db:
            return json.loads(db.execute('SELECT document FROM '+V.META).fetchone()[0])

    def logical(self):
        with closing(sqlite3.connect(self.out/'audit.sqlite')) as db:
            return {name:db.execute('SELECT * FROM '+name+' ORDER BY 1,2').fetchall() for name in V.SCHEMA}

    def mutate(self,sql,args=()):
        with closing(sqlite3.connect(self.source/'inventory.sqlite')) as db,db:db.execute(sql,args)

    def test_all_versions_and_archived_inputs_independent_of_collector(self):
        for version in ['5.3','5.4','5.5']:
            with self.subTest(version=version):
                root=self.home/version;root.mkdir();self.source,self.plan=self.build(root,version);self.out=root/'audit'
                before=hashlib.sha256((self.source/'inventory.sqlite').read_bytes()).hexdigest();self.prepare()
                with patch.object(A.I,'row_keys',side_effect=AssertionError('collector classifier must not run')),patch.object(A.I.Sink,'apply',side_effect=AssertionError('collector sink must not run')),patch.object(A,'merge',side_effect=AssertionError('reducer merge must not run')):
                    result=self.complete(max_steps=1,page_keys=1)
                self.assertEqual(result['rows'],2);self.assertEqual(result['row_keys'],1)
                self.assertEqual(result['partitions'],2);self.assertFalse(result['whole_source_audited']);self.assertFalse(result['qualifying'])
                self.assertEqual(V.run(self.out,verify_only=True),result)
                self.assertEqual(hashlib.sha256((self.source/'inventory.sqlite').read_bytes()).hexdigest(),before)

    def test_comparison_page_size_does_not_change_content_digests(self):
        self.prepare();first=self.complete(max_steps=1,page_keys=1)
        self.out=self.home/'other-audit';self.prepare();second=self.complete(max_steps=128,page_keys=1024)
        for name in ['row_chain','bin_chain','receipt_chain','source_file_chain']:self.assertEqual(first[name],second[name])

    def test_wrong_rows_missing_rows_and_histogram_corruption_are_rejected(self):
        original=self.source
        cases=["UPDATE row_bag SET n=n+1","DELETE FROM row_bag","UPDATE bins SET n=n+1 WHERE dimension='encoded_row_bytes'",
               "DELETE FROM bins WHERE dimension='encoded_row_bytes'","UPDATE row_bag SET row_bytes=zeroblob(65537)"]
        for number,sql in enumerate(cases):
            with self.subTest(sql=sql):
                self.source=self.home/('bad-source-'+str(number));shutil.copytree(original,self.source);self.out=self.home/('bad-audit-'+str(number))
                self.mutate(sql);self.prepare()
                with self.assertRaisesRegex(ValueError,'Global (rows|bins) inventory differs'):self.complete()
                self.assertFalse((self.out/'complete.json').exists())

    def test_extra_histogram_keys_are_not_hidden_by_matching_counts(self):
        self.mutate("INSERT INTO bins VALUES('measurement','extra','{}',1)");self.prepare()
        with self.assertRaisesRegex(ValueError,'Global bins'):self.complete()

    def test_missing_partition_is_detected_by_row_multiplicity_comparison(self):
        self.mutate('DELETE FROM '+A.PARTS+' WHERE partition_no=(SELECT max(partition_no) FROM '+A.PARTS+')');self.prepare()
        with self.assertRaisesRegex(ValueError,'^Global rows inventory differs from independently regenerated source$'):self.complete()
        state=self.checkpoint();self.assertEqual(state['phase'],'rows')
        self.assertEqual(state['expected']['partitions'],1);self.assertEqual(state['row_keys_compared'],0)
        self.assertFalse((self.out/'complete.json').exists())

    def test_schedule_outputs_are_refused_without_poisoning_the_source_plan(self):
        catalog=self.home/'catalog';catalog.mkdir();schedule=catalog/'schedule'
        plan=A.P.create(self.home/'registration',schedule,rows_per_partition=1,chunk_rows=1)
        source=self.home/'isolated-reducer';A.prepare(schedule,source)
        alias=self.home/'schedule-alias';alias.symlink_to(schedule,target_is_directory=True)
        before=(schedule/'partition-plan.json').read_bytes();source_bytes=(source/'inventory.sqlite').read_bytes()
        nested=schedule/'audit'
        for output in [catalog,schedule,nested,alias/'audit']:
            with self.subTest(output=output):
                try:
                    with self.assertRaisesRegex(ValueError,'Keep reducer separate from schedule/source/inventory'):V.prepare(source,output)
                    self.assertFalse(nested.exists())
                finally:
                    # Keeps the pre-fix reproduction isolated to this fixture.
                    if nested.exists():shutil.rmtree(nested)
                self.assertEqual((schedule/'partition-plan.json').read_bytes(),before)
                self.assertEqual(A.P.verify(schedule),plan)
                self.assertEqual((source/'inventory.sqlite').read_bytes(),source_bytes)

    def test_regenerated_completion_sha_refuses_forged_receipt(self):
        with closing(sqlite3.connect(self.source/'inventory.sqlite')) as db,db:
            index,raw=db.execute('SELECT partition_no,document FROM '+A.PARTS+' LIMIT 1').fetchone()
            value=json.loads(raw);value['source_binding']['completion_sha256']='0'*64
            db.execute('UPDATE '+A.PARTS+' SET document=? WHERE partition_no=?',(json.dumps(value),index))
        self.prepare()
        with self.assertRaisesRegex(ValueError,'Regenerated partition completion'):self.complete()

    def test_consistent_shaped_cached_null_counts_do_not_pass_audit(self):
        with closing(sqlite3.connect(self.source/'inventory.sqlite')) as db,db:
            value=json.loads(db.execute('SELECT document FROM '+A.META).fetchone()[0]);value['tables']['measurement']['null_counts']['person_id']=1
            db.execute('UPDATE '+A.META+' SET document=?',(json.dumps(value),))
        self.prepare()
        with self.assertRaisesRegex(ValueError,'^Global cached summary/journal differs from regenerated source$'):self.complete()
        self.assertEqual(self.checkpoint()['phase'],'finalize')

    def test_whole_scope_refuses_gaps_without_certifying_selected_inventory(self):
        self.prepare(require_whole_source=True)
        with self.assertRaisesRegex(ValueError,'partition gap'):V.run(self.out)
        self.assertFalse((self.out/'complete.json').exists())

    def test_whole_scope_success_uses_test_only_compact_workload(self):
        # A stand-in schedule exercises every physical table without claiming a
        # real S1/S2 run. Outside this patch its source pins/plan no longer verify.
        init=A.S.Source.__init__
        def compact(source,*args,**kwargs):
            init(source,*args,**kwargs);source.counts={t:min(n,1) for t,n in source.counts.items()}
        root=self.home/'compact';root.mkdir()
        with patch.object(A.S.Source,'__init__',compact):
            self.source,self.plan=self.build(root,'5.5',all_partitions=True);self.out=root/'audit';self.prepare(require_whole_source=True)
            receipt=self.complete(max_steps=128,page_keys=256)
            self.assertTrue(receipt['whole_source_audited']);self.assertEqual(receipt['partitions'],self.plan['partition_count'])
            self.assertEqual(receipt['rows'],self.plan['total_rows']);self.assertFalse(receipt['qualifying'])
        with self.assertRaises(ValueError):V.run(self.out,verify_only=True)

    def test_partial_sql_failure_rolls_back_current_chunk_checkpoint(self):
        self.prepare();V.run(self.out,max_steps=1);before=self.logical();add=V.Writer.add
        def fail(writer,*args):add(writer,*args);raise RuntimeError('injected oracle failure')
        with patch.object(V.Writer,'add',fail),self.assertRaisesRegex(RuntimeError,'oracle failure'):V.run(self.out,max_steps=1)
        self.assertEqual(before,self.logical());self.assertEqual(self.complete()['rows'],2)

    def test_lost_commit_response_adopts_durable_audit_cursor(self):
        self.prepare();databases=V.databases
        class Lost:
            def __init__(self,db):self.db=db
            def __getattr__(self,key):return getattr(self.db,key)
            def execute(self,sql,*args):
                result=self.db.execute(sql,*args)
                if sql=='COMMIT':raise RuntimeError('commit response lost')
                return result
        @contextmanager
        def lose(*args):
            with databases(*args) as (original,db,header):yield original,Lost(db),header
        with patch.object(V,'databases',lose),self.assertRaisesRegex(RuntimeError,'response lost'):V.run(self.out,max_steps=1)
        self.assertEqual(self.checkpoint()['expected']['rows'],1)
        self.assertEqual(self.complete()['rows'],2)

    def test_completion_receipt_write_failure_resumes_without_regenerating(self):
        self.prepare();atomic=A.M.atomic_json
        def fail(root,name,*args,**kwargs):
            if Path(root).resolve()==self.out.resolve() and name=='complete.json':raise OSError('completion write failed')
            return atomic(root,name,*args,**kwargs)
        with patch.object(A.M,'atomic_json',fail),self.assertRaisesRegex(OSError,'completion write failed'):self.complete()
        self.assertEqual(self.checkpoint()['phase'],'complete');self.assertFalse((self.out/'complete.json').exists())
        with patch.object(V.Writer,'write',side_effect=AssertionError('must reuse completed audit')):receipt=self.complete()
        self.assertEqual(V.run(self.out,verify_only=True),receipt)

    def test_interrupted_exclusive_completion_link_is_recovered(self):
        self.prepare();receipt=self.complete();content=(self.out/'complete.json').read_bytes()
        os.link(self.out/'complete.json',self.out/'complete.json.next')
        self.assertEqual((self.out/'complete.json').stat().st_nlink,2)
        self.assertEqual(V.run(self.out,verify_only=True),receipt)
        self.assertFalse((self.out/'complete.json.next').exists())
        self.assertEqual((self.out/'complete.json').read_bytes(),content)
        self.assertEqual((self.out/'complete.json').stat().st_nlink,1)

    def test_external_completion_hard_links_are_refused_unchanged(self):
        self.prepare();self.complete();external=self.home/'external-receipt'
        os.link(self.out/'complete.json',external)
        with self.assertRaisesRegex(ValueError,'External audit completion hard link'):V.run(self.out)
        self.assertTrue(external.exists());self.assertEqual((self.out/'complete.json').stat().st_nlink,2)

    def test_source_change_invalidates_checkpoint_and_historical_completion(self):
        self.prepare();self.complete();receipt=(self.out/'complete.json').read_bytes()
        self.mutate("UPDATE row_bag SET n=n+1")
        with self.assertRaisesRegex(ValueError,'Source inventory changed'):V.run(self.out,verify_only=True)
        self.assertEqual((self.out/'complete.json').read_bytes(),receipt)

    def test_cooperating_append_invalidates_in_progress_audit(self):
        self.prepare();V.run(self.out,max_steps=1);before=self.logical()
        index=next(t['first_partition'] for t in self.plan['tables'] if t['table']=='measurement')+100
        stage=self.home/'later';stage.mkdir();source=stage/'source';inventory=stage/'inventory';materialization=A.P.materialization_plan(self.plan,index)
        A.M.prepare(source,'S2','5.5',materialization['windows'],chunk_rows=1);A.M.run(source);A.I.collect(source,inventory);A.append(self.source,index,source,inventory)
        with self.assertRaisesRegex(ValueError,'Source inventory changed'):V.run(self.out)
        self.assertEqual(before,self.logical());self.assertFalse((self.out/'complete.json').exists())

    def test_source_and_audit_stop_files_and_operation_locks(self):
        self.prepare()
        for root in [self.out,self.source]:
            (root/'STOP').touch()
            try:
                with self.assertRaises(V.M.Stopped):V.run(self.out)
            finally:(root/'STOP').unlink()
            with V.M.locked(root),self.assertRaises(BlockingIOError):V.run(self.out)

    def test_prepare_requires_source_journal_recovery_without_writing_source(self):
        before=hashlib.sha256((self.source/'inventory.sqlite').read_bytes()).hexdigest()
        (self.source/'inventory.sqlite-journal').write_bytes(b'pending')
        with self.assertRaisesRegex(ValueError,'Recover the source journal'):self.prepare()
        self.assertFalse(self.out.exists());self.assertEqual(hashlib.sha256((self.source/'inventory.sqlite').read_bytes()).hexdigest(),before)

    def test_real_sqlite_callback_cancellation_preserves_last_page(self):
        self.prepare();V.run(self.out,max_steps=1);before=self.logical();add=V.Writer.add;stopped=[None]
        def cancel(writer,*args):
            add(writer,*args);stopped[0]='SIGTERM'
            writer.db.execute('WITH RECURSIVE n(v) AS (VALUES(1) UNION ALL SELECT v+1 FROM n WHERE v<100000) SELECT sum(v) FROM n').fetchone()
        with patch.object(V.Writer,'add',cancel),self.assertRaises(V.M.Stopped) as error:V.run(self.out,stop=lambda:stopped[0])
        self.assertEqual(error.exception.code,143);self.assertEqual(before,self.logical())

    def test_key_cap_preserves_checkpoint(self):
        self.prepare(bins=1);before=self.logical()
        with self.assertRaisesRegex(ValueError,'key budget'):V.run(self.out)
        self.assertEqual(before,self.logical());self.assertFalse((self.out/'complete.json').exists())

    def test_page_cap_rolls_back_current_regeneration_chunk(self):
        root=self.home/'pages';root.mkdir();self.source,self.plan=self.build(root,'5.5',size=1000);self.out=root/'audit'
        self.prepare(database_bytes=65536);before=self.logical()
        with self.assertRaises(sqlite3.Error):V.run(self.out)
        self.assertEqual(before,self.logical());self.assertLessEqual((self.out/'audit.sqlite').stat().st_size,65536)

    def test_buffered_repeated_observations_conserve_counts_across_chunks(self):
        root=self.home/'buffered';root.mkdir();self.source,self.plan=self.build(root,'5.5',size=1000);self.out=root/'audit';self.prepare()
        receipt=self.complete(max_steps=128,page_keys=1024)
        self.assertEqual(receipt['rows'],2000);self.assertEqual(receipt['row_keys'],1980)

    def test_byte_chain_reads_all_source_bytes_and_is_independently_reproducible(self):
        # Released free pages enlarge the physical file across an 8 MiB boundary
        # without changing its schema, live rows, histograms or cached counts.
        with closing(sqlite3.connect(self.source/'inventory.sqlite')) as db:
            db.execute('PRAGMA auto_vacuum=NONE');db.execute('VACUUM')
            db.execute("INSERT INTO row_bag VALUES('audit_padding',zeroblob(?),1)",(9*1024*1024+137,));db.commit()
            db.execute("DELETE FROM row_bag WHERE table_name='audit_padding'");db.commit()
        self.prepare();result=self.complete();previous='00'*32;chunks=0
        with (self.source/'inventory.sqlite').open('rb') as stream:
            offset=0
            while raw:=stream.read(8*1024*1024):
                value=dict(offset=offset,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
                canonical=json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode('utf-8')+b'\n'
                previous=hashlib.sha256(bytes.fromhex(previous)+canonical).hexdigest();offset+=len(raw);chunks+=1
        self.assertGreaterEqual(chunks,2)
        self.assertEqual(result['source_file_digest_algorithm'],'sha256-chain-8MiB-v1')
        self.assertEqual(result['source_file_bytes'],offset);self.assertEqual(result['source_file_chain'],previous)

    def test_corrupt_completion_checkpoint_is_refused(self):
        self.prepare();self.complete()
        with closing(sqlite3.connect(self.out/'audit.sqlite')) as db,db:
            value=self.checkpoint();value['receipt']['rows']=99
            db.execute('UPDATE '+V.META+' SET document=?',(json.dumps(value),))
        with self.assertRaisesRegex(ValueError,'completion checkpoint differs'):V.run(self.out)

    def test_code_drift_bounds_output_isolation_and_cli_budget_exit(self):
        for path in [self.source/'inside',self.home/'registration'/'inside',self.home]:
            with self.subTest(path=path),self.assertRaises(ValueError):V.prepare(self.source,path)
        self.prepare()
        with patch.object(V,'SOURCE_SHA','0'*64),self.assertRaisesRegex(ValueError,'changed after import'):V.run(self.out)
        for options in [dict(max_steps=0),dict(page_keys=True),dict(page_keys=1025)]:
            with self.subTest(options=options),self.assertRaises(ValueError):V.run(self.out,**options)
        with patch.object(sys,'argv',['audit','run','--output-dir',str(self.out),'--max-steps','1']),patch.object(sys,'stdout',new_callable=io.StringIO) as output:
            self.assertEqual(V.main(),3)
        self.assertEqual(json.loads(output.getvalue())['rows_regenerated'],1)


if __name__=='__main__':unittest.main()
