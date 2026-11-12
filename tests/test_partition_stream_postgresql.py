"""Opt-in stream restart, SQL rollback, audit and reader-publication proof.

Uses only the provisioned, pinned, marked local fixture sandbox. No provisioning
or global grant changes. Set ACHILLES_NEXT_TEST_STATE to its private service state.
"""
from collections import Counter
import csv
import io
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
    import partition_stream as T
finally:sys.path[:]=saved


@unittest.skipUnless(os.environ.get('ACHILLES_NEXT_TEST_STATE'),'Set ACHILLES_NEXT_TEST_STATE for marked PostgreSQL integration')
class StreamPostgresTests(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory(prefix='achillesnext-stream-test-');self.addCleanup(temp.cleanup);self.home=Path(temp.name)
        self.state=Path(os.environ['ACHILLES_NEXT_TEST_STATE']).resolve()
        self.pg=T.L.Client(self.state,T.L.Guard([self.home]),'achillesnext-stream-test');T.L.check_target(self.pg)

    def selection(self,version='5.5',name='job',size=3,count=3):
        root=self.home/name;root.mkdir();reg=root/'registration';schedule=root/'schedule';out=root/'stream'
        T.R.register(reg,'stream-postgres-test','S2',version,{r:str(root) for r in T.R.ROLES})
        plan=T.P.create(reg,schedule,rows_per_partition=size,chunk_rows=min(size,2))
        first=next(t['first_partition'] for t in plan['tables'] if t['table']=='measurement')+96//size
        req=T.prepare(schedule,out,first,count)
        def cleanup():
            (out/'STOP').unlink(missing_ok=True);T.drop(out,self.state)
            self.assertEqual(self.pg.value('SELECT count(*) FROM pg_namespace WHERE nspname='+T.F.literal(req['schema'])),'0')
        self.addCleanup(cleanup)
        return out,req,plan

    def complete(self,out):
        for _ in range(100):
            value=T.run(out,self.state,max_partitions=1,max_steps=128)
            self.assertFalse((out/'active').exists())
            if value['status']=='complete':return value
        self.fail('stream did not complete')

    def rows(self,req,role='owner'):
        return self.pg.rows('SELECT * FROM '+T.table(req,'measurement'),role=role)

    def denied(self,req):
        result=self.pg.run('SELECT count(*) FROM '+T.table(req,'measurement'),role='runner',allow_failure=True)
        self.assertNotEqual(result.returncode,0);self.assertIn('permission denied',result.stderr)

    def state_value(self,req):return self.pg.rows('SELECT document FROM '+T.table(req,T.HEADER))[0]['document']

    def test_three_versions_exact_bags_duplicate_boundary_and_bounded_retention(self):
        for version in T.F.VERSIONS:
            with self.subTest(version=version):
                out,req,plan=self.selection(version,name=version)
                first=T.run(out,self.state,max_steps=128);self.assertEqual(first['phase'],'loading');self.denied(req)
                self.assertFalse((out/'active').exists());self.assertFalse((out/'active.json').exists())
                result=self.complete(out);self.assertEqual(result['rows'],9);self.assertFalse(result['qualifying'])
                wanted=Counter();source=T.S.Source('S2',version)
                for index in range(req['first'],req['first']+req['count']):
                    window=T.P.partition(plan,index)[0];stream=io.BytesIO();T.S.render(source,window['table'],window['start'],window['rows'],stream)
                    wanted.update(T.S.BASE.canonical({k:None if v=='\\N' else v for k,v in row.items()}) for row in csv.DictReader(io.StringIO(stream.getvalue().decode())))
                cols=source.columns['measurement'];select=','.join(T.F.identifier(c['name'])+'::text AS '+T.F.identifier(c['name']) for c in cols)
                actual=Counter(T.S.BASE.canonical(r) for r in self.pg.rows('SELECT '+select+' FROM '+T.table(req,'measurement'),role='runner'))
                self.assertEqual(actual,wanted);self.assertEqual(sum(actual.values())-len(actual),1)
                self.assertEqual(self.state_value(req)['phase'],'complete');self.assertEqual(len(self.rows(req)),9)
                self.assertEqual(self.pg.value('SELECT has_table_privilege('+T.F.literal(T.F.RUNNER)+','+T.F.literal(req['schema']+'.measurement')+",'INSERT,UPDATE,DELETE,TRUNCATE')"),'f')
                self.assertEqual(self.complete(out),result)

    def test_lost_partition_commit_response_adopts_sql_and_reducer_without_recopy(self):
        out,req,plan=self.selection();execute=T.execute;lost=[False]
        def lose(client,sql,request):
            result=execute(client,sql,request)
            if 'INSERT INTO '+T.table(req,T.PARTS) in sql and not lost[0]:lost[0]=True;raise RuntimeError('lost partition response')
            return result
        with patch.object(T,'execute',side_effect=lose),self.assertRaisesRegex(RuntimeError,'lost partition response'):T.run(out,self.state)
        self.assertEqual(self.state_value(req)['next_partition'],req['first']+1);self.assertEqual(len(self.rows(req)),3)
        self.assertTrue((out/'active/source').exists());source_ready=T.source_ready
        def never_repeat(active,plan,index,guard):
            self.assertNotEqual(index,req['first']);return source_ready(active,plan,index,guard)
        with patch.object(T,'source_ready',side_effect=never_repeat):self.complete(out)
        self.assertEqual(len(self.rows(req)),9)

    def test_chunk_validation_and_final_grants_rollback_preserve_previous_publication(self):
        previous,old,_=self.selection(name='previous');self.complete(previous)
        old_rows=self.rows(old,role='runner');out,req,_=self.selection();script=T.partition_script
        def bad_facts(*args):return script(*args).replace("'rows',count(*)","'rows',count(*)+1")
        with patch.object(T,'partition_script',side_effect=bad_facts),self.assertRaises(RuntimeError):T.run(out,self.state)
        self.assertEqual(len(self.rows(req)),0);self.assertEqual(self.state_value(req)['next_partition'],req['first']);self.denied(req)
        self.assertEqual(self.rows(old,role='runner'),old_rows)
        finish=T.finish_script
        def fail_grants(*args):return finish(*args).replace('COMMIT;','SELECT 1/0;\nCOMMIT;')
        with patch.object(T,'finish_script',side_effect=fail_grants),self.assertRaises(RuntimeError):self.complete(out)
        self.assertEqual(len(self.rows(req)),9);self.assertEqual(self.state_value(req)['phase'],'loading');self.denied(req)
        self.assertFalse((out/'complete.json').exists());self.assertEqual(self.rows(old,role='runner'),old_rows)
        self.complete(out);self.assertEqual(self.rows(old,role='runner'),old_rows)

    def test_audit_corruption_and_database_journal_drift_block_reader_grants(self):
        for mutation in ['inventory','journal']:
            with self.subTest(mutation=mutation):
                out,req,_=self.selection(name=mutation);T.run(out,self.state)
                if mutation=='inventory':
                    import sqlite3
                    from contextlib import closing
                    with closing(sqlite3.connect(out/'reduction/inventory.sqlite')) as db,db:db.execute('UPDATE row_bag SET n=n+1')
                else:self.pg.run('UPDATE '+T.table(req,T.PARTS)+" SET manifest=jsonb_set(manifest,'{source_csv_bytes}','1'::jsonb)")
                with self.assertRaises(ValueError):self.complete(out)
                self.denied(req);self.assertFalse((out/'complete.json').exists())

    def test_cleanup_interruption_and_receipt_export_failure_resume(self):
        out,req,_=self.selection();prune=T.prune;lost=[False]
        def fail_cleanup(path,guard):
            if path.name=='active' and not lost[0]:
                lost[0]=True
                (path/'source/chunk-000000.csv').unlink();raise OSError('partial prune')
            return prune(path,guard)
        with patch.object(T,'prune',side_effect=fail_cleanup),self.assertRaisesRegex(OSError,'partial prune'):T.run(out,self.state)
        self.assertEqual(len(self.rows(req)),3)
        atomic=T.M.atomic_json
        def fail_export(root,name,*args,**kwargs):
            if root==out and name=='complete.json':raise OSError('receipt export failed')
            return atomic(root,name,*args,**kwargs)
        with patch.object(T.M,'atomic_json',side_effect=fail_export),self.assertRaisesRegex(OSError,'receipt export failed'):self.complete(out)
        self.assertEqual(self.state_value(req)['phase'],'complete');self.assertEqual(len(self.rows(req,role='runner')),9)
        self.complete(out);self.assertEqual(len(self.rows(req)),9)

    def test_stop_and_missing_candidate_refuse_without_recreation(self):
        out,req,_=self.selection();T.run(out,self.state);before=self.state_value(req)
        (out/'STOP').touch()
        with self.assertRaises(T.M.Stopped):T.run(out,self.state)
        with self.assertRaises(T.M.Stopped):T.drop(out,self.state)
        self.assertEqual(self.state_value(req),before);(out/'STOP').unlink()
        self.pg.run('DROP SCHEMA '+T.F.identifier(req['schema'])+' CASCADE')
        with self.assertRaisesRegex(ValueError,'schema is missing'):T.run(out,self.state)
        self.assertEqual(self.pg.value('SELECT count(*) FROM pg_namespace WHERE nspname='+T.F.literal(req['schema'])),'0')

    def test_audited_reduction_stays_locked_through_finalization(self):
        out,req,_=self.selection();step=T.journal_step;attempts=[]
        def verify_lock(*args):
            with self.assertRaises(BlockingIOError),T.M.locked(out/'reduction'):pass
            attempts.append(True);return step(*args)
        with patch.object(T,'journal_step',side_effect=verify_lock):self.complete(out)
        self.assertTrue(attempts)

    def test_compact_cross_domain_selection_includes_empty_tables(self):
        # Explicitly test-only source dimensions: not a real S1/S2 execution.
        init=T.S.Source.__init__
        def compact(source,*args,**kwargs):
            init(source,*args,**kwargs);source.counts={t:min(n,2) for t,n in source.counts.items()}
        root=self.home/'compact';root.mkdir();reg=root/'registration';schedule=root/'schedule';out=root/'stream'
        with patch.object(T.S.Source,'__init__',compact):
            T.R.register(reg,'compact-stream','S2','5.5',{r:str(root) for r in T.R.ROLES})
            plan=T.P.create(reg,schedule,rows_per_partition=3,chunk_rows=2)
            req=T.prepare(schedule,out,0,plan['partition_count']-1)
            self.addCleanup(lambda:T.drop(out,self.state))
            result=self.complete(out);wanted=0
            for index in range(req['count']):
                window=T.P.partition(plan,index)[0];wanted+=window['rows']
                self.assertEqual(self.pg.value('SELECT count(*) FROM '+T.table(req,window['table']),role='runner'),str(window['rows']))
            self.assertEqual(result['rows'],wanted);self.assertFalse(result['full_tier_generated'])

    def admitted(self,name='whole',wrong_target=False):
        # Reference capacities/host identities are simulated, not allocated.
        # PostgreSQL, source witnesses, COPY, journals and audit remain real.
        import test_source_execution_resources as support
        root=self.home/name;root.mkdir();source=root/'witness';inventory=root/'witness-inventory';reg=root/'registration';schedule=root/'schedule';out=root/'stream';resources=root/'resources'
        T.M.prepare(source,'S2','5.5',[dict(table='person',start=0,rows=2)],chunk_rows=2);T.M.run(source);T.I.collect(source,inventory)
        T.R.register(reg,'whole-contract-self-test','S2','5.5',{r:str(root) for r in T.R.ROLES},source,inventory)
        plan=T.P.create(reg,schedule,rows_per_partition=3,chunk_rows=2)
        target=T.Z.target_identity(self.pg)
        if wrong_target:target=dict(target,database_oid=target['database_oid']+1)
        config,observed,worker=support.reference_fixture(root,plan['partition_plan_sha256'],'S2',out,target)
        config_file=root/'allocation.json';config_file.write_bytes(T.S.BASE.canonical(config))
        host=patch.object(T.Z,'host_observation',return_value=observed);host.start();self.addCleanup(host.stop)
        identity=patch.object(T.Z,'worker_identity',return_value=worker);identity.start();self.addCleanup(identity.stop)
        T.Z.register(config_file,resources);req=T.prepare(schedule,out,0,plan['partition_count'],resource_dir=resources)
        self.addCleanup(lambda:T.drop(out,self.state))
        return out,req,plan,resources

    def complete_admitted(self,out,resources):
        for _ in range(100):
            T.Z.renew(resources)
            value=T.run(out,self.state,max_partitions=1,max_steps=128)
            if value['status']=='complete':return value
        self.fail('admitted compact stream did not complete')

    def compact_source(self):
        init=T.S.Source.__init__
        def compact(source,*args,**kwargs):
            init(source,*args,**kwargs);source.counts={t:min(n,2) for t,n in source.counts.items()}
        return patch.object(T.S.Source,'__init__',compact)

    def test_whole_source_contract_audits_every_partition_and_table(self):
        with self.compact_source():
            out,req,plan,resources=self.admitted()
            result=self.complete_admitted(out,resources)
            self.assertEqual(result['coverage'],'whole_source');self.assertTrue(result['whole_source_loaded']);self.assertTrue(result['full_tier_generated']);self.assertFalse(result['qualifying'])
            self.assertEqual(result['partitions'],plan['partition_count']);self.assertEqual(result['rows'],plan['total_rows'])
            audit=T.V.run(out/'audit',verify_only=True);self.assertEqual(audit['scope'],'whole_source');self.assertTrue(audit['whole_source_audited'])
            for name,n in plan['source']['table_rows'].items():self.assertEqual(self.pg.value('SELECT count(*) FROM '+T.table(req,name),role='runner'),str(n))
            self.assertFalse(list(out.glob('**/*.csv')));self.assertFalse((out/'active').exists())
        # Restoring the true source dimensions invalidates this explicit stand-in.
        with self.assertRaises(ValueError):T.run(out,self.state)

    def test_expired_admission_and_database_identity_drift_precede_mutation(self):
        with self.compact_source():
            for reason in ['expired','database']:
                with self.subTest(reason=reason):
                    out,req,_,resources=self.admitted(name=reason,wrong_target=reason=='database')
                    if reason=='expired':
                        lease=T.M.read_json(resources/'lease.json');lease['valid_until']=T.Z.stamp(T.Z.now()-1);T.M.atomic_json(resources,'lease.json',lease)
                        with patch.object(T.L,'Client',side_effect=AssertionError('must refuse before connecting')),self.assertRaises(T.M.Stopped):T.run(out,self.state)
                    else:
                        with self.assertRaisesRegex(ValueError,'database identity/settings changed'):T.run(out,self.state)
                    self.assertFalse((out/'reduction').exists())
                    self.assertEqual(self.pg.value('SELECT count(*) FROM pg_namespace WHERE nspname='+T.F.literal(req['schema'])),'0')

    def test_resource_stop_during_sql_rolls_back_then_resumes_same_prefix(self):
        import threading,time
        with self.compact_source():
            out,req,_,resources=self.admitted();T.run(out,self.state,max_partitions=1);before=self.state_value(req)
            script=T.partition_script;found=threading.Event();done=threading.Event();errors=[]
            def slow(*args):return script(*args).replace('COMMIT;','SELECT pg_sleep(20);\nCOMMIT;')
            def revoke_on_sleep():
                try:
                    deadline=time.monotonic()+10
                    while time.monotonic()<deadline and not done.is_set():
                        rows=self.pg.rows("SELECT pid FROM pg_stat_activity WHERE application_name="+T.F.literal('achillesnext-stream-'+req['schema'][-16:])+" AND wait_event='PgSleep'")
                        if rows:(resources/'STOP').touch();found.set();return
                        time.sleep(.05)
                except Exception as error:errors.append(error)
            thread=threading.Thread(target=revoke_on_sleep);thread.start()
            try:
                T.Z.renew(resources)
                with patch.object(T,'partition_script',side_effect=slow),self.assertRaisesRegex(T.M.Stopped,'resource_operator_stop_file'):T.run(out,self.state)
            finally:done.set();thread.join(timeout=12)
            self.assertFalse(thread.is_alive());self.assertFalse(errors);self.assertTrue(found.is_set())
            self.assertEqual(self.state_value(req),before);self.denied(req);self.assertFalse((out/'complete.json').exists())
            (resources/'STOP').unlink();result=self.complete_admitted(out,resources);self.assertTrue(result['whole_source_loaded'])


if __name__=='__main__':unittest.main()
