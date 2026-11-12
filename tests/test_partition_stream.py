"""Selection bounds, frozen identities, work retention and pre-connection guards."""
import io
import json
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


@unittest.skipUnless(T.M.fcntl is not None,'POSIX stream locks')
class StreamTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);self.home=Path(temporary.name)
        self.reg=self.home/'registration';self.schedule=self.home/'schedule';self.out=self.home/'stream'
        T.R.register(self.reg,'stream-test','S2','5.5',{r:str(self.home) for r in T.R.ROLES})
        self.plan=T.P.create(self.reg,self.schedule,rows_per_partition=3,chunk_rows=2)
        self.first=next(t['first_partition'] for t in self.plan['tables'] if t['table']=='measurement')+32

    def prepare(self,**options):return T.prepare(self.schedule,self.out,self.first,3,**options)

    def test_request_has_constant_size_range_without_work_list(self):
        req=self.prepare();self.assertEqual(req['first'],self.first);self.assertEqual(req['count'],3)
        self.assertNotIn('units',req);self.assertNotIn('chunks',req);self.assertFalse(req['qualifying'])
        self.assertEqual(req,T.saved_request(self.out))
        self.assertFalse((self.out/'active').exists())

    def test_range_and_resource_controls_are_checked_before_creation(self):
        for first,count in [(-1,1),(False,1),(0,True),(0,0),(self.plan['partition_count'],1),(0,self.plan['partition_count'])]:
            with self.subTest(first=first,count=count),self.assertRaises(ValueError):T.prepare(self.schedule,self.out,first,count)
            self.assertFalse(self.out.exists())
        with self.assertRaises(ValueError):self.prepare(database_bytes=True)

    def test_output_cannot_poison_schedule_registration_or_witness(self):
        alias=self.home/'alias';alias.symlink_to(self.schedule,target_is_directory=True)
        for out in [self.schedule,self.schedule/'child',self.home,self.reg/'child',alias/'child']:
            with self.subTest(out=out),self.assertRaises(ValueError):T.prepare(self.schedule,out,self.first,1)
        self.assertEqual(T.P.verify(self.schedule),self.plan)

    def test_stop_before_prepare_or_database_connection(self):
        with self.assertRaises(T.M.Stopped):self.prepare(stop=lambda:'SIGTERM')
        self.assertFalse(self.out.exists());self.prepare();(self.out/'STOP').touch()
        with patch.object(T.L,'Client',side_effect=AssertionError('no connection')):
            with self.assertRaisesRegex(T.M.Stopped,'operator_stop_file'):T.run(self.out,self.home)
            with self.assertRaisesRegex(T.M.Stopped,'operator_stop_file'):T.drop(self.out,self.home)

    def test_code_and_schedule_drift_refuse_before_connection(self):
        self.prepare()
        with patch.object(T,'SOURCE_SHA','0'*64),patch.object(T.L,'Client',side_effect=AssertionError('no connection')):
            with self.assertRaisesRegex(ValueError,'changed after import'):T.run(self.out,self.home)
        original=(self.schedule/'partition-plan.json').read_bytes()
        (self.schedule/'partition-plan.json').write_bytes(original+b' ')
        with patch.object(T.L,'Client',side_effect=AssertionError('no connection')),self.assertRaises(ValueError):T.run(self.out,self.home)

    def test_preparation_rejects_reuse_and_nonobject_request(self):
        self.prepare()
        with self.assertRaises(FileExistsError):self.prepare()
        T.M.atomic_json(self.out,'request.json',[])
        with self.assertRaisesRegex(ValueError,'Invalid stream request'):T.saved_request(self.out)

    def test_owned_child_preparation_recovers_incomplete_attempt(self):
        self.prepare();guard=T.Guard(self.out);pending=self.out/'work.creating';pending.mkdir();(pending/'partial').write_bytes(b'partial')
        def create(path):path.mkdir();(path/'ready').write_bytes(b'ready')
        final=T.child(self.out,'work',create,guard)
        self.assertEqual((final/'ready').read_bytes(),b'ready');self.assertFalse(pending.exists())
        self.assertEqual(T.child(self.out,'work',lambda p:self.fail('do not recreate'),guard),final)

    def test_prune_refuses_external_aliases_and_preserves_external_bytes(self):
        self.prepare();outside=self.home/'external';outside.write_bytes(b'keep');active=self.out/'active';active.mkdir()
        (active/'alias').symlink_to(outside)
        with self.assertRaises(ValueError):T.prune(active,T.Guard(self.out))
        self.assertEqual(outside.read_bytes(),b'keep');self.assertTrue((active/'alias').is_symlink())

    def test_current_partition_can_be_resumed_without_retaining_old_files(self):
        self.prepare();active=self.out/'active';active.mkdir();guard=T.Guard(self.out)
        source,inventory,record=T.source_ready(active,self.plan,self.first,guard)
        self.assertEqual(record['selected_rows'],3)
        before=(source/'complete.json').read_bytes()
        self.assertEqual(T.source_ready(active,self.plan,self.first,guard)[2],record)
        self.assertEqual((source/'complete.json').read_bytes(),before)
        T.prune(active,guard);self.assertFalse(active.exists())
        self.assertEqual(T.P.verify(self.schedule),self.plan)

    def test_invalid_invocation_limits_and_cli_prepare(self):
        self.prepare()
        for options in [dict(max_partitions=True),dict(max_partitions=0),dict(max_steps=129)]:
            with self.subTest(options=options),self.assertRaises(ValueError):T.run(self.out,self.home,**options)
        other=self.home/'cli'
        with patch.object(sys,'argv',['stream','prepare','--schedule-dir',str(self.schedule),'--output-dir',str(other),'--first',str(self.first),'--count','2']),patch.object(sys,'stdout',new_callable=io.StringIO) as out:
            self.assertEqual(T.main(),0)
        self.assertEqual(json.loads(out.getvalue())['count'],2)


if __name__=='__main__':unittest.main()
