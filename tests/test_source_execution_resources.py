"""Admission model tests with explicitly simulated reference resources.

These fixtures never establish a real reference allocation or resource claim.
The worker filesystem paths are real; capacities/namespaces/cgroups are stand-ins.
"""
from copy import deepcopy
import io
import json
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
    import source_execution_resources as Z
    import source_partition_plan as P
    import partition_stream as T
finally:sys.path[:]=saved


def reference_fixture(root,plan_sha,tier='S1',job=None,target=None):
    """Synthetic machine envelope; never call this a measured registration."""
    work=root/'work';scratch=root/'scratch';database=root/'database'
    for directory in (work,scratch,database):directory.mkdir(exist_ok=True)
    config=Z.template(job or work/'job',plan_sha,tier);config.update(allocation_id='contract-self-test',operator_uid=1001,common_parent='/achillesnext-validation-self-test')
    config['authority']={k:True for k in Z.AUTHORITY}
    config['containers']={role:dict(id=letter*64,pid=pid) for role,letter,pid in [('runner','a',101),('postgres','b',202)]}
    for role,item in config['storage'].items():
        location=scratch if role=='temporary' else database if role=='database' else work
        item.update(pool='pool',host_path=str(location),worker_path=str(location))
    config['pools']=dict(pool=dict(reserved_bytes=512*Z.GIB))
    evidence=root/'projection-evidence';evidence.write_bytes(b'explicitly simulated resource-model evidence\n')
    config['projection']=dict(basis='bounded_witness' if tier=='S1' else 'S1_calibration',evidence_file=str(evidence),sha256=Z.file_sha(evidence),peak_bytes={r:2*Z.GIB for r in Z.R.ROLES})
    config['database']=target or dict(database=Z.L.F.DB,owner=Z.L.F.OWNER,database_oid=12345,postmaster_started_at='2026-11-12 01:00:00+00',server_version='17.11',address='127.0.0.1',port=5432,initial_database_bytes=0,
        settings=dict(shared_buffers='8GB',work_mem='64MB',hash_mem_multiplier='1',max_parallel_workers_per_gather='2',huge_pages='off',default_tablespace='',temp_tablespaces=''))
    parent=config['common_parent'];identities={role:dict(pid=v['pid'],start_ticks=10,pid_namespace='pid:[1]' if role=='runner' else 'pid:[2]',cgroup=parent+'/'+v['id']) for role,v in config['containers'].items()}
    member={role:{'memory.max':str(512*1024**2),'memory.swap.max':'0','cpu.max':'200000 100000','pids.max':'512'} for role in identities}
    raw={'memory.max':str(28*Z.GIB),'memory.swap.max':'0','cpu.max':'800000 100000','pids.max':'1024'}
    sample=dict(unavailable=[],member_controls=member,raw=raw,metrics=dict(controls=Z.C.controls(raw),memory_lifetime_peak_bytes=1024**2,swap_current_bytes=0,memory_events=dict(oom=0,oom_kill=0),cpu=dict(usage_usec=100)))
    observed=dict(platform='Linux',operator_uid=1001,boot_id=dict(state='observed',value='simulated-boot'),visible_cpus=dict(state='observed',value=16),memory_bytes=dict(state='observed',value=64*Z.GIB),
        storage={role:dict(state='observed',value=dict(Z.R.disk(item['host_path']),free_bytes=600*Z.GIB,total_bytes=1024*Z.GIB)) for role,item in config['storage'].items()},
        storage_directories={role:dict(state='observed',value=Z.directory_identity(item['host_path'])) for role,item in config['storage'].items()},
        database_volume=dict(state='observed',value=dict(data=Z.directory_identity(database),children={},namespace_pid='1',directory=str(database))),
        projection_sha256=dict(state='observed',value=config['projection']['sha256']),attribution_error=None,
        attribution=dict(identities=identities,inodes={parent:[1,1],identities['runner']['cgroup']:[1,2],identities['postgres']['cgroup']:[1,3]},observer_namespace='pid:[3]',ancestors={},sample=sample))
    worker=dict(platform='Linux',boot_id='simulated-boot',namespace='pid:[1]',cgroup_inode=[1,2],memory=dict(bytes=512*1024**2),cpu=dict(quota_usec=200000,period_usec=100000))
    return config,observed,worker


class ResourceTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);self.root=Path(temporary.name)
        self.config,self.observed,self.worker=reference_fixture(self.root,'1'*64)
        self.output=self.root/'resources';self.file=self.root/'allocation.json';self.save()

    def save(self):self.file.write_bytes(Z.S.BASE.canonical(self.config))
    def register(self):
        self.save()
        with patch.object(Z,'host_observation',return_value=deepcopy(self.observed)):return Z.register(self.file,self.output)

    def test_reference_model_registers_one_pool_without_summing_aliases(self):
        record=self.register();self.assertEqual(record['status'],'registered')
        self.assertEqual(record['pool_observations']['pool']['free_bytes'],600*Z.GIB)
        self.assertEqual(record['pool_observations']['pool']['projected_bytes'],10*Z.GIB)
        Z.Lease(self.output,record).check();self.assertFalse(record['qualifying'])

    def test_core_database_settings_cannot_be_empty_before_registration(self):
        settings=self.config['database']['settings']
        self.assertEqual(Z.allocation(deepcopy(self.config))['database']['settings'],settings)
        for name in settings:
            for invalid in (129*'x',None):
                with self.subTest(name=name,invalid=invalid):
                    config=deepcopy(self.config);config['database']['settings'][name]=invalid
                    with self.assertRaisesRegex(ValueError,'settings identity'):Z.allocation(config)
            if name in ('default_tablespace','temp_tablespaces'):continue
            with self.subTest(name=name):
                config=deepcopy(self.config);config['database']['settings'][name]=''
                self.file.write_bytes(Z.S.BASE.canonical(config))
                with patch.object(Z,'host_observation',side_effect=AssertionError('must reject before observation')):
                    with self.assertRaisesRegex(ValueError,'settings identity'):Z.register(self.file,self.output)
                self.assertFalse(self.output.exists())

    def test_external_storage_records_blocked_admission_and_exit_three(self):
        for case in ('tablespace','volume'):
            with self.subTest(case=case):
                config=deepcopy(self.config);observed=deepcopy(self.observed)
                if case=='tablespace':config['database']['settings']['default_tablespace']='external'
                else:observed['database_volume']=dict(state='unavailable',value=None)
                self.file.write_bytes(Z.S.BASE.canonical(config));output=self.root/('resources-'+case)
                with patch.object(Z,'host_observation',return_value=observed),patch.object(sys,'argv',
                        ['resources','register','--allocation-file',str(self.file),'--output-dir',str(output)]),patch.object(sys,'stdout',new_callable=io.StringIO) as stdout:
                    self.assertEqual(Z.main(),3)
                result=json.loads(stdout.getvalue());self.assertEqual(result['status'],'blocked')
                self.assertIn('external_database_tablespaces_unverified' if case=='tablespace' else 'database_volume_unverified',result['blocking_reasons'])
                self.assertEqual(Z.M.read_json(output/'registration.json')['status'],'blocked')

    def test_unapproved_template_records_blockers_and_cannot_be_renewed_ready(self):
        self.config=Z.template(self.root/'work/job','1'*64,'S1');record=self.register()
        self.assertEqual(record['status'],'blocked');self.assertIn('allocation_unassigned',record['blocking_reasons'])
        with patch.object(Z,'host_observation',return_value=self.observed):lease=Z.renew(self.output)
        self.assertEqual(lease['status'],'blocked')
        with self.assertRaises(Z.M.Stopped):Z.Lease(self.output,record).check()

    def test_missing_small_unlimited_and_ancestor_limits_block_admission(self):
        for case in ['missing','memory','cpu','unlimited','ancestor','root_operator']:
            with self.subTest(case=case):
                observed=deepcopy(self.observed)
                if case=='missing':observed['attribution']=None
                elif case=='memory':observed['memory_bytes']['value']=24*Z.GIB
                elif case=='cpu':observed['visible_cpus']['value']=4
                elif case=='root_operator':observed['operator_uid']=0
                elif case=='unlimited':observed['attribution']['sample']['metrics']['controls']['memory_bytes']=None
                else:observed['attribution']['ancestors']['/parent']={'memory.max':str(Z.GIB),'memory.swap.max':'0','cpu.max':'max 100000','pids.max':'max'}
                self.assertTrue(Z.assess(self.config,observed,Z.now())['blocking_reasons'])
        config=deepcopy(self.config);config['database']['settings']['huge_pages']='on'
        self.assertIn('hugetlb_accounting_unverified',Z.assess(config,self.observed,Z.now())['blocking_reasons'])

    def test_same_device_cannot_be_split_into_fake_free_storage_pools(self):
        self.config['pools']['other']=dict(reserved_bytes=64*Z.GIB);self.config['storage']['export']['pool']='other'
        self.observed['storage']['export']['value']['logical_device']=self.observed['storage']['source']['value']['logical_device']
        self.assertIn('storage_alias_split_across_pools',Z.assess(self.config,self.observed,Z.now())['blocking_reasons'])

    def test_projected_costs_require_headroom_and_tier_specific_evidence(self):
        for case in ['headroom','budget','basis','evidence']:
            with self.subTest(case=case):
                config=deepcopy(self.config)
                if case=='headroom':config['pools']['pool']['reserved_bytes']=10*Z.GIB
                elif case=='budget':config['projection']['peak_bytes']['database']=384*Z.GIB
                elif case=='basis':config['projection']['basis']='S1_calibration'
                else:config['projection']['sha256']='2'*64
                self.assertTrue(Z.assess(config,self.observed,Z.now())['blocking_reasons'])

    def test_renewal_blocks_identity_limit_counter_cpu_and_disk_drift(self):
        record=self.register()
        for case in ['boot','pid','inode','child_cap','parent_cap','cpu','counter','disk','device','oom','database_volume','directory']:
            with self.subTest(case=case):
                observed=deepcopy(self.observed);a=observed['attribution'];metrics=a['sample']['metrics']
                if case=='boot':observed['boot_id']['value']='changed'
                elif case=='pid':a['identities']['postgres']['start_ticks']+=1
                elif case=='inode':a['inodes'][self.config['common_parent']]=[1,99]
                elif case=='child_cap':a['sample']['member_controls']['runner']['cpu.max']='100000 100000'
                elif case=='parent_cap':a['sample']['raw']['pids.max']='512'
                elif case=='cpu':metrics['cpu']['usage_usec']+=40*3600*1000000+1
                elif case=='counter':metrics['memory_lifetime_peak_bytes']=0
                elif case=='oom':metrics['memory_events']['oom_kill']=1
                elif case=='device':observed['storage']['source']['value']['logical_device']='99999'
                elif case=='database_volume':observed['database_volume']['value']['data']=[1,999]
                elif case=='directory':observed['storage_directories']['source']['value']=[1,999]
                else:
                    for fact in observed['storage'].values():fact['value']['free_bytes']=580*Z.GIB
                with patch.object(Z,'host_observation',return_value=observed):lease=Z.renew(self.output)
                self.assertEqual(lease['status'],'blocked')
                with self.assertRaises(Z.M.Stopped):Z.Lease(self.output,record).check()

    def test_stale_future_expired_and_revoked_leases_stop(self):
        record=self.register();at=Z.now()
        with patch.object(Z,'now',return_value=at+11),self.assertRaises(Z.M.Stopped):Z.Lease(self.output,record).check()
        with patch.object(Z,'now',return_value=at-4),self.assertRaises(Z.M.Stopped):Z.Lease(self.output,record).check()
        Z.M.atomic_json(self.output,'revoked.json',dict(status='revoked'))
        with self.assertRaisesRegex(Z.M.Stopped,'revoked'):Z.Lease(self.output,record).check()
        with self.assertRaises(Z.M.Stopped):Z.renew(self.output)

    def test_template_cli_is_exclusive_and_no_host_authority_is_implied(self):
        output=self.root/'template.json'
        with patch.object(sys,'argv',['resources','template','--job-dir',str(self.root/'job'),'--plan-sha256','1'*64,'--tier','S1','--output-file',str(output)]),patch.object(sys,'stdout',new_callable=io.StringIO):self.assertEqual(Z.main(),0)
        doc=Z.M.read_json(output);self.assertFalse(any(doc['authority'].values()));self.assertIsNone(doc['common_parent'])

    def test_nonboolean_authority_and_bad_shape_are_not_silently_accepted(self):
        self.config['authority']['stop_authority']=1
        with self.assertRaises(ValueError):Z.allocation(self.config)
        with self.assertRaises(ValueError):Z.allocation([])

    def test_unknown_registration_version_and_altered_code_are_refused(self):
        record=self.register()
        changed=dict(record,version=2);changed['registration_sha256']=Z.digest({k:v for k,v in changed.items() if k!='registration_sha256'})
        Z.M.atomic_json(self.output,'registration.json',changed)
        with self.assertRaises(ValueError):Z.read_registration(self.output)
        Z.M.atomic_json(self.output,'registration.json',record)
        with patch.object(Z,'SOURCE_SHA','0'*64),self.assertRaises(ValueError):Z.read_registration(self.output)

    def witness_plan(self):
        source=self.root/'witness';inventory=self.root/'inventory';registration=self.root/'source-reg';schedule=self.root/'schedule'
        Z.M.prepare(source,'S1','5.5',[dict(table='measurement',start=0,rows=2)],chunk_rows=2);Z.M.run(source);Z.R.I.collect(source,inventory)
        Z.R.register(registration,'resource-unit','S1','5.5',{r:str(self.root) for r in Z.R.ROLES},source,inventory)
        plan=P.create(registration,schedule);self.config['partition_plan_sha256']=plan['partition_plan_sha256']
        return plan

    def test_worker_gate_rechecks_source_witness_namespace_storage_and_fresh_lease(self):
        plan=self.witness_plan();record=self.register()
        job=Path(self.config['job_dir'])
        with patch.object(Z,'worker_identity',return_value=self.worker),patch.object(Z.tempfile,'tempdir',self.config['storage']['temporary']['worker_path']):
            binding,lease,_=Z.verify_worker(self.output,job,plan);lease.check()
            self.assertEqual(binding['registration_sha256'],record['registration_sha256'])
            with self.assertRaisesRegex(ValueError,'binding differs'):Z.verify_worker(self.output,self.root/'other',plan)
        changed=dict(self.worker,namespace='pid:[999]')
        with patch.object(Z,'worker_identity',return_value=changed),self.assertRaisesRegex(ValueError,'outside registered'):Z.verify_worker(self.output,job,plan)

    def test_worker_mapping_is_rechecked_after_initial_admission(self):
        plan=self.witness_plan();self.register();job=Path(self.config['job_dir'])
        with patch.object(Z,'worker_identity',return_value=self.worker),patch.object(Z.tempfile,'tempdir',self.config['storage']['temporary']['worker_path']):
            _,lease,_=Z.verify_worker(self.output,job,plan)
            for role in ('source','temporary'):
                base=Path(self.config['storage'][role]['worker_path']);old=base.with_name(base.name+'-old');base.rename(old);base.mkdir()
                try:
                    with patch.object(Z.time,'monotonic',return_value=lease.last+1),self.assertRaisesRegex(ValueError,'Worker storage binding differs'):lease.check()
                finally:base.rmdir();old.rename(base)

    def test_resource_metadata_is_separate_in_both_directions_and_through_aliases(self):
        alias=self.root/'alias';alias.symlink_to(self.root/'work',target_is_directory=True)
        for output in [self.root/'work/resources',Path(self.config['job_dir'])/'resources',self.root/'scratch/resources',alias/'resources',self.root]:
            with self.subTest(output=output),patch.object(Z,'host_observation',side_effect=AssertionError('no observation before isolation')):
                with self.assertRaisesRegex(ValueError,'Keep resource output separate'):Z.register(self.file,output)
        self.assertFalse((self.root/'work/resources').exists());self.assertEqual(Z.M.read_json(self.file),self.config)

    def test_synthetic_operator_uid_is_independent_of_root_test_process(self):
        other=self.root/'root-case';other.mkdir()
        with patch.object(os,'geteuid',return_value=0):config,observed,_=reference_fixture(other,'1'*64)
        self.assertEqual(config['operator_uid'],1001);self.assertEqual(observed['operator_uid'],1001)
        self.assertFalse(Z.assess(config,observed,Z.now())['blocking_reasons'])

    def test_database_mapping_requires_the_active_mounted_data_directory(self):
        data=Path(self.config['storage']['database']['host_path']);proc=self.root/'proc';process=proc/'202';process.mkdir(parents=True)
        (process/'root').symlink_to('/',target_is_directory=True);(process/'status').write_text('NSpid:\t202\t1\n')
        for name in ('base','pg_wal','pg_tblspc'):(data/name).mkdir()
        (data/'base'/str(self.config['database']['database_oid'])).mkdir()
        def pidfile(pid='1',epoch=None):
            epoch=int(Z.timestamp(self.config['database']['postmaster_started_at'])) if epoch is None else epoch
            (data/'postmaster.pid').write_text(f'{pid}\n{data}\n{epoch}\n5432\n')
        pidfile();value=Z.database_volume(self.config,proc);self.assertEqual(value['data'],Z.directory_identity(data))
        other=self.root/'wrong-database';other.mkdir();wrong=deepcopy(self.config);wrong['storage']['database']['host_path']=str(other)
        with self.assertRaisesRegex(ValueError,'mapping differs'):Z.database_volume(wrong,proc)
        pidfile(pid='2')
        with self.assertRaisesRegex(ValueError,'target postmaster'):Z.database_volume(self.config,proc)
        pidfile(epoch=1)
        with self.assertRaisesRegex(ValueError,'target postmaster'):Z.database_volume(self.config,proc)
        pidfile();(data/'pg_wal').rmdir();(data/'pg_wal').symlink_to(other,target_is_directory=True)
        with self.assertRaises(ValueError):Z.database_volume(self.config,proc)
        (data/'pg_wal').unlink();(data/'pg_wal').mkdir();(data/'pg_tblspc/123').symlink_to(other,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'External database tablespaces'):Z.database_volume(self.config,proc)

    def test_postgres_ceiling_must_fit_projection_before_creating_whole_job(self):
        plan=self.witness_plan();self.register();job=Path(self.config['job_dir'])
        with patch.object(Z,'worker_identity',return_value=self.worker),patch.object(Z.tempfile,'tempdir',self.config['storage']['temporary']['worker_path']):
            for ceiling in (None,3*Z.GIB):
                with self.subTest(ceiling=ceiling),self.assertRaises(ValueError):T.prepare(self.root/'schedule',job,0,plan['partition_count'],resource_dir=self.output,postgres_bytes=ceiling)
                self.assertFalse(job.exists())
            req=T.prepare(self.root/'schedule',job,0,plan['partition_count'],resource_dir=self.output,postgres_bytes=128*1024**2)
            self.assertEqual(req['postgres_bytes'],128*1024**2)

    def test_successful_revocation_exit_differs_from_refusal_after_revocation(self):
        self.register()
        with patch.object(sys,'argv',['resources','revoke','--output-dir',str(self.output)]),patch.object(sys,'stdout',new_callable=io.StringIO):self.assertEqual(Z.main(),0)
        with patch.object(sys,'argv',['resources','renew','--output-dir',str(self.output)]),patch.object(sys,'stderr',new_callable=io.StringIO):self.assertEqual(Z.main(),3)

    def test_postgres_short_utc_timestamp_matches_resource_utc_format(self):
        self.assertEqual(Z.timestamp('2026-11-12 01:00:00+00'),Z.timestamp('2026-11-12T01:00:00+00:00'))
        for fraction in ('1','12','123','1234','12345','123456'):
            with self.subTest(fraction=fraction):self.assertEqual(Z.timestamp('2026-11-12 01:00:00.'+fraction+'+00'),Z.timestamp('2026-11-12T01:00:00.'+fraction.ljust(6,'0')+'+00:00'))


if __name__=='__main__':unittest.main()
