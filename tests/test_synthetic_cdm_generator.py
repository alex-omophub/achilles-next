"""Deterministic bounded source bags, independent CSV facts and safe fixture writes."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT=Path(__file__).resolve().parents[1]
_path=sys.path[:]
try:
    sys.path.insert(0,str(ROOT/'tools'))
    import synthetic_cdm as GENERATOR
    import synthetic_cdm_database as DATABASE
    import synthetic_cdm_oracle as ORACLE
    import test_synthetic_cdm as CONTROLLER
finally:
    sys.path[:]=_path


def sandbox():
    pg=Mock()
    pg.rows.return_value=[dict(db='achilles_next_fixtures',usr='achilles_next_fixture_owner',marker=DATABASE.MARKER)]
    return pg


class SyntheticCdmTest(unittest.TestCase):
    def test_mixer_has_explicit_uint64_wrapping(self):
        for value in [0,1,2026110801,2**64-1,2**80+19]:
            self.assertEqual(GENERATOR.mix(value),GENERATOR.mix(value%(2**64)))
            self.assertEqual(GENERATOR.mix(value),GENERATOR.mix(value+2**64))
            self.assertLessEqual(GENERATOR.mix(value),2**64-1)

    def test_determinism_versions_and_independent_source_counts(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            for version,count in [('5.3',37),('5.4',39),('5.5',42)]:
                with self.subTest(version=version):
                    a=root/(version+'a');b=root/(version+'b')
                    left=GENERATOR.generate(a,version=version);right=GENERATOR.generate(b,version=version)
                    self.assertEqual(left,right);self.assertEqual(len(left['tables']),count)
                    self.assertEqual(left['rows_per_domain'],dict(condition=120,drug=180,procedure=80,visit=60,device=20,observation=100,death=1,specimen=19,measurement=420))
                    self.assertEqual(GENERATOR.verify(a),left)
                    for name in a.iterdir():self.assertEqual(name.read_bytes(),(b/name.name).read_bytes())
                    oracle=ORACLE.expected(a)
                    self.assertEqual(oracle['source_rows']['person'],20)
                    self.assertEqual(oracle['source_rows']['measurement'],420)
                    self.assertEqual(oracle['actual_duplicate_rows']['measurement'],4)
                    self.assertEqual(oracle['actual_duplicate_rows']['drug'],1)
                    self.assertEqual(oracle['actual_duplicate_rows']['condition'],1)
                    self.assertEqual(oracle['actual_duplicate_rows']['observation'],1)
                    self.assertEqual(oracle['observed_people'],18)
                    self.assertEqual(oracle['person_days'],18*61+2*16)
                    cols=left['tables']['observation']['columns']
                    self.assertEqual('value_as_date' in cols,version=='5.5')
                    self.assertEqual('value_source_value' in cols,version!='5.3')

    def test_seed_changes_data_and_small_rounding_preserves_total(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            for n in [0,1,7,99,1001]:
                m=GENERATOR.generate(root/str(n),events=n)
                self.assertEqual(sum(m['rows_per_domain'].values()),n)
            a=GENERATOR.generate(root/'a',seed=1);b=GENERATOR.generate(root/'b',seed=2)
            self.assertNotEqual(a['tables']['measurement']['sha256'],b['tables']['measurement']['sha256'])

    def test_empty_source_and_max_preview_remain_bounded(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);empty=GENERATOR.generate(root/'empty',people=0,events=0)
            self.assertEqual(empty['tables']['person']['rows'],0)
            self.assertTrue(all(n==0 for n in empty['rows_per_domain'].values()))
            maximum=GENERATOR.generate(root/'maximum',people=1000,events=10000)
            self.assertLess(maximum['bytes'],32*1024**2)
            self.assertEqual(sum(maximum['rows_per_domain'].values()),10000)

    def test_bad_controls_refuse_before_creating_output(self):
        cases=[dict(people=1001),dict(events=10001),dict(people=1000000,events=100000000),dict(events=-1),
               dict(people=True),dict(events=1.5),dict(seed=-1),dict(seed=2**32),dict(seed=True),
               dict(version='5.6'),dict(people=0,events=1)]
        with tempfile.TemporaryDirectory() as folder:
            for i,kw in enumerate(cases):
                path=Path(folder)/str(i)
                with self.subTest(kw=kw),self.assertRaises(ValueError):GENERATOR.generate(path,**kw)
                self.assertFalse(path.exists())
            with self.assertRaisesRegex(ValueError,'Preview requires'):
                GENERATOR.materialize(dict(people=1000000,events=100000000,seed=1,cdm_version='5.5'),Path(folder))
            self.assertEqual(list(Path(folder).iterdir()),[])

    def test_no_overwrite_and_failure_removes_only_owned_output(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);existing=root/'existing';existing.mkdir();keep=existing/'keep';keep.write_text('preserve')
            with self.assertRaises(FileExistsError):GENERATOR.generate(existing)
            with patch.object(GENERATOR,'MAX_BYTES',10),self.assertRaisesRegex(ValueError,'byte budget'):GENERATOR.generate(root/'partial')
            self.assertFalse((root/'partial').exists());self.assertEqual(keep.read_text(),'preserve')
            original=GENERATOR.rows
            def interrupted(*args):
                yield next(original(*args))
                raise KeyboardInterrupt()
            with patch.object(GENERATOR,'rows',interrupted),self.assertRaises(KeyboardInterrupt):GENERATOR.generate(root/'cancelled')
            self.assertFalse((root/'cancelled').exists())

    def test_pinned_ddl_mismatch_precedes_output(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);ddl=root/'ddl';ddl.mkdir()
            for name in ['5.5.sql','5.5-primary-keys.sql']:shutil.copyfile(GENERATOR.DDL/name,ddl/name)
            with (ddl/'5.5.sql').open('a') as stream:stream.write('\n-- changed\n')
            with patch.object(GENERATOR,'DDL',ddl),self.assertRaisesRegex(ValueError,'DDL hash'):GENERATOR.generate(root/'out')
            self.assertFalse((root/'out').exists())

    def test_rehashed_tamper_extra_files_and_symlinks_are_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);path=root/'fixture';m=GENERATOR.generate(path)
            csvfile=path/'person.csv';raw=csvfile.read_bytes();csvfile.write_bytes(raw+b'bad\n')
            changed=json.loads((path/'manifest.json').read_bytes());changed['tables']['person']['sha256']=hashlib.sha256(csvfile.read_bytes()).hexdigest()
            changed['tables']['person']['bytes']=csvfile.stat().st_size
            (path/'manifest.json').write_bytes(GENERATOR.canonical(changed))
            with self.assertRaisesRegex(ValueError,'replay mismatch'):GENERATOR.verify(path)
            csvfile.write_bytes(raw);(path/'manifest.json').write_bytes(GENERATOR.canonical(m))
            (path/'extra').write_text('extra')
            with self.assertRaisesRegex(ValueError,'Unexpected preview files'):GENERATOR.verify(path)
            (path/'extra').unlink();csvfile.unlink();csvfile.symlink_to(path/'measurement.csv')
            with self.assertRaisesRegex(ValueError,'size/type mismatch'):GENERATOR.verify(path)

    def test_csv_preserves_null_blank_quotes_tabs_backslashes_and_decimals(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)/'fixture';GENERATOR.generate(root)
            _,tables=ORACLE.read_tables(root)
            values={r['measurement_source_value'] for r in tables['measurement']}
            self.assertTrue({None,'',' ','\t','synthetic,"quote"','synthetic\\path'}<=values)
            self.assertTrue(any(r['value_as_number'].endswith('.000125') for r in tables['measurement'] if r['value_as_number']))
            self.assertEqual(tables['measurement'][98],tables['measurement'][99])

    def test_unmarked_or_tampered_input_never_mutates_database(self):
        pg=sandbox();pg.rows.return_value=[dict(db='postgres',usr='achilles_next_fixture_owner',marker=DATABASE.MARKER)]
        with self.assertRaisesRegex(ValueError,'marked fixture sandbox'):DATABASE.load_preview(pg,Path('/missing'))
        pg.run.assert_not_called()
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)/'fixture';GENERATOR.generate(root);(root/'person.csv').write_text('bad')
            pg=sandbox()
            with self.assertRaises(ValueError):DATABASE.load_preview(pg,root)
            pg.run.assert_not_called()

    def test_mutation_during_freeze_is_refused_before_ddl(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)/'fixture';GENERATOR.generate(root);pg=sandbox();copy=shutil.copyfile
            def race(src,dst):
                if Path(src).name=='person.csv':Path(src).write_text('changed after first verification')
                return copy(src,dst)
            with patch.object(DATABASE.shutil,'copyfile',race),self.assertRaises(ValueError):DATABASE.load_preview(pg,root)
            pg.run.assert_not_called()

    def test_loader_never_drops_existing_schemas_and_cleanup_checks_owner(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)/'fixture';GENERATOR.generate(root);pg=sandbox()
            pg.run.side_effect=RuntimeError('existing schema')
            with self.assertRaisesRegex(RuntimeError,'existing schema'):DATABASE.load_preview(pg,root)
            sql=pg.run.call_args.args[0];self.assertNotIn('DROP',sql);self.assertNotIn('IF NOT EXISTS',sql)
            self.assertIn('BEGIN;',sql);self.assertIn('COMMIT;',sql);self.assertIn('REVOKE ALL ON SCHEMA',sql)
            pg=sandbox();pg.rows.side_effect=[pg.rows.return_value,[dict(marker='right',owned=False)]]
            with self.assertRaisesRegex(ValueError,'unowned/unmarked'):DATABASE.drop_preview(pg,dict(schema='cdm_synthetic_'+'a'*12,marker='right'))
            pg.run.assert_not_called()

    def test_cli_cannot_execute_large_tier_or_ignore_verify_overrides(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'out';script=str(ROOT/'tools/generate_synthetic_cdm.py')
            result=subprocess.run([sys.executable,script,'build','--output-dir',str(path),'--events=100000000'],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0);self.assertFalse(path.exists())
            result=subprocess.run([sys.executable,script,'verify','--output-dir',str(path),'--events=1'],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0);self.assertIn('Verify uses only',result.stderr)

    def test_cleanup_failure_attempts_all_sources_and_cannot_write_success_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);out=root/'out';pg=sandbox();current={};loaded=[]
            def load(pg,directory):
                current.update(ORACLE.expected(directory)['source_rows'])
                manifest=json.loads((directory/'manifest.json').read_text())
                one=dict(schema='cdm_synthetic_'+str(len(loaded))*12,marker='test',version='5.5',
                         manifest_sha256=GENERATOR.sha(GENERATOR.canonical(manifest)))
                loaded.append(one);return one
            pg.value.side_effect=lambda sql:str(current[sql.rsplit('.',1)[1].strip('"')])
            def worker(*args,**kwargs):
                snapshots=[dict(manifest_sha256=x['manifest_sha256'],validated=True,
                    producer_source_access_revoked=True,datasets={str(i):{} for i in range(142)}) for x in loaded]
                (out/'results.json').write_text(json.dumps(dict(snapshots=snapshots)))
            argv=['test_synthetic_cdm.py','--state',str(root),'--config',str(root/'config.R'),'--output-dir',str(out)]
            with patch.object(sys,'argv',argv),patch.object(CONTROLLER,'Postgres',return_value=pg),\
                 patch.object(CONTROLLER,'load_preview',side_effect=load),\
                 patch.object(CONTROLLER,'drop_preview',side_effect=[RuntimeError('cleanup denied'),None]) as cleanup,\
                 patch.object(CONTROLLER.subprocess,'run',side_effect=worker),\
                 patch.object(CONTROLLER,'check_snapshot',return_value=dict(metrics=25,rows=1)):
                with self.assertRaisesRegex(RuntimeError,'Preview cleanup failed'):CONTROLLER.main()
            self.assertEqual(cleanup.call_count,2)
            self.assertFalse((out/'oracle.json').exists())


if __name__=='__main__':unittest.main()
