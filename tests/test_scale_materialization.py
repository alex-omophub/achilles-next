"""Durable prefix, recovery, resource and source-identity controls on small jobs."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
_saved = sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    import scale_materialization as M
finally: sys.path[:] = _saved


@unittest.skipUnless(M.fcntl is not None, 'POSIX materialization locks')
class MaterializationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name); self.root = self.home/'job'

    def prepare(self, **kwargs):
        controls=dict(chunk_rows=4); controls.update(kwargs)
        return M.prepare(self.root,'S2','5.5',[dict(table='measurement',start=95,rows=10)],**controls)

    def state(self): return M.read_json(self.root/'checkpoint.json')

    def hashes(self, root=None):
        return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (root or self.root).iterdir() if p.is_file()}

    def test_streamed_partition_equals_source_and_complete_is_idempotent(self):
        self.prepare(); self.assertEqual(M.run(self.root)['status'],'complete')
        result = M.verify(self.root); self.assertEqual(result['rows'],10)
        merged = b''
        for index,chunk in enumerate(result['chunks']):
            raw = (self.root/chunk['file']).read_bytes()
            merged += raw if index==0 else raw.split(b'\n',1)[1]
        expected = io.BytesIO(); M.SCALE.render(M.SCALE.Source(),'measurement',95,10,expected)
        self.assertEqual(merged,expected.getvalue())
        before = self.hashes(); M.run(self.root)
        after = self.hashes(); before.pop('attempt.json'); after.pop('attempt.json')
        self.assertEqual(before,after); self.assertFalse(result['full_tier_generated']); self.assertFalse(result['qualifying'])

    def test_pause_and_resume_keep_committed_inode_and_duplicate_boundary(self):
        self.prepare(); stopped=M.run(self.root,max_chunks=1)
        self.assertEqual(stopped['status'],'stopped'); self.assertEqual(stopped['code'],3)
        self.assertEqual(len(self.state()['committed']),1); self.assertFalse((self.root/'complete.json').exists())
        st=(self.root/'chunk-000000.csv').stat()
        self.assertEqual(M.run(self.root)['status'],'complete')
        self.assertEqual((self.root/'chunk-000000.csv').stat().st_ino,st.st_ino)
        rows=[(self.root/f'chunk-{i:06}.csv').read_bytes().splitlines() for i in range(3)]
        self.assertEqual(rows[0][-1],rows[1][1])  # Physical indices98/99 repeat across chunks.

    def test_incomplete_or_bad_receipt_is_never_verified_or_overwritten(self):
        self.prepare(); M.run(self.root,max_chunks=1)
        with self.assertRaises(ValueError): M.verify(self.root)
        M.run(self.root); (self.root/'complete.json').write_bytes(b'corrupt')
        result=M.run(self.root); self.assertEqual(result['status'],'failed')
        self.assertEqual((self.root/'complete.json').read_bytes(),b'corrupt')

    def test_write_failure_recovers_only_valid_partial_prefix(self):
        self.prepare(); original=M.SCALE.Source.row
        def fault(source,table,index):
            if index==97: raise OSError('simulated write phase failure')
            return original(source,table,index)
        with patch.object(M.SCALE.Source,'row',fault): result=M.run(self.root)
        self.assertEqual(result['status'],'failed'); self.assertTrue((self.root/'chunk-000000.part').exists())
        self.assertEqual(self.state()['committed'],[])
        self.assertEqual(M.run(self.root)['status'],'complete'); M.verify(self.root)

    def test_invalid_partial_is_retained_without_deletion(self):
        self.prepare(); part=self.root/'chunk-000000.part'; part.write_bytes(b'foreign bytes')
        self.assertEqual(M.run(self.root)['status'],'failed')
        self.assertEqual(part.read_bytes(),b'foreign bytes'); self.assertEqual(self.state()['committed'],[])

    def test_published_orphan_is_verified_and_adopted_after_checkpoint_failure(self):
        self.prepare(); original=M.atomic_json
        def fault(root,name,value,exclusive=False):
            if name=='checkpoint.json': raise OSError('checkpoint write failed')
            return original(root,name,value,exclusive)
        with patch.object(M,'atomic_json',fault): result=M.run(self.root)
        self.assertEqual(result['status'],'failed'); self.assertEqual(self.state()['committed'],[])
        st=(self.root/'chunk-000000.csv').stat()
        self.assertEqual(M.run(self.root)['status'],'complete')
        self.assertEqual((self.root/'chunk-000000.csv').stat().st_ino,st.st_ino); M.verify(self.root)

    def test_crash_after_link_recovers_link_pair(self):
        self.prepare(); original=M.os.link
        def crash(source,target,**kwargs):
            original(source,target,**kwargs)
            if Path(source).suffix=='.part': raise SystemExit(99)
        with patch.object(M.os,'link',side_effect=crash),self.assertRaises(SystemExit): M.run(self.root)
        self.assertEqual((self.root/'chunk-000000.csv').stat().st_ino,(self.root/'chunk-000000.part').stat().st_ino)
        self.assertEqual(M.run(self.root)['status'],'complete'); self.assertFalse((self.root/'chunk-000000.part').exists())

    def test_missing_completion_is_recovered_after_last_checkpoint(self):
        self.prepare(); original=M.atomic_json
        def fault(root,name,value,exclusive=False):
            if name=='complete.json': raise OSError('receipt write failed')
            return original(root,name,value,exclusive)
        with patch.object(M,'atomic_json',fault): result=M.run(self.root)
        self.assertEqual(result['status'],'failed'); self.assertEqual(len(self.state()['committed']),3)
        before={p.name:p.stat().st_ino for p in self.root.glob('*.csv')}
        self.assertEqual(M.run(self.root)['status'],'complete'); M.verify(self.root)
        self.assertEqual(before,{p.name:p.stat().st_ino for p in self.root.glob('*.csv')})

    def test_crash_after_completion_link_is_recovered_without_overwrite(self):
        self.prepare(); original=M.os.link
        def crash(source,target,**kwargs):
            original(source,target,**kwargs)
            if Path(target).name=='complete.json': raise SystemExit(99)
        with patch.object(M.os,'link',side_effect=crash),self.assertRaises(SystemExit): M.run(self.root)
        before=(self.root/'complete.json').read_bytes(); inode=(self.root/'complete.json').stat().st_ino
        self.assertEqual(M.run(self.root)['status'],'complete'); M.verify(self.root)
        self.assertEqual((self.root/'complete.json').read_bytes(),before)
        self.assertEqual((self.root/'complete.json').stat().st_ino,inode)

    def test_committed_corruption_and_boolean_metadata_cannot_extend_prefix(self):
        self.prepare(); M.run(self.root,max_chunks=1); saved=(self.root/'checkpoint.json').read_bytes()
        file=self.root/'chunk-000000.csv'; raw=file.read_bytes(); file.write_bytes(b'bad')
        self.assertEqual(M.run(self.root)['status'],'failed'); self.assertEqual((self.root/'checkpoint.json').read_bytes(),saved)
        file.write_bytes(raw); cp=self.state(); field=next(k for k,v in cp['committed'][0]['null_counts'].items() if v==0)
        cp['committed'][0]['null_counts'][field]=False; M.atomic_json(self.root,'checkpoint.json',cp)
        self.assertEqual(M.run(self.root)['status'],'failed'); self.assertFalse((self.root/'chunk-000001.csv').exists())

    def test_data_corrupted_after_last_checkpoint_cannot_receive_completion(self):
        self.prepare(); original=M.atomic_json
        def corrupt(root,name,value,exclusive=False):
            original(root,name,value,exclusive)
            if name=='checkpoint.json' and len(value['committed'])==3:
                (root/'chunk-000000.csv').write_bytes(b'corrupt after write')
        with patch.object(M,'atomic_json',corrupt): result=M.run(self.root)
        self.assertEqual(result['status'],'failed'); self.assertFalse((self.root/'complete.json').exists())
        self.assertEqual((self.root/'chunk-000000.csv').read_bytes(),b'corrupt after write')

    def test_source_or_plan_change_refuses_without_touching_artifact(self):
        self.prepare(); M.run(self.root,max_chunks=1); before=self.hashes()
        recipe=json.loads(M.SCALE.RECIPE.read_text()); recipe['history_end']='2024-12-30'
        changed=self.home/'recipe.json'; changed.write_text(json.dumps(recipe))
        with patch.object(M.SCALE,'RECIPE',changed),self.assertRaises(ValueError): M.run(self.root)
        self.assertEqual(before,self.hashes())
        plan=M.read_json(self.root/'plan.json'); plan['limits']['csv_bytes']-=1
        M.atomic_json(self.root,'plan.json',plan)
        with self.assertRaises(ValueError): M.run(self.root)

    def test_csv_limit_is_cumulative_across_restart(self):
        source=M.SCALE.Source(); first=M.SCALE.render(source,'measurement',95,4)['bytes']
        self.prepare(byte_limit=first+1); self.assertEqual(M.run(self.root,max_chunks=1)['status'],'stopped')
        result=M.run(self.root); self.assertEqual(result['status'],'failed'); self.assertIn('byte budget',result['reason'])
        self.assertEqual(self.state()['csv_bytes'],first)
        self.assertLessEqual(sum(p.stat().st_size for p in self.root.glob('*.csv'))+sum(p.stat().st_size for p in self.root.glob('*.part')),first+1)

    def test_stop_file_and_signal_request_preserve_restart(self):
        self.prepare(); (self.root/'STOP').touch(); result=M.run(self.root)
        self.assertEqual(result['status'],'stopped'); self.assertFalse(list(self.root.glob('*.csv')))
        (self.root/'STOP').unlink(); original=M.SCALE.Source.row; reason=[None]
        def signal(source,table,index):
            if index==97: reason[0]='SIGTERM'
            return original(source,table,index)
        with patch.object(M.SCALE.Source,'row',signal): result=M.run(self.root,stop=lambda:reason[0])
        self.assertEqual(result['code'],143); self.assertEqual(self.state()['committed'],[])
        self.assertEqual(M.run(self.root)['status'],'complete')

    def test_deadline_and_free_space_stop_before_checkpoint_advances(self):
        self.prepare(seconds=1); original=M.SCALE.Source.row; clock=M.time.monotonic; expired=[False]
        def row(source,table,index):
            if index==97: expired[0]=True
            return original(source,table,index)
        with patch.object(M.SCALE.Source,'row',row),patch.object(M.time,'monotonic',side_effect=lambda:clock()+(2 if expired[0] else 0)):
            result=M.run(self.root)
        self.assertEqual(result['status'],'stopped'); self.assertEqual(result['reason'],'invocation_deadline')
        with patch.object(M.shutil,'disk_usage',return_value=type('Usage',(),{'free':0})()): result=M.run(self.root)
        self.assertEqual(result['status'],'failed'); self.assertEqual(self.state()['committed'],[])
        self.assertEqual(M.run(self.root)['status'],'complete')

    def test_initial_plan_validation_is_charged_to_invocation_deadline(self):
        self.prepare(seconds=1); clock=M.time.monotonic; original=M.load_plan; loaded=[False]
        def slow(root):
            plan=original(root); loaded[0]=True; return plan
        with patch.object(M,'load_plan',slow),patch.object(M.time,'monotonic',side_effect=lambda:clock()+(2 if loaded[0] else 0)):
            result=M.run(self.root)
        self.assertEqual(result['status'],'stopped'); self.assertEqual(result['reason'],'invocation_deadline')
        self.assertEqual(self.state()['committed'],[]); self.assertFalse(list(self.root.glob('*.part')))

    def test_unknown_symlink_and_external_hardlink_files_are_preserved(self):
        self.prepare(); keep=self.root/'keep'; keep.write_bytes(b'user file')
        self.assertEqual(M.run(self.root)['status'],'failed'); self.assertEqual(keep.read_bytes(),b'user file')
        keep.unlink(); outside=self.home/'outside'; outside.write_bytes(b'keep')
        (self.root/'chunk-000000.part').symlink_to(outside)
        self.assertEqual(M.run(self.root)['status'],'failed'); self.assertEqual(outside.read_bytes(),b'keep')
        (self.root/'chunk-000000.part').unlink(); M.run(self.root,max_chunks=1)
        os.link(self.root/'chunk-000000.csv',self.home/'external-link')
        self.assertEqual(M.run(self.root)['status'],'failed'); self.assertEqual(len(self.state()['committed']),1)

    def test_uncommitted_metadata_scratch_is_discarded_after_validation(self):
        self.prepare(); (self.root/'checkpoint.json.next').write_bytes(b'partial metadata')
        self.assertEqual(M.run(self.root)['status'],'complete'); self.assertFalse((self.root/'checkpoint.json.next').exists())

    def test_concurrent_cli_writer_is_refused_without_progress_change(self):
        self.prepare(); before=self.hashes()
        with M.locked(self.root):
            result=subprocess.run([sys.executable,str(ROOT/'tools/scale_materialization.py'),'run','--output-dir',str(self.root)],capture_output=True,text=True)
        self.assertEqual(result.returncode,1); self.assertNotIn('Traceback',result.stderr); self.assertEqual(before,self.hashes())

    def test_invalid_controls_never_create_directory_or_enable_large_tier(self):
        for kwargs in [dict(chunk_rows=0),dict(chunk_rows=10001),dict(seconds=float('nan')),dict(byte_limit=M.MAX_BYTES+1),dict(min_free=0)]:
            with self.subTest(kwargs=kwargs),self.assertRaises(ValueError): self.prepare(**kwargs)
            self.assertFalse(self.root.exists())
        for windows in [[dict(table='measurement',start=0,rows=100001)],
                        [dict(table='person',start=0,rows=4),dict(table='person',start=3,rows=1)],
                        [dict(table='../bad',start=0,rows=1)], [dict(table='person',start=True,rows=1)]]:
            with self.subTest(windows=windows),self.assertRaises(ValueError): M.prepare(self.root,'S2','5.5',windows)
            self.assertFalse(self.root.exists())
        with self.assertRaises(ValueError): M.prepare(self.root,'S2','5.5',[dict(table='measurement',start=0,rows=129)],chunk_rows=1)

    def test_prepare_refuses_dangling_and_existing_output_symlinks(self):
        for existing in [False,True]:
            with self.subTest(existing=existing):
                target=self.home/('existing' if existing else 'missing'); alias=self.home/('alias-'+str(existing))
                if existing:
                    target.mkdir(); (target/'keep').write_bytes(b'user content')
                alias.symlink_to(target,target_is_directory=True)
                with self.assertRaisesRegex(ValueError,'must not be a symlink'):
                    M.prepare(alias,'S2','5.5',[dict(table='measurement',start=0,rows=1)])
                self.assertTrue(alias.is_symlink())
                if existing:
                    self.assertEqual([p.name for p in target.iterdir()],['keep'])
                    self.assertEqual((target/'keep').read_bytes(),b'user content')
                else:self.assertFalse(target.exists())

    def test_prior_complete_selection_is_untouched_when_new_selection_fails(self):
        self.prepare(); M.run(self.root); before=self.hashes()
        other=self.home/'other'; M.prepare(other,'S2','5.5',[dict(table='measurement',start=0,rows=10)],byte_limit=1)
        self.assertEqual(M.run(other)['status'],'failed'); self.assertEqual(before,self.hashes()); M.verify(self.root)


if __name__ == '__main__': unittest.main()
