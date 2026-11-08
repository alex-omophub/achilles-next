"""Independent fixture inventory arithmetic, determinism and write safety."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1]/'tools/benchmark/inventory_fixture.py'
SPEC = importlib.util.spec_from_file_location('inventory_fixture', MODULE)
FIXTURE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(FIXTURE)
sys.path.insert(0,str(MODULE.parent))
import inventory as PROTOCOL
sys.path.pop(0)


class InventoryFixtureTest(unittest.TestCase):
    def test_exact_inventory_determinism_and_saved_partition(self):
        with tempfile.TemporaryDirectory() as folder:
            a = Path(folder)/'a'; b = Path(folder)/'b'
            left = FIXTURE.build(a, 11, page_rows=3); right = FIXTURE.build(b, 11, page_rows=3)
            self.assertEqual(left, right)
            objects = list((a/'artifact/objects').iterdir())
            self.assertEqual(len(objects), left['inventory']['objects'])
            self.assertEqual(sum(p.stat().st_size for p in objects), left['inventory']['bytes'])
            concepts = []; names = []; counts = []
            for path in objects:
                raw = path.read_bytes(); doc = json.loads(raw)
                self.assertEqual(hashlib.sha256(raw).hexdigest(), path.stem)
                self.assertEqual(raw, FIXTURE.canonical(doc))
                if doc['kind'] == 'concept_catalogue':concepts.extend(doc['entries'])
                if doc['kind'] == 'terminology':names.extend(doc['entries'])
                if doc['kind'] == 'data' and doc['metric_id'] == 'core.person.gender_count':counts.extend(doc['rows'])
            self.assertEqual({e['concept_tag']['value'] for e in concepts}, {str(i) for i in range(1,12)})
            self.assertEqual(sorted(concepts,key=lambda e:e['concept_tag']['value']), sorted(names,key=lambda e:e['concept_tag']['value']))
            self.assertEqual(sum(int(r['values']['person_count']) for r in counts), 11)
            self.assertEqual(FIXTURE.id_key(9) < FIXTURE.id_key(10), True)
            self.assertEqual(len({r['row_key'] for r in counts}),11)
            with self.assertRaises(FileExistsError):FIXTURE.build(a,11)

    def test_bad_controls_do_not_create_output(self):
        with tempfile.TemporaryDirectory() as folder:
            for i,(count,page_rows) in enumerate([(0,3),(1000001,3),(True,3),(1,0),(1,513)]):
                path = Path(folder)/str(i)
                with self.assertRaises(ValueError):FIXTURE.build(path,count,page_rows)
                self.assertFalse(path.exists())

    def test_running_protocol_is_independent_of_later_source_edits(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); source=root/'tools/benchmark'; source.mkdir(parents=True)
            proof=root/'tests/tracer';proof.mkdir(parents=True)
            for path in [source/'inventory.R',source/'inventory-inputs.R',source/'implementation_identity.R',proof/'inventory-proof.R']:
                path.write_text('original\n')
            target=root/'snapshot'
            with patch.object(PROTOCOL,'__file__',str(source/'inventory.py')):
                command,env=PROTOCOL.protocol_command('read',root,root/'result.json',3,target)
            for path in [source/'inventory.R',source/'inventory-inputs.R',source/'implementation_identity.R',proof/'inventory-proof.R']:
                path.write_text('edited during run\n')
            self.assertEqual(Path(command[2]),target/'inventory.R')
            self.assertEqual(env['ACHILLES_NEXT_INVENTORY_PROTOCOL_DIR'],str(target))
            for path in target.iterdir():self.assertEqual(path.read_text(),'original\n')

    @unittest.skipUnless(hasattr(os,'wait4'),'Unix process telemetry')
    def test_failed_worker_keeps_its_exit_and_memory_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            log=Path(folder)/'failure.log'
            with self.assertRaisesRegex(RuntimeError,'worker failed'):
                PROTOCOL.measured([sys.executable,'-c','raise SystemExit(7)'],log)
            result=json.loads(log.with_suffix('.log.metrics.json').read_text())
            self.assertEqual(result['exit_code'],7)
            self.assertGreater(result['peak_process_rss_bytes'],0)

    def test_missing_telemetry_rejects_before_fixture_work(self):
        for phase in ['all','read','admit']:
            with tempfile.TemporaryDirectory() as folder,patch.dict(PROTOCOL.os.__dict__):
                PROTOCOL.os.__dict__.pop('wait4',None)
                output=Path(folder)/'must-not-exist'
                with patch.object(sys,'argv',['inventory.py',phase,'--output-dir',str(output)]),patch.object(PROTOCOL,'build') as build:
                    with self.assertRaisesRegex(RuntimeError,'Unix wait4'):
                        PROTOCOL.main()
                    build.assert_not_called()
                self.assertFalse(output.exists())

    def test_build_only_does_not_require_telemetry(self):
        with tempfile.TemporaryDirectory() as folder,patch.dict(PROTOCOL.os.__dict__):
            PROTOCOL.os.__dict__.pop('wait4',None);output=Path(folder)/'fixture'
            with patch.object(sys,'argv',['inventory.py','build','--output-dir',str(output),'--entries','1']):
                PROTOCOL.main()
            self.assertTrue((output/'fixture.json').is_file())

    def test_integrity_and_page_limits_survive_python_optimization(self):
        # Test in an actual -O interpreter, which removes Python assert guards.
        code='''
import json,sys,tempfile
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,sys.argv[1])
import inventory_fixture as fixture
with tempfile.TemporaryDirectory() as folder:
    root=Path(folder);(root/'inst/analysis').mkdir(parents=True);(root/'inst/contracts/v2').mkdir(parents=True)
    package=Path(fixture.__file__).resolve().parents[2]
    profile=(package/'inst/analysis/core-characterization-v2.json').read_bytes()
    rows=json.loads((package/'inst/contracts/v2/rows.json').read_bytes());rows['profile_sha256']='0'*64
    (root/'inst/analysis/core-characterization-v2.json').write_bytes(profile)
    (root/'inst/contracts/v2/rows.json').write_text(json.dumps(rows))
    with patch.object(fixture,'__file__',str(root/'tools/benchmark/inventory_fixture.py')):
        try:fixture.build(root/'bad-hash',1)
        except ValueError as error:
            if str(error)!='Profile hash does not match the row contract':raise
        else:raise RuntimeError('Optimized build accepted the wrong profile')
    with patch.object(fixture,'canonical',return_value=b'x'*4194305):
        try:fixture.build(root/'bad-size',1)
        except ValueError as error:
            if str(error)!='Fixture page exceeds physical byte limit':raise
        else:raise RuntimeError('Optimized build accepted an oversized page')
'''
        import subprocess
        subprocess.run([sys.executable,'-O','-c',code,str(MODULE.parent)],check=True)


if __name__ == '__main__':unittest.main()
