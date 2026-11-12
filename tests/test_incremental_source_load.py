"""Request integrity, bounded resume orchestration and generated SQL guards.

The orchestration double is not a PostgreSQL transaction simulator. Real rollback
and permission regressions are in test_incremental_source_load_postgresql.py.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
saved=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    import incremental_source_load as N
finally:sys.path[:]=saved


class Client:
    instances=[];chunks=[];phase='loading';exists=False;lost=False
    def __init__(self,*args):self.last_error=None;self.sql=[];self.__class__.instances.append(self)
    def value(self,sql):return 't'
    def rows(self,sql):return [dict(nspname='exists')] if self.exists else []
    def run(self,sql):
        self.sql.append(sql)
        if '\\echo dropped' in sql:
            status='dropped' if self.exists else 'absent';self.__class__.exists=False
            return subprocess.CompletedProcess([],0,'\n'+status+'\n','')
        self.__class__.exists=True
        match=re.search(r'INSERT INTO .* VALUES\((\d+),(.+)::jsonb\);',sql)
        if match:
            index=int(match[1]);chunk=json.loads(match[2][1:-1].replace("''","'"))
            if index==len(self.chunks):self.chunks.append(chunk)
            if self.lost:self.__class__.lost=False;raise RuntimeError('commit response lost')
        if "SET manifest=jsonb_set" in sql:self.__class__.phase='complete'
        return subprocess.CompletedProcess([],0,json.dumps(dict(phase=self.phase,chunks=self.chunks)),'')


@unittest.skipUnless(N.M.fcntl is not None,'POSIX loader')
class IncrementalTest(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);self.home=Path(temp.name)
        self.source=self.home/'source';self.inventory=self.home/'inventory';self.reg=self.home/'registration';self.out=self.home/'load'
        N.M.prepare(self.source,'S2','5.5',[dict(table='measurement',start=95,rows=12),dict(table='person',start=0,rows=2),dict(table='note',start=0,rows=0)],chunk_rows=4)
        N.M.run(self.source);N.I.collect(self.source,self.inventory)
        N.R.register(self.reg,'incremental-test','S2','5.5',{r:str(self.home) for r in N.R.ROLES},self.source,self.inventory)
        self.request=N.prepare(self.reg,self.out)
        Client.instances=[];Client.chunks=[];Client.phase='loading';Client.exists=False;Client.lost=False
        mock=patch.object(N.L,'Client',Client);mock.start();self.addCleanup(mock.stop)
        mock=patch.object(N.L,'check_target');mock.start();self.addCleanup(mock.stop)

    def run_load(self,**kw):return N.run(self.out,self.home/'state',**kw)

    def test_partial_invocation_resumes_same_schema_and_sql_prefix(self):
        with self.assertRaises(N.M.Stopped) as error:self.run_load(max_chunks=1)
        self.assertEqual(error.exception.code,3);self.assertEqual(len(Client.chunks),1)
        self.assertFalse((self.out/'complete.json').exists())
        result=self.run_load();self.assertEqual(result['schema'],self.request['schema'])
        self.assertEqual(result['rows'],14);self.assertFalse(result['qualifying']);self.assertEqual(len(Client.chunks),5)
        copied=[sql for c in Client.instances for sql in c.sql if '\\copy ' in sql]
        self.assertEqual(len(copied),5)

    def test_lost_commit_response_adopts_database_prefix(self):
        Client.lost=True
        with self.assertRaisesRegex(RuntimeError,'response lost'):self.run_load()
        self.assertEqual(len(Client.chunks),1);self.assertFalse((self.out/'progress.json').exists())
        self.run_load();self.assertEqual(len(Client.chunks),5)
        self.assertEqual(sum('\\copy ' in sql for c in Client.instances for sql in c.sql),5)

    def test_local_progress_failure_does_not_replace_sql_journal(self):
        atomic=N.M.atomic_json
        def fail(root,name,*a,**kw):
            if name=='progress.json':raise OSError('progress unavailable')
            return atomic(root,name,*a,**kw)
        with patch.object(N.M,'atomic_json',side_effect=fail),self.assertRaisesRegex(OSError,'progress unavailable'):self.run_load()
        self.assertEqual(len(Client.chunks),1)
        self.run_load();self.assertEqual(len(Client.chunks),5)

    def test_final_receipt_failure_is_recovered_from_complete_database(self):
        atomic=N.M.atomic_json
        def fail(root,name,*a,**kw):
            if name=='complete.json' and Path(root).resolve()==self.out.resolve():raise OSError('receipt unavailable')
            return atomic(root,name,*a,**kw)
        with patch.object(N.M,'atomic_json',side_effect=fail),self.assertRaisesRegex(OSError,'receipt unavailable'):self.run_load()
        self.assertEqual(Client.phase,'complete');before=sum('\\copy ' in s for c in Client.instances for s in c.sql)
        self.run_load();self.assertEqual(sum('\\copy ' in s for c in Client.instances for s in c.sql),before)

    def test_source_drift_refuses_before_client(self):
        (self.source/'chunk-000000.csv').write_bytes(b'changed')
        with self.assertRaises(ValueError):self.run_load()
        self.assertEqual(Client.instances,[])

    def test_code_drift_and_request_corruption_refuse_before_client(self):
        with patch.object(N,'SOURCE_SHA','0'*64),self.assertRaisesRegex(ValueError,'changed after import'):self.run_load()
        request=dict(self.request,schema='cdm_incremental_'+'0'*16);N.M.atomic_json(self.out,'request.json',request)
        with self.assertRaisesRegex(ValueError,'request identity'):self.run_load()
        self.assertEqual(Client.instances,[])

    def test_stop_file_and_lock_refuse_before_database(self):
        (self.out/'STOP').touch()
        with self.assertRaises(N.M.Stopped):self.run_load()
        (self.out/'STOP').unlink()
        with N.M.locked(self.out),self.assertRaises(BlockingIOError):self.run_load()
        self.assertEqual(Client.instances,[])

    def test_cleanup_uses_saved_request_without_original_inputs(self):
        self.run_load();self.reg.rename(self.home/'archived-registration')
        self.assertEqual(N.drop(self.out,self.home/'state')['status'],'dropped')
        with self.assertRaisesRegex(ValueError,'cleaned up'):self.run_load()
        self.assertEqual(N.drop(self.out,self.home/'state')['status'],'absent')

    def test_missing_completed_schema_is_not_recreated(self):
        self.run_load();Client.exists=False
        with self.assertRaisesRegex(ValueError,'Completed schema is missing'):self.run_load()
        self.assertEqual(Client.instances[-1].sql,[])

    def test_invalid_limits_and_output_preserve_request(self):
        before=(self.out/'request.json').read_bytes()
        for limit in [0,129,True,1.5]:
            with self.subTest(limit=limit),self.assertRaises(ValueError):self.run_load(max_chunks=limit)
        with self.assertRaises(FileExistsError):N.prepare(self.reg,self.out)
        with self.assertRaises(ValueError):N.prepare(self.reg,self.source/'nested')
        self.assertEqual((self.out/'request.json').read_bytes(),before);self.assertEqual(Client.instances,[])

    def test_journal_response_requires_exact_contiguous_request_prefix(self):
        for state in [None,{},dict(phase='loading',chunks=[self.request['chunks'][1]]),dict(phase='complete',chunks=[])]:
            client=Client();client.run=lambda sql:subprocess.CompletedProcess([],0,json.dumps(state),'')
            with self.subTest(state=state),self.assertRaises(ValueError):N.execute(client,'sql',self.request)

    def test_chunk_sql_stages_checks_and_receipt_inside_same_transaction(self):
        plan=N.M.load_plan(self.source);sql=N.chunk_script(self.request,plan,Path('/private/frozen'),0)
        self.assertTrue(sql.startswith('BEGIN;'));self.assertTrue(sql.endswith('COMMIT;'))
        for text in ['Not the local marked fixture','pg_advisory_xact_lock','Incremental namespace owner/marker differs','Incremental journal is not a prefix','Chunk is not next in prefix']:
            self.assertLess(sql.index(text),sql.index('\\copy '))
        self.assertLess(sql.index('\\copy '),sql.index('Loaded selection facts differ'))
        self.assertLess(sql.index('Loaded selection facts differ'),sql.index('INSERT INTO "cdm_incremental_'))
        self.assertNotIn('FROM "'+self.request['schema']+'"."measurement"',sql)
        self.assertIn('FROM "pg_temp"."achillesnext_chunk"',sql)
        self.assertNotIn('GRANT',sql);self.assertIn('\\if :achillesnext_copy',sql)

    def test_finalize_checks_all_tables_before_select_grants(self):
        plan=N.M.load_plan(self.source);complete=N.M.read_json(self.source/'complete.json')
        sql=N.finish_script(self.request,plan,complete)
        self.assertEqual(sql.count('Loaded selection facts differ'),len(N.S.Source('S2','5.5').columns))
        self.assertLess(sql.rindex('Loaded selection facts differ'),sql.index('GRANT USAGE'))
        self.assertIn('Chunks still missing',sql);self.assertIn("'\"complete\"'::jsonb",sql)

    def test_cleanup_sql_rechecks_owner_marker_under_transaction_lock(self):
        N.drop(self.out,self.home/'state');sql=Client.instances[-1].sql[-1]
        self.assertLess(sql.index('pg_advisory_xact_lock'),sql.index('DROP SCHEMA'))
        self.assertIn('Selection cleanup owner/marker changed',sql);self.assertIn(self.request['marker'],sql)

    def test_cleanup_stop_file_refuses_before_client(self):
        (self.out/'STOP').touch()
        with self.assertRaisesRegex(N.M.Stopped,'operator_stop_file') as error:
            N.drop(self.out,self.home/'state')
        self.assertEqual(error.exception.code,3)
        self.assertEqual(Client.instances,[])
        self.assertFalse((self.out/'dropped.json').exists())

    def test_cleanup_keeps_stop_guard_after_client_creation(self):
        def check(client):
            (self.out/'STOP').touch();client.guard.check()
        class GuardedClient(Client):
            def __init__(self,state,guard,*args):super().__init__();self.guard=guard
        with patch.object(N.L,'Client',GuardedClient),patch.object(N.L,'check_target',side_effect=check):
            with self.assertRaisesRegex(N.M.Stopped,'operator_stop_file'):
                N.drop(self.out,self.home/'state')
        self.assertFalse((self.out/'dropped.json').exists())

    def test_non_object_request_is_refused_without_cleanup_connection(self):
        for value in [None,[],True,0,1.5,'text']:
            N.M.atomic_json(self.out,'request.json',value)
            with self.subTest(value=value),self.assertRaisesRegex(ValueError,'Invalid incremental request'):
                N.drop(self.out,self.home/'state')
        self.assertEqual(Client.instances,[])

    def test_preparation_rejects_missing_witness_and_forwards_stop(self):
        plain=self.home/'plain'
        N.R.register(plain,'plain','S2','5.5',{r:str(self.home) for r in N.R.ROLES})
        with self.assertRaisesRegex(ValueError,'bounded witness'):N.prepare(plain,self.home/'no-witness')
        with self.assertRaises(N.M.Stopped):N.prepare(self.reg,self.home/'stopped',stop=lambda:'SIGTERM')
        self.assertFalse((self.home/'no-witness').exists());self.assertFalse((self.home/'stopped').exists())
        self.assertEqual(Client.instances,[])


if __name__=='__main__':unittest.main()
