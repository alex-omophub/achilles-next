"""Real SQLite transactions and independent partition-union accounting."""
from collections import Counter
from contextlib import closing,contextmanager
import csv
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
saved=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    import partition_inventory as A
finally:sys.path[:]=saved


@unittest.skipUnless(A.M.fcntl is not None,'POSIX source/reducer locks')
class ReductionTest(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);self.home=Path(temporary.name)
        self.schedule,self.plan=self.make_schedule(self.home,'5.5')
        self.output=self.home/'reducer';A.prepare(self.schedule,self.output);self.inputs={}

    def make_schedule(self,root,version,size=1):
        registration=root/'registration';schedule=root/'schedule'
        A.R.register(registration,'reduction-test','S2',version,{r:str(root) for r in A.R.ROLES})
        return schedule,A.P.create(registration,schedule,rows_per_partition=size,chunk_rows=min(size,10000))

    def index(self,table,offset=0,plan=None):
        return next(t['first_partition'] for t in (plan or self.plan)['tables'] if t['table']==table)+offset

    def materialize(self,index,root=None,plan=None):
        root=root or self.home;plan=plan or self.plan;source=root/('source-'+str(index));inventory=root/('inventory-'+str(index))
        expected=A.P.materialization_plan(plan,index);c=plan['controls'];s=plan['source']
        A.M.prepare(source,s['tier'],s['parameters']['cdm_version'],expected['windows'],chunk_rows=c['chunk_rows'])
        A.M.run(source);A.I.collect(source,inventory);return source,inventory

    def add(self,index,**kwargs):
        if index not in self.inputs:self.inputs[index]=self.materialize(index)
        return A.append(self.output,index,*self.inputs[index],**kwargs)

    def logical(self):
        with closing(sqlite3.connect(self.output/'inventory.sqlite')) as db:
            return {table:db.execute('SELECT * FROM '+table+' ORDER BY 1,2').fetchall() for table in A.SCHEMA}

    def test_exact_global_row_bags_histograms_and_stats_all_versions(self):
        for version in ['5.3','5.4','5.5']:
            with self.subTest(version=version):
                root=self.home/version;root.mkdir();schedule,plan=self.make_schedule(root,version);out=root/'reduce';A.prepare(schedule,out)
                bags=Counter();bins=Counter();nulls={};csv_rows=Counter();inputs=[]
                for table,offset in [('measurement',98),('measurement',99),('observation',0),('person',0),('note',0)]:
                    index=self.index(table,offset,plan);source,inventory=self.materialize(index,root,plan);inputs.append(source)
                    A.append(out,index,source,inventory)
                    for chunk in A.M.read_json(source/'complete.json')['chunks']:
                        raw=(source/chunk['file']).read_bytes();lines=raw.splitlines(keepends=True)[1:]
                        rows=list(csv.DictReader(io.StringIO(raw.decode())))
                        for row,line in zip(rows,lines):
                            bags[table,line]+=1;csv_rows[table]+=1;counts=nulls.setdefault(table,{c:0 for c in row})
                            for c,v in row.items():counts[c]+=v=='\\N'
                    # Sum keyed observations, never per-partition distinct counts.
                    with closing(sqlite3.connect(inventory/'inventory.sqlite')) as db:
                        for t,dimension,value,n in db.execute('SELECT * FROM bins'):bins[t,dimension,value]+=n
                with closing(sqlite3.connect(out/'inventory.sqlite')) as db:
                    self.assertEqual({(t,bytes(v)):n for t,v,n in db.execute('SELECT * FROM row_bag')},dict(bags))
                    self.assertEqual({(t,d,v):n for t,d,v,n in db.execute('SELECT * FROM bins')},dict(bins))
                value=A.status(out);self.assertEqual(value['committed_partitions'],5)
                for table,n in csv_rows.items():
                    info=value['tables'][table];self.assertEqual(info['selected_rows'],n);self.assertEqual(info['null_counts'],nulls[table])
                    self.assertEqual(info['distinct_rows'],sum(t==table for t,_ in bags))
                    self.assertEqual(info['duplicate_rows'],n-info['distinct_rows'])
                self.assertEqual(value['tables']['measurement']['distinct_rows'],1)
                self.assertEqual(value['tables']['measurement']['duplicate_rows'],1)
                self.assertEqual(value['tables']['note']['distinct_rows'],0)
                self.assertFalse(value['all_scheduled_partitions_accumulated']);self.assertFalse(value['whole_source_audited'])

    def test_retry_adopts_journal_without_original_files_or_double_counting(self):
        index=self.index('measurement',98);self.add(index);before=self.logical()
        source,inventory=self.inputs[index];source.rename(self.home/'archived-source');inventory.rename(self.home/'archived-inventory')
        with patch.object(A.I,'verify',side_effect=AssertionError('must not replay committed inputs')):
            result=self.add(index)
        self.assertEqual(result['status'],'already_committed');self.assertEqual(before,self.logical())
        self.assertEqual(result['progress']['selected_rows'],1)

    def test_more_than_eight_partitions_and_only_new_input_is_verified(self):
        for offset in range(12):self.add(self.index('measurement',80+offset))
        with patch.object(A.I,'verify',wraps=A.I.verify) as verify:
            index=self.index('measurement',92);self.add(index)
        self.assertEqual(verify.call_count,1);self.assertEqual(A.status(self.output)['committed_partitions'],13)

    def test_partial_merge_failure_rolls_back_rows_histograms_and_checkpoint(self):
        self.add(self.index('measurement',98));before=self.logical();apply=A.Sink.apply
        def fail(sink,key,count):apply(sink,key,count);raise RuntimeError('injected merge failure')
        with patch.object(A.Sink,'apply',fail),self.assertRaisesRegex(RuntimeError,'merge failure'):
            self.add(self.index('measurement',99))
        self.assertEqual(before,self.logical());self.assertEqual(A.status(self.output)['selected_rows'],1)
        self.add(self.index('measurement',99));self.assertEqual(A.status(self.output)['tables']['measurement']['duplicate_rows'],1)

    def test_receipt_write_failure_leaves_authoritative_committed_sqlite_state(self):
        atomic=A.M.atomic_json;index=self.index('measurement',98)
        def fail(root,name,*args,**kwargs):
            if name=='progress.json':raise OSError('receipt write failed')
            return atomic(root,name,*args,**kwargs)
        with patch.object(A.M,'atomic_json',side_effect=fail),self.assertRaisesRegex(OSError,'receipt write failed'):self.add(index)
        self.assertFalse((self.output/'progress.json').exists());self.assertEqual(A.status(self.output)['selected_rows'],1)
        self.assertEqual(self.add(index)['status'],'already_committed');self.assertEqual(A.status(self.output)['selected_rows'],1)

    def test_lost_commit_response_is_recovered_without_double_merge(self):
        connection=A.connection
        class LostResponse:
            def __init__(self,db):self.db=db
            def __getattr__(self,key):return getattr(self.db,key)
            def execute(self,sql,*args):
                result=self.db.execute(sql,*args)
                if sql=='COMMIT':raise RuntimeError('commit response lost')
                return result
        @contextmanager
        def lose(*args):
            with connection(*args) as db:yield LostResponse(db)
        index=self.index('measurement',98)
        with patch.object(A,'connection',lose),self.assertRaisesRegex(RuntimeError,'response lost'):self.add(index)
        self.assertEqual(A.status(self.output)['committed_partitions'],1)
        self.assertEqual(self.add(index)['status'],'already_committed');self.assertEqual(A.status(self.output)['selected_rows'],1)

    def test_wrong_partition_and_corrupt_source_leave_accumulator_unchanged(self):
        index=self.index('measurement',98);source,inventory=self.materialize(index);before=self.logical()
        with self.assertRaisesRegex(ValueError,'scheduled partition'):A.append(self.output,index+1,source,inventory)
        self.assertEqual(before,self.logical());(source/'chunk-000000.csv').write_bytes(b'bad')
        with self.assertRaises(ValueError):A.append(self.output,index,source,inventory)
        self.assertEqual(before,self.logical())

    def test_changed_inventory_during_snapshot_is_refused_before_merge(self):
        index=self.index('measurement',98);self.inputs[index]=self.materialize(index);before=self.logical();hash_file=A.I.hash_file
        def changed(path,*args):
            if Path(path).parent.name.startswith('achillesnext-reduction-'):
                value=hash_file(path,*args);return dict(value,sha256='0'*64)
            return hash_file(path,*args)
        with patch.object(A.I,'hash_file',side_effect=changed),self.assertRaisesRegex(ValueError,'snapshot differs'):self.add(index)
        self.assertEqual(before,self.logical())

    def test_STOP_lock_and_code_drift_prevent_input_replay(self):
        index=self.index('measurement',98);self.inputs[index]=self.materialize(index);before=self.logical()
        (self.output/'STOP').touch()
        with patch.object(A.I,'verify',side_effect=AssertionError('unexpected scan')),self.assertRaises(A.M.Stopped):self.add(index)
        (self.output/'STOP').unlink()
        with A.M.locked(self.output),self.assertRaises(BlockingIOError):self.add(index)
        with patch.object(A,'SOURCE_SHA','0'*64),self.assertRaisesRegex(ValueError,'changed after import'):self.add(index)
        self.assertEqual(before,self.logical())

    def test_stop_during_real_sqlite_work_preserves_prefix_and_exit_code(self):
        self.add(self.index('measurement',98));before=self.logical();apply=A.Sink.apply;stopped=[None]
        def interrupt(sink,key,count):
            apply(sink,key,count);stopped[0]='SIGTERM'
            sink.connection.execute('WITH RECURSIVE n(v) AS (VALUES(1) UNION ALL SELECT v+1 FROM n WHERE v<100000) SELECT sum(v) FROM n').fetchone()
        with patch.object(A.Sink,'apply',interrupt),self.assertRaises(A.M.Stopped) as error:
            self.add(self.index('measurement',99),stop=lambda:stopped[0])
        self.assertEqual(error.exception.code,143);self.assertEqual(before,self.logical())

    def test_global_key_ceiling_failure_preserves_prior_empty_partition(self):
        self.output=self.home/'limited';A.prepare(self.schedule,self.output,bins=1)
        self.add(self.index('note'));before=self.logical()
        with self.assertRaisesRegex(ValueError,'bin budget'):self.add(self.index('measurement',98))
        self.assertEqual(before,self.logical());self.assertEqual(A.status(self.output)['committed_partitions'],1)

    def test_global_page_ceiling_rolls_back_current_partition(self):
        root=self.home/'page-case';root.mkdir();schedule,plan=self.make_schedule(root,'5.5',size=2000)
        out=root/'reduce';A.prepare(schedule,out,database_bytes=65536)
        source,inventory=self.materialize(self.index('measurement',0,plan),root,plan)
        with self.assertRaises(sqlite3.Error):A.append(out,self.index('measurement',0,plan),source,inventory)
        value=A.status(out);self.assertEqual(value['selected_rows'],0);self.assertEqual(value['committed_partitions'],0)
        self.assertLessEqual((out/'inventory.sqlite').stat().st_size,65536)

    def test_settings_bounds_and_no_implicit_budget_raise(self):
        for options in [dict(database_bytes=True),dict(database_bytes=A.MAX_DB+1),dict(database_bytes=1),dict(bins=True),dict(bins=2**31),dict(seconds=float('nan'))]:
            with self.subTest(options=options),self.assertRaises(ValueError):A.controls(**options)
        self.assertEqual(A.controls()['database_bytes'],A.I.MAX_DB)
        self.assertEqual(A.controls(database_bytes=65537)['database_bytes'],65536)

    def test_output_isolation_and_existing_directory_preserved(self):
        before=self.logical()
        with self.assertRaises(FileExistsError):A.prepare(self.schedule,self.output)
        for out in [self.schedule/'inside',self.home/'registration'/'inside',self.home]:
            with self.subTest(out=out),self.assertRaises(ValueError):A.prepare(self.schedule,out)
        self.assertEqual(before,self.logical())

    def test_header_schema_and_nondict_request_refusals(self):
        for value in [None,[],True]:
            with closing(sqlite3.connect(self.output/'inventory.sqlite')) as db,db:
                db.execute('UPDATE '+A.META+' SET document=?',(json.dumps(value),))
            with self.subTest(value=value),self.assertRaises(ValueError):A.status(self.output)
        A.M.atomic_json(self.output,'request.json',[])
        with self.assertRaisesRegex(ValueError,'Invalid reducer request'):A.status(self.output)

    def test_inconsistent_summary_and_unexpected_artifact_refuse_status(self):
        self.add(self.index('measurement',98))
        with closing(sqlite3.connect(self.output/'inventory.sqlite')) as db,db:
            value=json.loads(db.execute('SELECT document FROM '+A.META).fetchone()[0]);value['tables']['measurement']['duplicate_rows']=4
            db.execute('UPDATE '+A.META+' SET document=?',(json.dumps(value),))
        with self.assertRaisesRegex(ValueError,'conserve rows'):A.status(self.output)
        (self.output/'unexpected').touch()
        with self.assertRaisesRegex(ValueError,'Unexpected reducer artifact'):A.status(self.output)

    def test_malformed_committed_receipt_refuses_retry(self):
        index=self.index('measurement',98);self.add(index)
        with closing(sqlite3.connect(self.output/'inventory.sqlite')) as db,db:
            value=json.loads(db.execute('SELECT document FROM '+A.PARTS).fetchone()[0]);value['selected_rows']=True
            db.execute('UPDATE '+A.PARTS+' SET document=?',(json.dumps(value),))
        with self.assertRaisesRegex(ValueError,'partition identity'):self.add(index)

    def test_source_and_output_locks_are_held_during_snapshot(self):
        original=A.snapshot;index=self.index('measurement',98);self.inputs[index]=self.materialize(index)
        @contextmanager
        def probe(*args):
            with original(*args) as value:
                for path in [self.output,self.inputs[index][0]]:
                    with self.assertRaises(BlockingIOError):
                        with A.M.locked(path):pass
                yield value
        with patch.object(A,'snapshot',probe):self.add(index)

    def test_prepare_and_cli_cancel_with_clean_exit(self):
        with self.assertRaises(A.M.Stopped):A.prepare(self.schedule,self.home/'cancelled',stop=lambda:'SIGINT')
        self.assertFalse((self.home/'cancelled').exists());(self.output/'STOP').touch()
        with patch.object(sys,'argv',['reduce','status','--output-dir',str(self.output)]),patch.object(sys,'stderr',new_callable=io.StringIO) as output:
            self.assertEqual(A.main(),3)
        self.assertIn('operator_stop_file',output.getvalue())

    def test_cli_status_and_mutating_settings_are_explicit(self):
        with patch.object(sys,'argv',['reduce','status','--output-dir',str(self.output)]),patch.object(sys,'stdout',new_callable=io.StringIO) as output:
            self.assertEqual(A.main(),0)
        self.assertEqual(json.loads(output.getvalue())['committed_partitions'],0)
        with patch.object(sys,'argv',['reduce','status','--output-dir',str(self.output),'--bins','5']),patch.object(sys,'stderr',new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as error:A.main()
        self.assertEqual(error.exception.code,2)


if __name__=='__main__':unittest.main()
