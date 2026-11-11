"""Selected partition provenance, crash adoption and bounded restart controls."""
import copy
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
_saved=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    import partition_execution as E
finally:sys.path[:]=_saved


@unittest.skipUnless(E.M.fcntl is not None,'POSIX partition execution')
class ExecutionTest(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);self.home=Path(temp.name)
        self.registration=self.home/'registration';self.schedule=self.home/'schedule';self.output=self.home/'execution'
        E.R.register(self.registration,'execution-test','S2','5.5',{r:str(self.home) for r in E.R.ROLES})
        self.plan=E.P.create(self.registration,self.schedule,rows_per_partition=20,chunk_rows=5)
        by_table={t['table']:t for t in self.plan['tables']}
        self.measurement=by_table['measurement']['first_partition']
        self.empty=next(t['first_partition'] for t in self.plan['tables'] if not t['rows'])
        self.care=by_table['care_site']['first_partition']

    def prepare(self,indices=None):return E.prepare(self.schedule,self.output,indices or [self.measurement])

    def state(self):return E.M.read_json(self.output/'checkpoint.json')

    def hashes(self,root):
        return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}

    def test_pipeline_retains_all_three_parent_unit_and_materialization_identities(self):
        before=self.hashes(self.schedule);req=self.prepare([self.measurement,self.empty,self.care])
        result=E.run(self.output);self.assertEqual(E.verify(self.output),result)
        self.assertEqual(result['selected_rows'],22);self.assertFalse(result['full_tier_generated']);self.assertFalse(result['qualifying'])
        self.assertEqual(before,self.hashes(self.schedule));self.assertEqual(result['partition_plan_sha256'],self.plan['partition_plan_sha256'])
        for unit,saved in zip(req['units'],result['units']):
            self.assertEqual(saved['partition'],unit['partition'])
            self.assertEqual(saved['materialization_plan_sha256'],unit['materialization_plan_sha256'])
            self.assertEqual(saved['source_binding']['plan_sha256'],unit['materialization_plan_sha256'])
        before=self.hashes(self.output)
        with patch.object(E.M,'run',side_effect=AssertionError('completed source must not regenerate')),patch.object(E.I,'collect',side_effect=AssertionError('completed inventory must not rebuild')):
            self.assertEqual(E.run(self.output),result)
        self.assertEqual(before,self.hashes(self.output))

    def test_selection_limits_refuse_before_writing(self):
        for indices in [[],[True],[self.measurement]*2,list(range(9)),[-1],[self.plan['partition_count']]]:
            with self.subTest(indices=indices),self.assertRaises(ValueError):E.prepare(self.schedule,self.output,indices)
            self.assertFalse(self.output.exists())
        large=self.home/'large';E.P.create(self.registration,large)
        m=next(t['first_partition'] for t in E.P.verify(large)['tables'] if t['table']=='measurement')
        with self.assertRaisesRegex(ValueError,'total rows'):E.prepare(large,self.output,[m,m+1])
        self.assertFalse(self.output.exists())
        many=self.home/'many-chunks';E.P.create(self.registration,many,rows_per_partition=100,chunk_rows=1)
        m=next(t['first_partition'] for t in E.P.verify(many)['tables'] if t['table']=='measurement')
        with self.assertRaisesRegex(ValueError,'128 chunks'):E.prepare(many,self.output,[m,m+1])
        self.assertFalse(self.output.exists())

    def test_unit_budget_stops_then_resumes_without_rewriting_completed_unit(self):
        req=self.prepare([self.measurement,self.care])
        with self.assertRaisesRegex(E.M.Stopped,'unit_limit'):E.run(self.output,max_units=1)
        first=self.output/req['units'][0]['directory'];before=self.hashes(first)
        self.assertIsNotNone(self.state()['units'][0]['result']);self.assertFalse((self.output/'complete.json').exists())
        result=E.run(self.output);self.assertEqual(result['selected_rows'],22);self.assertEqual(before,self.hashes(first))

    def test_materializer_checkpoint_survives_interrupted_generation(self):
        self.prepare();original=E.M.atomic_json;stopped=[False]
        def stop_after_chunk(root,name,value,exclusive=False):
            result=original(root,name,value,exclusive)
            if name=='checkpoint.json' and Path(root).name=='source' and value.get('rows')==5:stopped[0]=True
            return result
        with patch.object(E.M,'atomic_json',side_effect=stop_after_chunk),self.assertRaises(E.M.Stopped):E.run(self.output,stop=lambda:'SIGINT' if stopped[0] else None)
        source=self.output/'unit-000/source';self.assertEqual(E.M.read_json(source/'checkpoint.json')['rows'],5)
        raw=(source/'chunk-000000.csv').read_bytes()
        self.assertEqual(E.run(self.output)['selected_rows'],20);self.assertEqual((source/'chunk-000000.csv').read_bytes(),raw)

    def test_completed_inventory_adopted_after_checkpoint_receipt_loss(self):
        self.prepare();original=E.M.atomic_json
        def fail_checkpoint(root,name,value,exclusive=False):
            if Path(root).resolve()==self.output.resolve() and name=='checkpoint.json' and value['units'][0]['result'] is not None:raise OSError('injected controller checkpoint loss')
            return original(root,name,value,exclusive)
        with patch.object(E.M,'atomic_json',side_effect=fail_checkpoint),self.assertRaisesRegex(OSError,'checkpoint loss'):E.run(self.output)
        self.assertIsNone(self.state()['units'][0]['result']);inventory=self.output/'unit-000/inventory-000';before=self.hashes(inventory)
        with patch.object(E.I,'collect',side_effect=AssertionError('adopt existing verified inventory')):E.run(self.output)
        self.assertEqual(before,self.hashes(inventory));self.assertEqual(E.verify(self.output)['selected_rows'],20)

    def test_incomplete_inventory_requires_explicit_new_attempt_and_preserves_evidence(self):
        self.prepare();original=E.I.collect;stopped=[False]
        def cancel_inventory(source,output,**kwargs):
            def stop():
                stopped[0]=stopped[0] or (output/'inventory.sqlite').exists()
                return 'SIGTERM' if stopped[0] else None
            return original(source,output,stop=stop)
        with patch.object(E.I,'collect',side_effect=cancel_inventory),self.assertRaises(E.M.Stopped):E.run(self.output)
        inventory=self.output/'unit-000/inventory-000';before=self.hashes(inventory)
        with self.assertRaisesRegex(ValueError,'explicitly retry'):E.run(self.output)
        E.run(self.output,retry_incomplete_inventory=True)
        self.assertEqual(before,self.hashes(inventory));self.assertEqual(self.state()['units'][0]['inventory_attempt'],1)
        self.assertEqual(E.verify(self.output)['selected_rows'],20)

    def test_corrupt_completed_inventory_is_not_hidden_by_retry(self):
        self.prepare();E.run(self.output);db=self.output/'unit-000/inventory-000/inventory.sqlite'
        raw=db.read_bytes();db.write_bytes(raw[:-1]+bytes([raw[-1]^1]))
        for retry in [False,True]:
            with self.subTest(retry=retry),self.assertRaisesRegex(ValueError,'hash differs'):E.run(self.output,retry_incomplete_inventory=retry)
        self.assertFalse((self.output/'unit-000/inventory-001').exists())

    def test_missing_completed_artifacts_are_not_regenerated(self):
        self.prepare();E.run(self.output);inventory=self.output/'unit-000/inventory-000'
        for path in inventory.iterdir():path.unlink()
        inventory.rmdir()
        with patch.object(E.I,'collect',side_effect=AssertionError('must not rebuild completed work')),self.assertRaisesRegex(ValueError,'missing'):E.run(self.output)

    def test_changed_completed_source_is_not_regenerated_or_rebound(self):
        self.prepare();E.run(self.output);chunk=self.output/'unit-000/source/chunk-000000.csv'
        chunk.write_bytes(chunk.read_bytes()+b'changed');before=chunk.read_bytes()
        with patch.object(E.M,'run',side_effect=AssertionError('must preserve changed evidence')),self.assertRaises(ValueError):E.run(self.output,retry_incomplete_inventory=True)
        self.assertEqual(chunk.read_bytes(),before)

    def test_attempt_limit_and_incomplete_source_metadata_refuse_safely(self):
        self.prepare();folder=self.output/'unit-000';folder.mkdir();(folder/'source').mkdir()
        with self.assertRaises(OSError):E.run(self.output)
        self.assertTrue((folder/'source').exists())

    def test_inventory_attempt_limit_retains_all_attempts(self):
        self.prepare()
        def fail(source,output,**kwargs):output.mkdir();raise OSError('injected incomplete inventory')
        with patch.object(E.I,'collect',side_effect=fail):
            for retry in [False,True,True]:
                with self.assertRaisesRegex(OSError,'incomplete'):E.run(self.output,retry_incomplete_inventory=retry)
        with self.assertRaisesRegex(ValueError,'attempt limit'):E.run(self.output,retry_incomplete_inventory=True)
        self.assertEqual(len(list((self.output/'unit-000').glob('inventory-*'))),3)

    def test_input_checkpoint_and_result_drift_are_refused(self):
        self.prepare();E.run(self.output);cp=self.state();bad=copy.deepcopy(cp);bad['units'][0]['partition']+=1
        E.M.atomic_json(self.output,'checkpoint.json',bad)
        with self.assertRaises(ValueError):E.verify(self.output)
        E.M.atomic_json(self.output,'checkpoint.json',cp)
        complete=E.M.read_json(self.output/'complete.json');complete['qualifying']=0;E.M.atomic_json(self.output,'complete.json',complete)
        with self.assertRaisesRegex(ValueError,'completion differs'):E.verify(self.output)
        req=E.M.read_json(self.output/'request.json');req['partition_plan_sha256']='0'*64;E.M.atomic_json(self.output,'request.json',req)
        with self.assertRaisesRegex(ValueError,'request/source'):E.run(self.output)

    def test_completed_receipt_cannot_hide_a_regressed_checkpoint(self):
        self.prepare();E.run(self.output);cp=self.state();cp['units'][0]['result']=None
        E.M.atomic_json(self.output,'checkpoint.json',cp)
        with patch.object(E.I,'collect',side_effect=AssertionError('must not rewrite completed run')),self.assertRaisesRegex(ValueError,'contradicts'):E.run(self.output)

    def test_changed_schedule_and_executor_code_are_refused(self):
        self.prepare();plan=E.M.read_json(self.schedule/'partition-plan.json');plan['total_rows']+=1;E.M.atomic_json(self.schedule,'partition-plan.json',plan)
        with self.assertRaisesRegex(ValueError,'identity/coverage'):E.run(self.output)
        with patch.object(E,'SOURCE_SHA','0'*64),self.assertRaisesRegex(ValueError,'changed after import'):E.run(self.output)

    def test_stop_deadline_and_exclusive_lock_do_not_start_generation(self):
        self.prepare()
        with E.M.locked(self.output),self.assertRaises(BlockingIOError):E.run(self.output)
        for reason,code in [('SIGINT',130),('SIGTERM',143)]:
            with self.subTest(reason=reason),self.assertRaises(E.M.Stopped) as error:E.run(self.output,stop=lambda:reason)
            self.assertEqual(error.exception.code,code)
        with patch.object(E.Guard,'check',side_effect=E.M.Stopped('deadline')),self.assertRaises(E.M.Stopped):E.run(self.output)
        (self.output/'STOP').write_bytes(b'')
        with self.assertRaisesRegex(E.M.Stopped,'stop_file'):E.run(self.output)
        self.assertFalse((self.output/'unit-000').exists())

    def test_cancelled_prepare_and_invalid_run_controls_leave_outputs_untouched(self):
        with self.assertRaises(E.M.Stopped):E.prepare(self.schedule,self.output,[self.care],stop=lambda:'SIGINT')
        self.assertFalse(self.output.exists());self.prepare();before=self.hashes(self.output)
        for args in [dict(max_units=0),dict(max_units=True),dict(seconds=0),dict(retry_incomplete_inventory=1)]:
            with self.subTest(args=args),self.assertRaises(ValueError):E.run(self.output,**args)
        self.assertEqual(before,self.hashes(self.output))

    def test_prepare_second_witness_scan_preserves_stop_and_outer_deadline(self):
        source=self.home/'witness-source';inventory=self.home/'witness-inventory'
        E.M.prepare(source,'S2','5.5',[dict(table='measurement',start=98,rows=2)])
        self.assertEqual(E.M.run(source)['status'],'complete');E.I.collect(source,inventory)
        registration=self.home/'witness-registration';schedule=self.home/'witness-schedule'
        E.R.register(registration,'prepare-stop','S2','5.5',{r:str(self.home) for r in E.R.ROLES},source,inventory)
        E.P.create(registration,schedule,rows_per_partition=20,chunk_rows=5)
        original=E.I.verify
        for mode,code in [('signal',143),('deadline',3)]:
            calls=[];completed=[];stopped=[None];clock=[100.0]
            def scan(*args,**kwargs):
                calls.append(kwargs.get('stop'))
                if len(calls)==2:
                    if mode=='signal':stopped[0]='SIGTERM'
                    else:clock[0]=221.0
                value=original(*args,**kwargs);completed.append(len(calls));return value
            with self.subTest(mode=mode):
                with patch.object(E.I,'verify',side_effect=scan),patch.object(E.I.time,'monotonic',side_effect=lambda:clock[0]),self.assertRaises(E.M.Stopped) as error:
                    E.prepare(schedule,self.output,[self.care],stop=lambda:stopped[0])
                self.assertEqual(error.exception.code,code);self.assertEqual(len(calls),2)
                self.assertEqual(completed,[1]);self.assertTrue(all(callable(callback) for callback in calls))
                self.assertFalse(self.output.exists())

    def test_missing_or_replaced_retained_attempts_block_run_retry_and_verify(self):
        self.prepare();original=E.I.collect
        def partial(source,output,**kwargs):
            if output.name in ('inventory-000','inventory-001'):
                output.mkdir();E.M.atomic_json(output,'failed.json',dict(status='failed'))
                raise OSError('injected incomplete inventory')
            return original(source,output,**kwargs)
        with patch.object(E.I,'collect',side_effect=partial):
            for retry in [False,True]:
                with self.assertRaisesRegex(OSError,'incomplete'):E.run(self.output,retry_incomplete_inventory=retry)
            E.run(self.output,retry_incomplete_inventory=True)
        folder=self.output/'unit-000';active=folder/'inventory-002';before=self.hashes(active)
        for index in [0,1]:
            retired=folder/f'inventory-{index:03}';saved=self.home/f'saved-{index}';retired.rename(saved)
            try:
                for replacement in ['missing','file','symlink']:
                    if replacement=='file':retired.write_bytes(b'retained placeholder')
                    elif replacement=='symlink':retired.symlink_to(saved,target_is_directory=True)
                    try:
                        with self.subTest(index=index,replacement=replacement),patch.object(E.I,'collect',side_effect=AssertionError('must not rebuild missing evidence')):
                            for action in [lambda:E.run(self.output),lambda:E.run(self.output,retry_incomplete_inventory=True),lambda:E.verify(self.output)]:
                                with self.assertRaises(ValueError):action()
                        self.assertEqual(before,self.hashes(active))
                    finally:
                        if replacement!='missing':retired.unlink()
            finally:saved.rename(retired)
        self.assertEqual(E.verify(self.output)['selected_rows'],20)

    def test_path_isolation_and_unexpected_files_preserve_inputs(self):
        before=self.hashes(self.schedule)
        for output in [self.schedule/'inside',self.home,self.registration/'inside']:
            with self.subTest(output=output),self.assertRaises(ValueError):E.prepare(self.schedule,output,[self.care])
        alias=self.home/'alias';alias.symlink_to(self.home/'absent')
        with self.assertRaises(ValueError):E.prepare(self.schedule,alias,[self.care])
        self.assertFalse((self.home/'absent').exists());self.assertEqual(before,self.hashes(self.schedule))
        self.prepare();(self.output/'foreign').write_bytes(b'preserve')
        with self.assertRaisesRegex(ValueError,'Unexpected'):E.run(self.output)
        self.assertEqual((self.output/'foreign').read_bytes(),b'preserve')

    def test_prepare_run_and_verify_never_launch_source_database_processes(self):
        with patch.object(subprocess,'Popen',side_effect=AssertionError('no process/database transport')):
            self.prepare();E.run(self.output);E.verify(self.output)


if __name__=='__main__':unittest.main()
