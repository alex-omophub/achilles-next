"""Frozen handoff input integrity and refusal before source access."""
import copy
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
    import source_analysis_handoff as H
finally:sys.path[:]=saved


class HandoffTests(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);self.home=Path(temp.name)
        self.directory=self.home/'handoff';self.directory.mkdir()
        self.source=H.S.Source();self.plan=self.source.plan();self.columns={t:{c['name']:c['type'] for c in cols} for t,cols in self.source.columns.items()}
        self.compiled=H.Reference('cdm_stream_'+'a'*16,self.columns).manifest()
        self.body=dict(kind='whole_source_analysis_handoff',version=1,stream_dir=str(self.home/'stream'),stream_request_sha256='b'*64,
            partition_plan_sha256='c'*64,audit_sha256='d'*64,source_schema='cdm_stream_'+'a'*16,source_marker=H.F.MARKER+': partition-stream:'+'b'*64,
            cdm_version='5.5',source_plan=self.plan,table_rows=self.source.counts,columns=self.columns,database={},measurement={},
            profile_sha256=H.S.BASE.sha(H.PROFILE_PATH.read_bytes()),code=H.pins(),consistency='test-only metadata',live_checks='not a live proof',
            analysis_execution_authorized=False,qualifying=False,reference_sha256=H.S.BASE.sha(H.S.BASE.canonical(self.compiled)))
        self.write(self.body)

    def write(self,body,compiled=None):
        digest=H.S.BASE.sha(H.S.BASE.canonical(body));value=dict(body,handoff_sha256=digest,source_id='fixture:stream:'+digest)
        (self.directory/'handoff.json').write_bytes(H.S.BASE.canonical(value))
        (self.directory/'reference.json').write_bytes(H.S.BASE.canonical(self.compiled if compiled is None else compiled))
        return value

    def test_static_inspection_binds_complete_reference_without_source_access(self):
        with patch.object(H.T.L,'Client',side_effect=AssertionError('no source connection for static inspect')):
            value=H.inspect(self.directory)
        self.assertEqual(set(value),H.FIELDS);self.assertFalse(value['analysis_execution_authorized']);self.assertFalse(value['qualifying'])
        self.assertEqual(len(self.compiled['queries']),138)
        self.assertGreater((self.directory/'reference.json').stat().st_size,H.M.JSON_BYTES)

    def test_rehashed_reference_edits_do_not_replace_the_frozen_compiler(self):
        compiled=copy.deepcopy(self.compiled);compiled['queries']['core.person.count']['sql']='SELECT 1'
        body=copy.deepcopy(self.body);body['reference_sha256']=H.S.BASE.sha(H.S.BASE.canonical(compiled));self.write(body,compiled)
        with self.assertRaisesRegex(ValueError,'identity differs'):H.inspect(self.directory)

    def test_shape_and_authority_changes_fail_even_with_recomputed_hash(self):
        for change in ('version','extra','scope','qualification','count','columns','marker','schema','source_plan','parent','hash'):
            with self.subTest(change=change):
                body=copy.deepcopy(self.body)
                if change=='version':body['version']=True
                elif change=='extra':body['extra']=0
                elif change=='scope':body['analysis_execution_authorized']=True
                elif change=='qualification':body['qualifying']=True
                elif change=='count':body['table_rows']['person']=True
                elif change=='columns':body['columns']['person']['person_id']=None
                elif change=='marker':body['source_marker']='unmarked'
                elif change=='schema':body['source_schema']='public'
                elif change=='source_plan':body['source_plan']['parameters']['cdm_version']='5.3'
                elif change=='parent':body['columns']=None
                else:body['audit_sha256']=True
                self.write(body)
                with self.assertRaises(ValueError):H.inspect(self.directory)

    def test_noncanonical_and_aliased_inputs_refuse(self):
        path=self.directory/'handoff.json';original=path.read_bytes();path.write_bytes(original+b' ')
        with self.assertRaises(ValueError):H.inspect(self.directory)
        path.write_bytes(original);reference=self.directory/'reference.json';external=self.home/'external';reference.rename(external);reference.symlink_to(external)
        with self.assertRaises(ValueError):H.inspect(self.directory)
        self.assertTrue(external.exists())

    def test_selected_and_stopped_jobs_refuse_before_database_access(self):
        T=H.T;reg=self.home/'registration';schedule=self.home/'schedule';stream=self.home/'stream'
        T.R.register(reg,'handoff-unit','S2','5.5',{r:str(self.home) for r in T.R.ROLES});plan=T.P.create(reg,schedule)
        T.prepare(schedule,stream,0,1)
        with patch.object(T.L,'Client',side_effect=AssertionError('no connection')):
            with self.assertRaisesRegex(ValueError,'whole-source stream'):H.prepare(stream,self.home,self.home/'output')
            (stream/'STOP').touch()
            with self.assertRaises(T.M.Stopped):H.prepare(stream,self.home,self.home/'output')
        self.assertFalse((self.home/'output').exists())

    def test_cancellation_during_compilation_refuses_output_creation(self):
        T=H.T;reg=self.home/'registration';schedule=self.home/'schedule';stream=self.home/'stream';stream.mkdir();state=self.home/'state';state.mkdir()
        T.R.register(reg,'handoff-stop','S2','5.5',{r:str(self.home) for r in T.R.ROLES});plan=T.P.create(reg,schedule)
        stopped=[False]
        def compile_now():stopped[0]=True;return self.compiled
        with patch.object(H,'capture',return_value=(self.body,plan)),patch.object(H,'Reference') as compiler:
            compiler.return_value.manifest.side_effect=compile_now
            with self.assertRaises(T.M.Stopped):H.prepare(stream,state,self.home/'output',stop=lambda:'requested' if stopped[0] else None)
        self.assertFalse((self.home/'output').exists())

    def test_changed_handoff_implementation_is_rejected(self):
        with patch.object(H,'SOURCE_SHA','0'*64),self.assertRaisesRegex(ValueError,'changed after import'):H.inspect(self.directory)


if __name__=='__main__':unittest.main()
