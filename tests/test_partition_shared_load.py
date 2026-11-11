"""One-schema loading and exact selected-union inventories from saved partitions."""
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
_saved=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    import partition_shared_load as H
finally:sys.path[:]=_saved


class Client:
    instances=[];failure=False
    def __init__(self,state,guard,application):
        self.guard=guard;self.last_error=None;self.sql=[];self.links={};self.committed=False
        self.__class__.instances.append(self)
    def rows(self,sql):
        self.guard.check()
        if 'current_database() AS db' in sql:return [dict(db=H.L.F.DB,usr=H.L.F.OWNER,marker=H.L.F.MARKER)]
        if 'inet_server_addr()' in sql:return [dict(address='127.0.0.1')]
        if 'pg_namespace' in sql:return []
        raise AssertionError(sql)
    def versions(self):return dict(server=H.L.F.LOCK['postgresql_server'],client='test double')
    def run(self,sql):
        self.guard.check();self.sql.append(sql)
        for name in re.findall(r"FROM '([^']+)' WITH",sql):self.links[Path(name).name]=Path(name).stat().st_nlink
        if self.failure:self.last_error='injected database error';raise RuntimeError(self.last_error)
        self.committed=True


@unittest.skipUnless(H.M.fcntl is not None,'POSIX partition loading')
class SharedLoadTest(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);self.home=Path(temp.name)
        self.registration=self.home/'registration';self.schedule=self.home/'schedule';self.execution=self.home/'execution';self.output=self.home/'shared'
        H.R.register(self.registration,'shared-test','S2','5.5',{r:str(self.home) for r in H.R.ROLES})
        plan=H.E.P.create(self.registration,self.schedule,rows_per_partition=1,chunk_rows=1)
        measurement=next(t['first_partition'] for t in plan['tables'] if t['table']=='measurement')
        empty=next(t['first_partition'] for t in plan['tables'] if not t['rows'])
        H.E.prepare(self.schedule,self.execution,[measurement+98,measurement+99,empty]);H.E.run(self.execution)
        Client.instances=[];Client.failure=False
        self.mock=patch.object(H.L,'Client',Client);self.mock.start();self.addCleanup(self.mock.stop)

    def load(self,**kwargs):return H.load(self.execution,self.output,self.home/'unused-state',**kwargs)
    def hashes(self,root):return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}

    def test_exact_union_inventory_counts_cross_partition_duplicates_and_one_schema(self):
        before=self.hashes(self.execution)
        with patch.object(H.M,'run',side_effect=AssertionError('must reuse committed chunks')):result=self.load()
        self.assertEqual(before,self.hashes(self.execution));self.assertEqual(result['rows'],2)
        inventory=H.I.verify(self.output/'source',self.output/'inventory')
        self.assertEqual(inventory['tables']['measurement']['distinct_rows'],1)
        self.assertEqual(inventory['tables']['measurement']['duplicate_rows'],1)
        sql=Client.instances[-1].sql[-1];self.assertEqual(sql.count('CREATE SCHEMA'),1)
        self.assertEqual(set(re.findall(r'\\copy "([^"]+)"',sql)),{result['schema']})
        self.assertEqual(len(Client.instances[-1].links),3)
        binding=H.M.read_json(self.output/'binding.json')
        self.assertEqual(result['binding_sha256'],binding['binding_sha256'])
        self.assertEqual(binding['execution_completion_sha256'],H.S.BASE.sha(H.S.BASE.canonical(H.E.verify(self.execution))))
        for key in ['whole_source_loaded','full_tier_generated','qualifying']:self.assertIs(result[key],False)

    def test_input_operation_lock_prevents_copy_or_output(self):
        with H.M.locked(self.execution),self.assertRaises(BlockingIOError):self.load()
        self.assertFalse(self.output.exists());self.assertEqual(Client.instances,[])

    def test_both_operation_locks_remain_held_during_database_load(self):
        original=H.L.load
        def locked(*args,**kwargs):
            for path in [self.execution,self.output]:
                with self.subTest(path=path),self.assertRaises(BlockingIOError):
                    with H.M.locked(path):pass
            return original(*args,**kwargs)
        with patch.object(H.L,'load',side_effect=locked):self.load()

    def test_existing_output_symlink_and_input_overlaps_are_preserved(self):
        for output in [self.execution/'inside',self.schedule/'inside',self.registration/'inside',self.home]:
            with self.subTest(output=output),self.assertRaises(ValueError):H.load(self.execution,output,self.home/'state')
        alias=self.home/'alias';alias.symlink_to(self.home/'absent')
        with self.assertRaises(ValueError):H.load(self.execution,alias,self.home/'state')
        self.assertFalse((self.home/'absent').exists());self.load();before=self.hashes(self.output)
        with self.assertRaises(FileExistsError):self.load()
        self.assertEqual(before,self.hashes(self.output))

    def test_incomplete_or_corrupt_execution_never_reaches_database(self):
        chunk=next((self.execution/'unit-001/source').glob('*.csv'));chunk.write_bytes(chunk.read_bytes()+b'changed')
        with self.assertRaises(ValueError):self.load()
        self.assertFalse(self.output.exists());self.assertEqual(Client.instances,[])

    def test_combined_csv_byte_budget_refuses_without_creating_source(self):
        with H.M.locked(self.execution) as execution:
            _,req,plan=H.E.verify_locked(execution,H.E.Guard(execution))
            read=H.M.read_json
            def too_large(path):
                value=read(path)
                if Path(path).name=='complete.json':value=dict(value,csv_bytes=H.M.MAX_BYTES)
                return value
            with patch.object(H.M,'read_json',side_effect=too_large),self.assertRaisesRegex(ValueError,'64 MiB'):H.merged_plan(execution,req,plan)
        self.assertFalse(self.output.exists());self.assertEqual(Client.instances,[])

    def test_corrupt_copied_source_is_refused_before_inventory_and_database(self):
        original=H.copy_sources
        def corrupt(*args,**kwargs):
            result=original(*args,**kwargs);chunk=next((self.output/'source').glob('*.csv'));chunk.write_bytes(chunk.read_bytes()+b'bad');return result
        with patch.object(H,'copy_sources',side_effect=corrupt),self.assertRaises(ValueError):self.load()
        self.assertEqual(Client.instances,[]);attempt=H.M.read_json(self.output/'attempt.json')
        self.assertEqual(attempt['commit_outcome'],'not_attempted');self.assertFalse((self.output/'complete.json').exists())

    def test_witness_registration_preserves_outer_cancellation(self):
        original=H.I.verify;stopped=[None]
        def scan(source,inventory,**kwargs):
            if Path(source).resolve()==(self.output/'source').resolve():stopped[0]='SIGTERM'
            return original(source,inventory,**kwargs)
        with patch.object(H.I,'verify',side_effect=scan),self.assertRaises(H.M.Stopped) as error:self.load(stop=lambda:stopped[0])
        self.assertEqual(error.exception.code,143);self.assertEqual(Client.instances,[])
        self.assertFalse((self.output/'registration').exists())
        self.assertEqual(H.M.read_json(self.output/'attempt.json')['stage'],'registration')

    def test_database_failure_retains_owned_child_request_and_inputs(self):
        before=self.hashes(self.execution);Client.failure=True
        with self.assertRaisesRegex(RuntimeError,'injected database error'):self.load()
        self.assertEqual(before,self.hashes(self.execution));self.assertTrue((self.output/'load/request.json').exists())
        self.assertFalse((self.output/'complete.json').exists())
        self.assertEqual(H.M.read_json(self.output/'attempt.json')['commit_outcome'],'unknown')

    def test_outer_receipt_failure_records_confirmed_commit(self):
        atomic=H.M.atomic_json
        def fail(root,name,value,exclusive=False):
            if Path(root).resolve()==self.output.resolve() and name=='complete.json':raise OSError('outer receipt failed')
            return atomic(root,name,value,exclusive)
        with patch.object(H.M,'atomic_json',side_effect=fail),self.assertRaisesRegex(OSError,'outer receipt'):self.load()
        self.assertTrue(Client.instances[-1].committed);self.assertTrue((self.output/'load/complete.json').exists())
        self.assertEqual(H.M.read_json(self.output/'attempt.json')['commit_outcome'],'committed')

    def test_child_receipt_failure_preserves_confirmed_commit_outcome(self):
        atomic=H.M.atomic_json
        def fail(root,name,value,exclusive=False):
            if Path(root).resolve()==(self.output/'load').resolve() and name=='complete.json':raise OSError('child receipt failed')
            return atomic(root,name,value,exclusive)
        with patch.object(H.M,'atomic_json',side_effect=fail),self.assertRaisesRegex(OSError,'child receipt'):self.load()
        self.assertEqual(H.M.read_json(self.output/'attempt.json')['commit_outcome'],'committed')
        self.assertTrue((self.output/'load/request.json').exists())

    def test_internal_chunk_hardlinks_survive_copy_and_loader_freeze(self):
        schedule=self.home/'linked-schedule';execution=self.home/'linked-execution'
        plan=H.E.P.create(self.registration,schedule,rows_per_partition=2,chunk_rows=1)
        index=next(t['first_partition'] for t in plan['tables'] if t['table']=='measurement')+49
        H.E.prepare(schedule,execution,[index]);run=H.M.run
        def link(root,**kwargs):
            result=run(root,**kwargs);first=Path(root)/'chunk-000000.csv';second=Path(root)/'chunk-000001.csv'
            self.assertEqual(first.read_bytes(),second.read_bytes());second.unlink();os.link(first,second);return result
        with patch.object(H.M,'run',side_effect=link):H.E.run(execution)
        result=H.load(execution,self.output,self.home/'state')
        self.assertEqual(result['rows'],2);self.assertEqual(set(Client.instances[-1].links.values()),{2})
        chunks=list((self.output/'source').glob('*.csv'));self.assertEqual(chunks[0].stat().st_ino,chunks[1].stat().st_ino)

    def test_stop_deadline_and_code_drift_do_not_start_output(self):
        for reason,code in [('SIGINT',130),('SIGTERM',143)]:
            with self.subTest(reason=reason),self.assertRaises(H.M.Stopped) as error:self.load(stop=lambda:reason)
            self.assertEqual(error.exception.code,code)
        guard_class=H.E.Guard
        def expired(*args,**kwargs):
            guard=guard_class(*args,**kwargs);guard.began-=guard.controls['seconds']+1;return guard
        with patch.object(H.E,'Guard',side_effect=expired),self.assertRaises(H.M.Stopped) as error:self.load()
        self.assertEqual(error.exception.code,3)
        with patch.object(H,'SOURCE_SHA','0'*64),self.assertRaisesRegex(ValueError,'changed after import'):self.load()
        with self.assertRaises(ValueError):self.load(seconds=0)
        self.assertFalse(self.output.exists());self.assertEqual(Client.instances,[])

    def test_cleanup_locks_parent_and_refuses_mismatched_child_binding(self):
        self.load();before=len(Client.instances)
        with H.M.locked(self.output),self.assertRaises(BlockingIOError):H.drop(self.output,self.home/'state')
        self.assertEqual(len(Client.instances),before)
        binding=H.M.read_json(self.output/'binding.json');binding['combined_plan_sha256']='0'*64
        unsigned={k:v for k,v in binding.items() if k!='binding_sha256'}
        binding['binding_sha256']=H.S.BASE.sha(H.S.BASE.canonical(unsigned));H.M.atomic_json(self.output,'binding.json',binding)
        with self.assertRaisesRegex(ValueError,'differs'):H.drop(self.output,self.home/'state')
        self.assertEqual(len(Client.instances),before)

    def test_cleanup_can_use_saved_identity_after_original_inputs_are_archived(self):
        self.load();self.execution.rename(self.home/'archived')
        with patch.object(H.E,'verify_locked',side_effect=AssertionError('cleanup must not replay inputs')):
            self.assertEqual(H.drop(self.output,self.home/'state')['status'],'absent')


if __name__=='__main__':unittest.main()
