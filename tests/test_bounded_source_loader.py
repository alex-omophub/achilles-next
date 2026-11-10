"""Freeze, transactional SQL construction and bounded fixture-load controls."""
import hashlib
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
    import bounded_source_loader as L
finally: sys.path[:]=_saved


class FakeClient:
    instances=[]; failure=None; cleanup_rows=[]; bad_target=False

    def __init__(self,state,guard,application):
        self.guard=guard; self.last_error=None; self.sql=[]; self.payloads={}; self.links={}; self.__class__.instances.append(self)

    def rows(self,sql):
        self.guard.check()
        if 'current_database() AS db' in sql:
            return [dict(db='other' if self.bad_target else L.F.DB,usr=L.F.OWNER,marker=L.F.MARKER)]
        if 'inet_server_addr()' in sql: return [dict(address='127.0.0.1')]
        if 'pg_namespace' in sql: return self.cleanup_rows
        raise AssertionError('Unexpected metadata query: '+sql)

    def versions(self): return dict(server=L.F.LOCK['postgresql_server'],client='native pinned test double')

    def run(self,sql):
        self.guard.check(); self.sql.append(sql)
        for path in re.findall(r"FROM '([^']+)' WITH",sql):
            self.payloads[Path(path).name]=Path(path).read_bytes(); self.links[Path(path).name]=Path(path).stat().st_nlink
        if self.failure: self.last_error='simulated SQL failure'; raise RuntimeError(self.failure)


