"""Exact logical coverage and bounded handoff without source enumeration."""
import copy
import io
import json
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
    import source_partition_plan as P
finally: sys.path[:]=_saved


class PartitionCase(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.home=Path(temp.name); self.registration=self.home/'registration'; self.output=self.home/'schedule'
        self.paths={role:str(self.home) for role in P.R.ROLES}

    def create(self,tier='S2',version='5.5',**kwargs):
        P.R.register(self.registration,'schedule-check',tier,version,self.paths)
        return P.create(self.registration,self.output,**kwargs)

    def rewrite(self,value):
        unsigned={k:v for k,v in value.items() if k!='partition_plan_sha256'}
        value['partition_plan_sha256']=P.S.BASE.sha(P.S.BASE.canonical(unsigned))
        P.M.atomic_json(self.output,'partition-plan.json',value)


class PartitionTest(PartitionCase):
    def test_all_tables_are_covered_exactly_for_both_tiers_and_all_versions(self):
        for tier,total in [('S1',6705021),('S2',117050021)]:
            for version,tables in [('5.3',37),('5.4',39),('5.5',42)]:
                with self.subTest(tier=tier,version=version),tempfile.TemporaryDirectory(dir=self.home) as folder:
                    folder=Path(folder); registration=folder/'registration'; output=folder/'schedule'
                    P.R.register(registration,'coverage',tier,version,self.paths)
                    with patch.object(P.S.Source,'row',side_effect=AssertionError('must not enumerate source rows')):
                        plan=P.create(registration,output)
                        self.assertEqual(P.verify(output),plan)
                    self.assertEqual(plan['total_rows'],total); self.assertEqual(len(plan['tables']),tables)
                    self.assertEqual([t['table'] for t in plan['tables']],sorted(plan['source']['table_rows']))
                    index=0; actual_rows=0
                    for table in plan['tables']:
                        self.assertEqual(table['first_partition'],index); start=0
                        for _ in range(table['partitions']):
                            [window]=P.partition(plan,index)
                            self.assertEqual(window['table'],table['table']); self.assertEqual(window['start'],start)
                            self.assertLessEqual(window['rows'],100000); self.assertGreaterEqual(window['rows'],0)
                            if table['rows']:self.assertGreater(window['rows'],0)
                            start+=window['rows']; actual_rows+=window['rows']; index+=1
                        self.assertEqual(start,plan['source']['table_rows'][table['table']])
                        if not table['rows']:self.assertEqual(table['partitions'],1)
                    self.assertEqual(actual_rows,total); self.assertEqual(index,plan['partition_count'])

    def test_random_access_is_compact_even_with_one_row_partitions(self):
        plan=self.create(rows_per_partition=1,chunk_rows=1)
        self.assertGreater(plan['partition_count'],117000000)
        self.assertLess((self.output/'partition-plan.json').stat().st_size,65536)
        for table in plan['tables']:
            for index in {table['first_partition'],table['first_partition']+table['partitions']-1}:
                [window]=P.partition(plan,index)
                self.assertEqual(window['table'],table['table']); self.assertIn(window['rows'],[0,1])
                self.assertEqual(window['start']+window['rows'],min(table['rows'],index-table['first_partition']+1))

    def test_work_units_pass_existing_materializer_with_exact_pins(self):
        plan=self.create(rows_per_partition=777,chunk_rows=13)
        for table in plan['tables']:
            for index in {table['first_partition'],table['first_partition']+table['partitions']-1}:
                bounded=P.materialization_plan(plan,index)
                self.assertEqual(bounded['windows'],P.partition(plan,index))
                self.assertEqual(bounded['source'],plan['source'])
                self.assertLessEqual(len(P.M.layout(bounded)),P.M.MAX_CHUNKS)
                self.assertEqual(bounded['limits']['csv_bytes'],P.M.MAX_BYTES)
                self.assertFalse(bounded['full_tier_generated']); self.assertFalse(bounded['qualifying'])

    def test_planning_never_admits_generation_or_database_work(self):
        with patch.object(P.M,'run',side_effect=AssertionError('no generation')),patch.object(subprocess,'Popen',side_effect=AssertionError('no child/database client')):
            plan=self.create()
            self.assertEqual(P.verify(self.output),plan)
        self.assertEqual(plan['coverage'],'full_logical_source_schedule_only')
        self.assertEqual(plan['status'],'planned_not_admitted')
        for key in ['execution_enabled','full_tier_generated','qualifying']:self.assertIs(plan[key],False)
        self.assertEqual(sorted(p.name for p in self.output.iterdir()),['partition-plan.json'])

    def test_invalid_controls_are_rejected_without_output(self):
        for rows,chunks in [(True,1),(0,1),(100001,10000),(1000,True),(1000,0),(1000,10001),(100000,1),(1.0,1)]:
            with self.subTest(rows=rows,chunks=chunks),patch.object(P.R,'verify',side_effect=AssertionError('registration read before control validation')) as verify:
                with self.assertRaisesRegex(ValueError,'Partition controls'):
                    P.create(self.registration,self.output,rows_per_partition=rows,chunk_rows=chunks)
                verify.assert_not_called()
                self.assertFalse(self.output.exists())

    def test_invalid_partition_indices_are_rejected(self):
        plan=self.create()
        for index in [-1,True,1.0,'0',plan['partition_count']]:
            with self.subTest(index=index),self.assertRaises(ValueError):P.partition(plan,index)

    def test_resigned_layout_controls_flags_and_hash_drift_are_rejected(self):
        good=self.create()
        mutations=[]
        for field,value in [('total_rows',0),('partition_count',1),('execution_enabled',True),('planner_sha256','0'*64),('registration_sha256','0'*64)]:
            bad=copy.deepcopy(good);bad[field]=value;mutations.append(bad)
        bad=copy.deepcopy(good);bad['tables'][0]['first_partition']+=1;mutations.append(bad)
        bad=copy.deepcopy(good);bad['tables'][0]['rows']+=1;mutations.append(bad)
        bad=copy.deepcopy(good);bad['tables'].pop();mutations.append(bad)
        bad=copy.deepcopy(good);bad['controls']['csv_bytes']+=1;mutations.append(bad)
        for bad in mutations:
            with self.subTest(keys=bad.keys()):
                self.rewrite(bad)
                with self.assertRaisesRegex(ValueError,'identity/coverage'):P.verify(self.output)

    def test_changed_registration_is_not_rebound(self):
        self.create(); value=P.M.read_json(self.registration/'registration.json')
        value['request']['run_id']='different-run'
        unsigned={k:v for k,v in value.items() if k!='registration_sha256'}
        value['registration_sha256']=P.S.BASE.sha(P.S.BASE.canonical(unsigned))
        P.M.atomic_json(self.registration,'registration.json',value)
        P.R.verify(self.registration)
        with self.assertRaisesRegex(ValueError,'identity/coverage'):P.verify(self.output)

    def test_current_planner_code_drift_is_refused(self):
        self.create()
        with patch.object(P,'SOURCE_SHA','0'*64),self.assertRaisesRegex(ValueError,'changed after import'):P.verify(self.output)

    def test_existing_direct_symlink_and_overlapping_outputs_are_preserved(self):
        good=self.create();raw=(self.output/'partition-plan.json').read_bytes()
        with self.assertRaises(FileExistsError):P.create(self.registration,self.output)
        self.assertEqual((self.output/'partition-plan.json').read_bytes(),raw)
        for output in [self.registration/'inside',self.registration,self.home]:
            with self.subTest(output=output),self.assertRaises(ValueError):P.create(self.registration,output)
        alias=self.home/'alias';alias.symlink_to(self.home/'missing')
        with self.assertRaises(ValueError):P.create(self.registration,alias)
        self.assertFalse((self.home/'missing').exists())
        alias.unlink();alias.symlink_to(self.output)
        with self.assertRaises(ValueError):P.verify(alias)
        self.assertEqual(P.verify(self.output),good)

    def test_unexpected_and_noncanonical_metadata_are_refused(self):
        good=self.create();extra=self.output/'unexpected';extra.write_bytes(b'')
        with self.assertRaisesRegex(ValueError,'inventory'):P.verify(self.output)
        extra.unlink();(self.output/'partition-plan.json').write_text(json.dumps(good,indent=2))
        with self.assertRaisesRegex(ValueError,'Noncanonical'):P.verify(self.output)

    def test_witness_input_changes_and_overlap_are_refused(self):
        source=self.home/'source';inventory=self.home/'inventory'
        P.M.prepare(source,'S2','5.5',[dict(table='measurement',start=98,rows=2)])
        self.assertEqual(P.M.run(source)['status'],'complete');P.R.I.collect(source,inventory)
        P.R.register(self.registration,'witness','S2','5.5',self.paths,source,inventory)
        for output in [source/'inside',inventory/'inside']:
            with self.subTest(output=output),self.assertRaises(ValueError):P.create(self.registration,output)
        P.create(self.registration,self.output)
        (source/'chunk-000000.csv').write_bytes(b'changed')
        with self.assertRaises(ValueError):P.verify(self.output)

    def test_materializer_handoff_rejects_stale_source(self):
        plan=self.create();plan['source']['parameters']['seed']+=1
        with self.assertRaisesRegex(ValueError,'source changed'):P.materialization_plan(plan,0)

    def test_verification_forwards_outer_stop_callback_to_witness_scan(self):
        plan=self.create();stop=lambda:'SIGINT'
        with patch.object(P.R,'verify',wraps=P.R.verify) as verify:
            self.assertEqual(P.verify(self.output,stop=stop),plan)
        verify.assert_called_once_with(self.registration.resolve(),stop=stop)

    def test_cli_selection_is_only_a_json_array_accepted_by_materializer(self):
        self.create()
        args=['planner','selection','--output-dir',str(self.output),'--partition','0']
        with patch.object(sys,'argv',args),patch.object(sys,'stdout',new_callable=io.StringIO) as out:
            self.assertEqual(P.main(),0)
        selection=json.loads(out.getvalue());self.assertIsInstance(selection,list)
        value=P.M.build_plan('S2','5.5',selection,chunk_rows=10000)
        self.assertEqual(value['windows'],selection)


if __name__=='__main__':unittest.main()
