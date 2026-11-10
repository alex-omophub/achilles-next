"""Frozen registration, source witnesses and explicit non-admission boundaries."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
_saved=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    import source_run_registration as R
finally: sys.path[:]=_saved


class RegistrationCase(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.home=Path(temp.name); self.output=self.home/'registration'
        self.paths={role:str(self.home) for role in R.ROLES}

    def register(self,**kwargs):
        return R.register(self.output,'local-check','S2','5.5',self.paths,**kwargs)

    def rewrite(self,record):
        body={k:v for k,v in record.items() if k!='registration_sha256'}
        record['registration_sha256']=R.S.BASE.sha(R.S.BASE.canonical(body))
        R.M.atomic_json(self.output,'registration.json',record)

    def good_observations(self):
        def fact(value): return dict(state='observed',value=value)
        return dict(captured_at='2026-11-10T00:00:00+00:00',platform='Linux',architecture='aarch64',
            visible_cpus=fact(8),physical_memory_bytes=fact(32*1024**3),
            cgroup_memory_max=fact(dict(bytes=28*1024**3)),
            cgroup_cpu_max=fact(dict(quota_usec=800000,period_usec=100000)),
            storage={role:fact(dict(logical_device='42',total_bytes=2*1024**4,free_bytes=1024**4)) for role in R.ROLES})

class RegistrationTest(RegistrationCase):
    def test_roundtrip_is_historical_not_live_admission(self):
        record=self.register()
        with patch.object(R,'observe',side_effect=AssertionError('verify must not replace historical observations')):
            self.assertEqual(R.verify(self.output),record)
        self.assertEqual(record['status'],'planned_not_admitted')
        self.assertFalse(record['assessment']['full_tier_ready']); self.assertFalse(record['assessment']['execution_enabled'])
        self.assertFalse(record['full_tier_generated']); self.assertFalse(record['qualifying'])
        self.assertEqual(record['target']['parameters']['events'],100000000)
        self.assertEqual(record['target']['auxiliary_rows'],17050021)

    def test_capable_observations_cannot_admit_execution(self):
        observations=self.good_observations(); result=R.assessment(observations)
        self.assertFalse(result['execution_enabled']); self.assertFalse(result['full_tier_ready'])
        expected=[name+'_unverified' for name in R.UNVERIFIED]+[name+'_unavailable' for name in R.UNAVAILABLE]
        self.assertEqual(result['blocking_reasons'],sorted(expected))
        self.assertNotIn('cgroup_memory_max_below_reference',result['blocking_reasons'])

    def test_device_aliases_do_not_multiply_free_capacity(self):
        observations=self.good_observations()
        for index,role in enumerate(R.ROLES): observations['storage'][role]['value']['free_bytes']=100+index
        result=R.assessment(observations)
        self.assertEqual(result['logical_device_groups'],[dict(logical_device='42',roles=sorted(R.ROLES),free_bytes_min=100)])
        # Device numbers alone cannot prove physical pool identity/reservations.
        self.assertIn('storage_pool_reservations_unverified',result['blocking_reasons'])
        observations['storage']['temporary']['value']['logical_device']='43'
        self.assertEqual(len(R.assessment(observations)['logical_device_groups']),2)

    def test_insufficient_or_unavailable_limits_are_explicit(self):
        observations=self.good_observations()
        observations['visible_cpus']['value']=2; observations['physical_memory_bytes']['value']=4*1024**3
        observations['cgroup_memory_max']['value']['bytes']=2*1024**3
        observations['cgroup_cpu_max']['value']['quota_usec']=200000
        observations['storage']['database']=dict(state='unavailable',value=None)
        blockers=R.assessment(observations)['blocking_reasons']
        for reason in ['visible_cpus_below_reference','physical_memory_bytes_below_reference',
                       'cgroup_memory_max_below_reference','cgroup_cpu_max_below_reference','storage_unavailable:database']:
            self.assertIn(reason,blockers)

    def test_unbounded_cgroup_limits_do_not_claim_allocation(self):
        observations=self.good_observations()
        observations['cgroup_memory_max']['value']['bytes']=None
        observations['cgroup_cpu_max']['value']['quota_usec']=None
        self.assertIn('dedicated_allocation_unverified',R.assessment(observations)['blocking_reasons'])
        with patch.object(R,'disk',side_effect=OSError('not readable')):
            snapshot=R.observe(self.paths)
        self.assertTrue(all(v==dict(state='unavailable',value=None) for v in snapshot['storage'].values()))

    def test_malformed_observations_are_not_accepted_as_facts(self):
        invalid=[]
        for key,value in [('visible_cpus',dict(state='observed',value=True)),
                          ('physical_memory_bytes',dict(state='unavailable',value=32*1024**3)),
                          ('cgroup_memory_max',dict(state='observed',value=dict(bytes=-1))),
                          ('cgroup_cpu_max',dict(state='observed',value=dict(quota_usec=1,period_usec=0))),
                          ('captured_at','2026-11-10T00:00:00')]:
            d=self.good_observations(); d[key]=value; invalid.append(d)
        d=self.good_observations(); d['storage']['source']['value']['free_bytes']=True; invalid.append(d)
        d=self.good_observations(); d['storage']['source']['value']['free_bytes']=2**63; invalid.append(d)
        for observations in invalid:
            with self.subTest(observations=observations),self.assertRaises(ValueError): R.assessment(observations)

    def test_existing_output_and_symlinks_are_preserved(self):
        self.register(); before=(self.output/'registration.json').read_bytes()
        with self.assertRaises(FileExistsError): self.register()
        self.assertEqual((self.output/'registration.json').read_bytes(),before)
        alias=self.home/'alias'; alias.symlink_to(self.home/'absent')
        with self.assertRaises(ValueError): R.register(alias,'local-check','S2','5.5',self.paths)
        with self.assertRaises(ValueError): R.verify(alias)
        self.assertFalse((self.home/'absent').exists())

    def test_rehashed_admission_or_summary_tampering_fails(self):
        base=self.register()
        for field in ['qualifying','full_tier_generated']:
            record=copy.deepcopy(base); record[field]=True; self.rewrite(record)
            with self.assertRaisesRegex(ValueError,'identity/summary'): R.verify(self.output)
        record=copy.deepcopy(base); record['assessment']['full_tier_ready']=True; self.rewrite(record)
        with self.assertRaisesRegex(ValueError,'identity/summary'): R.verify(self.output)
        record=copy.deepcopy(base); record['assessment']['execution_enabled']=True; self.rewrite(record)
        with self.assertRaisesRegex(ValueError,'identity/summary'): R.verify(self.output)
        record=copy.deepcopy(base); record['status']='admitted'; self.rewrite(record)
        with self.assertRaisesRegex(ValueError,'identity/summary'): R.verify(self.output)
        record=copy.deepcopy(base); record['assessment']['blocking_reasons']=[]; self.rewrite(record)
        with self.assertRaisesRegex(ValueError,'identity/summary'): R.verify(self.output)

    def test_target_requirements_and_code_binding_cannot_drift(self):
        record=self.register(); record['reference_requirements']['cpus']=1; self.rewrite(record)
        self.assertEqual(R.REFERENCE['cpus'],8)
        with self.assertRaisesRegex(ValueError,'identity/summary'): R.verify(self.output)
        with patch.object(R,'SOURCE_SHA','0'*64),self.assertRaisesRegex(ValueError,'tool changed'): R.verify(self.output)

    def test_invalid_requests_never_create_output(self):
        for paths in [{},dict(self.paths,credentials='/secret'),dict(self.paths,source='relative'),dict(self.paths,source=1)]:
            with self.subTest(paths=paths),self.assertRaises(ValueError): R.register(self.output,'local-check','S2','5.5',paths)
        for name in ['','../run','UPPER','x'*65]:
            with self.subTest(name=name),self.assertRaises(ValueError): R.register(self.output,name,'S2','5.5',self.paths)
        self.assertFalse(self.output.exists())

    def test_unexpected_or_incomplete_registration_files_fail(self):
        self.output.mkdir()
        with self.assertRaises(ValueError): R.verify(self.output)
        self.output.rmdir(); self.register(); (self.output/'extra').write_text('unexpected')
        with self.assertRaises(ValueError): R.verify(self.output)


@unittest.skipUnless(R.M.fcntl is not None,'POSIX sample verifier')
class SampleRegistrationTest(RegistrationCase):
    def prepare_sample(self):
        self.source=self.home/'source'; self.inventory=self.home/'inventory'
        R.M.prepare(self.source,'S2','5.5',[dict(table='measurement',start=95,rows=12)],chunk_rows=4)
        self.assertEqual(R.M.run(self.source)['status'],'complete'); R.I.collect(self.source,self.inventory)

    def test_witness_is_verified_bound_and_never_extrapolated(self):
        self.prepare_sample(); before={p.name:p.read_bytes() for p in self.source.iterdir() if p.is_file()}
        record=self.register(source_dir=self.source,inventory_dir=self.inventory)
        self.assertEqual(record['sample']['selected_rows'],12)
        self.assertEqual(record['sample']['coverage'],'bounded_selection_only')
        self.assertEqual(R.verify(self.output),record)
        self.assertEqual(before,{p.name:p.read_bytes() for p in self.source.iterdir() if p.is_file()})
        R.M.atomic_json(self.inventory,'inventory.json',dict(status='edited'))
        with self.assertRaises((ValueError,KeyError)): R.verify(self.output)

    def test_mismatched_sample_target_or_unpaired_paths_fail(self):
        self.prepare_sample()
        with self.assertRaisesRegex(ValueError,'target differs'):
            R.register(self.output,'local-check','S1','5.5',self.paths,self.source,self.inventory)
        with self.assertRaisesRegex(ValueError,'both sample'): self.register(source_dir=self.source)
        self.assertFalse(self.output.exists())

    def test_output_must_not_contaminate_source_or_inventory(self):
        self.prepare_sample()
        for output in [self.source/'nested',self.inventory/'nested',self.home]:
            with self.subTest(output=output),self.assertRaisesRegex(ValueError,'Keep registration separate'):
                R.register(output,'local-check','S2','5.5',self.paths,self.source,self.inventory)
        alias=self.home/'alias'; alias.symlink_to(self.source,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'must not be symlinks'): self.register(source_dir=alias,inventory_dir=self.inventory)


if __name__=='__main__': unittest.main()