@unittest.skipUnless(L.M.fcntl is not None,'POSIX source verifier')
class LoaderTest(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.home=Path(temp.name); self.source=self.home/'source'; self.inventory=self.home/'inventory'
        self.registration=self.home/'registration'; self.output=self.home/'load'
        L.M.prepare(self.source,'S2','5.5',[dict(table='measurement',start=95,rows=24),dict(table='note',start=0,rows=0)],chunk_rows=4)
        self.assertEqual(L.M.run(self.source)['status'],'complete'); L.I.collect(self.source,self.inventory)
        L.R.register(self.registration,'load-check','S2','5.5',{r:str(self.home) for r in L.R.ROLES},self.source,self.inventory)
        FakeClient.instances=[]; FakeClient.failure=None; FakeClient.cleanup_rows=[]; FakeClient.bad_target=False
        self.mock=patch.object(L,'Client',FakeClient); self.mock.start(); self.addCleanup(self.mock.stop)

    def load(self,**kwargs): return L.load(self.registration,self.output,self.home/'unused-state',**kwargs)

    def hashes(self):
        return {str(p.relative_to(self.home)):hashlib.sha256(p.read_bytes()).hexdigest() for root in [self.source,self.inventory,self.registration] for p in root.iterdir() if p.is_file()}

    def test_frozen_copy_matches_source_and_all_facts_precede_commit(self):
        before=self.hashes(); receipt=self.load(); client=FakeClient.instances[-1]
        expected={p.name:p.read_bytes() for p in self.source.glob('*.csv')}
        self.assertEqual(client.payloads,expected); self.assertEqual(before,self.hashes())
        sql=client.sql[-1]; self.assertTrue(sql.startswith('BEGIN;')); self.assertTrue(sql.endswith('COMMIT;'))
        self.assertLess(sql.index('Not the local marked fixture'),sql.index('CREATE SCHEMA'))
        self.assertLess(sql.index('Loaded selection facts differ'),sql.index('COMMIT;'))
        self.assertIn('HEADER true',sql); self.assertNotIn('PRIMARY KEY',sql)
        self.assertEqual(receipt['rows'],24); self.assertEqual(receipt['tables']['measurement']['rows'],24)
        self.assertEqual(receipt['tables']['person']['rows'],0)
        self.assertFalse(receipt['whole_source_loaded']); self.assertFalse(receipt['qualifying'])
        for path in re.findall(r"FROM '([^']+)' WITH",sql): self.assertFalse(Path(path).exists())

    def test_internal_source_links_keep_logical_copy_multiplicity(self):
        # Exercise the accepted link pair using a separately frozen source.
        import os
        source=self.home/'linked-source'; inventory=self.home/'linked-inventory'; reg=self.home/'linked-registration'
        L.M.prepare(source,'S2','5.5',[dict(table='measurement',start=98,rows=2)],chunk_rows=1); L.M.run(source)
        first=source/'chunk-000000.csv'; second=source/'chunk-000001.csv'; second.unlink(); os.link(first,second)
        L.I.collect(source,inventory); L.R.register(reg,'linked','S2','5.5',{r:str(self.home) for r in L.R.ROLES},source,inventory)
        receipt=L.load(reg,self.output,self.home/'state')
        self.assertEqual(receipt['rows'],2); self.assertEqual(len(FakeClient.instances[-1].payloads),2)
        self.assertEqual(set(FakeClient.instances[-1].links.values()),{2})
        self.assertEqual(first.stat().st_ino,second.stat().st_ino)

    def test_sql_failure_keeps_request_without_success_and_preserves_inputs(self):
        before=self.hashes(); FakeClient.failure='COPY failed'
        with self.assertRaisesRegex(RuntimeError,'COPY failed'): self.load()
        self.assertEqual(before,self.hashes()); self.assertTrue((self.output/'request.json').exists())
        self.assertFalse((self.output/'complete.json').exists())
        attempt=L.M.read_json(self.output/'attempt.json'); self.assertEqual(attempt['commit_outcome'],'unknown')
        self.assertEqual(attempt['database_error'],'simulated SQL failure')

    def test_completion_write_failure_has_recoverable_schema_identity(self):
        original=L.M.atomic_json
        def fail(root,name,value,exclusive=False):
            if name=='complete.json' and Path(root).resolve()==self.output.resolve(): raise OSError('completion write failed')
            return original(root,name,value,exclusive)
        with patch.object(L.M,'atomic_json',fail),self.assertRaisesRegex(OSError,'completion write'): self.load()
        request=L.M.read_json(self.output/'request.json'); self.assertRegex(request['schema'],'^cdm_selection_[0-9a-f]{16}$')
        self.assertEqual(L.M.read_json(self.output/'attempt.json')['commit_outcome'],'unknown')

    def test_wrong_target_cannot_issue_source_ddl(self):
        FakeClient.bad_target=True
        with self.assertRaisesRegex(ValueError,'marked fixture'): self.load()
        self.assertEqual(FakeClient.instances[-1].sql,[])
        self.assertEqual(L.M.read_json(self.output/'attempt.json')['commit_outcome'],'not_attempted')

    def test_missing_witness_and_corrupt_source_fail_before_connection(self):
        plain=self.home/'plain'; L.R.register(plain,'plain','S2','5.5',{r:str(self.home) for r in L.R.ROLES})
        with self.assertRaisesRegex(ValueError,'bounded witness'): L.load(plain,self.output,self.home/'state')
        (self.source/'chunk-000000.csv').write_bytes(b'corrupt')
        with self.assertRaises(ValueError): self.load()
        self.assertFalse(self.output.exists()); self.assertEqual(FakeClient.instances,[])

    def test_code_or_ddl_drift_refuses_before_ddl(self):
        with patch.object(L,'SOURCE_SHA','0'*64),self.assertRaisesRegex(ValueError,'Loader changed'): self.load()
        self.assertEqual(FakeClient.instances,[])

    def test_cancelled_registration_and_deadline_do_no_database_work(self):
        for reason,code in [('SIGINT',130),('SIGTERM',143)]:
            with self.subTest(reason=reason),self.assertRaises(L.M.Stopped) as error: self.load(stop=lambda:reason)
            self.assertEqual(error.exception.code,code)
        self.assertEqual(FakeClient.instances,[]); self.assertFalse(self.output.exists())
        guard=L.Guard([self.home],seconds=1)
        with patch.object(L.I.time,'monotonic',return_value=guard.began+2),self.assertRaises(L.M.Stopped): guard.check()
        with self.assertRaises(L.M.Stopped): L.R.verify(self.registration,stop=lambda:'SIGINT')

    def test_existing_output_and_input_overlap_are_preserved(self):
        self.load(); before=(self.output/'complete.json').read_bytes()
        with self.assertRaises(FileExistsError): self.load()
        self.assertEqual((self.output/'complete.json').read_bytes(),before)
        for path in [self.source/'nested',self.inventory/'nested',self.registration/'nested',self.home]:
            with self.subTest(path=path),self.assertRaises(ValueError): L.load(self.registration,path,self.home/'state')
        alias=self.home/'alias'; alias.symlink_to(self.home/'absent')
        with self.assertRaises(ValueError): L.load(self.registration,alias,self.home/'state')
        self.assertFalse((self.home/'absent').exists())

    def test_cleanup_checks_saved_identity_and_actual_owner_marker(self):
        self.load(); request=L.M.read_json(self.output/'request.json')
        self.assertEqual(L.drop(self.home/'state',self.output)['status'],'absent')
        for rows in [[dict(marker='other',owned=True)],[dict(marker=request['marker'],owned=False)]]:
            FakeClient.cleanup_rows=rows
            with self.subTest(rows=rows),self.assertRaisesRegex(ValueError,'unowned or differently marked'): L.drop(self.home/'state',self.output)
            self.assertEqual(FakeClient.instances[-1].sql,[])
        FakeClient.cleanup_rows=[dict(marker=request['marker'],owned=True)]
        self.assertEqual(L.drop(self.home/'state',self.output)['status'],'dropped')
        sql=FakeClient.instances[-1].sql[-1]
        self.assertIn('Selection cleanup owner/marker changed',sql); self.assertIn('Not the local marked fixture',sql)
        request['schema']='fixture_results'; L.M.atomic_json(self.output,'request.json',request)
        with self.assertRaisesRegex(ValueError,'Invalid owned'): L.drop(self.home/'state',self.output)

    def test_cleanup_never_races_an_active_load_lock(self):
        self.load(); before=len(FakeClient.instances)
        with L.M.locked(self.output),self.assertRaises(BlockingIOError): L.drop(self.home/'state',self.output)
        self.assertEqual(len(FakeClient.instances),before)


if __name__=='__main__': unittest.main()
