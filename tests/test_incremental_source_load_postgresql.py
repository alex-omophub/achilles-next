"""Opt-in real PostgreSQL regressions, restricted to the marked local sandbox.

Set ACHILLES_NEXT_TEST_STATE to provisioned fixture credentials. No provisioning,
fixture reset or global grant changes are performed by these tests.
"""
from collections import Counter
import csv
import os
from pathlib import Path
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


@unittest.skipUnless(os.environ.get('ACHILLES_NEXT_TEST_STATE'),'Set ACHILLES_NEXT_TEST_STATE for marked PostgreSQL integration')
class IncrementalPostgresTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory(prefix='achillesnext-incremental-test-')
        self.addCleanup(temporary.cleanup);self.home=Path(temporary.name)
        self.state=Path(os.environ['ACHILLES_NEXT_TEST_STATE']).resolve()
        self.pg=N.L.Client(self.state,N.L.Guard([self.home]),'achillesnext-incremental-test')
        N.L.check_target(self.pg)  # Refuse foreign/remote/unpinned targets before DDL.

    def selection(self,version='5.5'):
        root=self.home/version;root.mkdir();source=root/'source';inventory=root/'inventory';reg=root/'registration';out=root/'load'
        N.M.prepare(source,'S2',version,[dict(table='measurement',start=95,rows=12)],chunk_rows=4)
        N.M.run(source);N.I.collect(source,inventory)
        N.R.register(reg,'incremental-postgres-test','S2',version,{r:str(root) for r in N.R.ROLES},source,inventory)
        request=N.prepare(reg,out)
        def cleanup():
            (out/'STOP').unlink(missing_ok=True)
            N.drop(out,self.state)
            self.assertEqual(self.pg.value('SELECT count(*) FROM pg_namespace WHERE nspname='+N.F.literal(request['schema'])),'0')
        self.addCleanup(cleanup)
        return out,source,request

    def journal(self,request):
        return self.pg.rows('SELECT chunk_no,manifest FROM '+N.ledger(request)+' ORDER BY chunk_no')

    def rows(self,request):
        return int(self.pg.value('SELECT count(*) FROM '+N.F.identifier(request['schema'])+'.measurement'))

    def denied(self,request):
        name=request['schema']
        self.assertEqual(self.pg.value('SELECT has_schema_privilege('+N.F.literal(N.F.RUNNER)+','+N.F.literal(name)+",'USAGE')"),'f')
        result=self.pg.run('SELECT count(*) FROM '+N.F.identifier(name)+'.measurement',role='runner',allow_failure=True)
        self.assertNotEqual(result.returncode,0);self.assertIn('permission denied',result.stderr)

    def prefix(self,out):
        with self.assertRaisesRegex(N.M.Stopped,'invocation_chunk_limit'):N.run(out,self.state,max_chunks=1)

    def test_failed_validation_rolls_back_chunk_and_final_grants(self):
        for version in N.F.VERSIONS:
            with self.subTest(version=version):
                out,source,request=self.selection(version);self.prefix(out)
                before=self.journal(request);self.assertEqual(self.rows(request),4);self.denied(request)
                original=N.chunk_script
                def bad_facts(*args):
                    # Exercise the actual aggregate assertion after staging COPY.
                    return original(*args).replace("'rows',count(*)","'rows',count(*)+1")
                with patch.object(N,'chunk_script',side_effect=bad_facts),self.assertRaises(RuntimeError):N.run(out,self.state)
                self.assertIn('Loaded selection facts differ',N.M.read_json(out/'attempt.json')['database_error'])
                self.assertEqual(self.journal(request),before);self.assertEqual(self.rows(request),4)
                self.denied(request);self.assertFalse((out/'complete.json').exists())

                finish=N.finish_script
                def fail_after_grants(*args):return finish(*args).replace('COMMIT;','SELECT 1/0;\nCOMMIT;')
                with patch.object(N,'finish_script',side_effect=fail_after_grants),self.assertRaises(RuntimeError):N.run(out,self.state)
                self.assertEqual(len(self.journal(request)),4);self.assertEqual(self.rows(request),12)
                self.assertEqual(self.journal(request)[0]['manifest']['phase'],'loading')
                self.denied(request);self.assertFalse((out/'complete.json').exists())

                result=N.run(out,self.state);self.assertEqual(result['schema'],request['schema'])
                self.assertEqual(self.journal(request)[0]['manifest']['phase'],'complete')
                self.assertEqual(self.pg.value('SELECT count(*) FROM '+N.F.identifier(request['schema'])+'.measurement',role='runner'),'12')
                self.assertEqual(self.pg.value('SELECT has_table_privilege('+N.F.literal(N.F.RUNNER)+','+N.F.literal(request['schema']+'.measurement')+",'INSERT,UPDATE,DELETE,TRUNCATE')"),'f')
                wanted=Counter()
                for chunk in request['chunks']:
                    with (source/chunk['file']).open() as stream:
                        wanted.update(N.S.BASE.canonical({k:None if v=='\\N' else v for k,v in row.items()}) for row in csv.DictReader(stream))
                columns=N.S.Source('S2',version).columns['measurement']
                select=','.join(N.F.identifier(c['name'])+'::text AS '+N.F.identifier(c['name']) for c in columns)
                actual=Counter(N.S.BASE.canonical(row) for row in self.pg.rows('SELECT '+select+' FROM '+N.F.identifier(request['schema'])+'.measurement'))
                self.assertEqual(actual,wanted);self.assertEqual(sum(actual.values())-len(actual),1)
                N.run(out,self.state);self.assertEqual(self.rows(request),12)

    def test_cleanup_stop_file_preserves_partial_candidate(self):
        out,_,request=self.selection();self.prefix(out);before=self.journal(request)
        (out/'STOP').touch()
        with self.assertRaisesRegex(N.M.Stopped,'operator_stop_file'):N.drop(out,self.state)
        self.assertEqual(self.journal(request),before);self.assertEqual(self.rows(request),4)
        self.assertFalse((out/'dropped.json').exists())
        (out/'STOP').unlink();self.assertEqual(N.drop(out,self.state)['status'],'dropped')



if __name__=='__main__':unittest.main()
