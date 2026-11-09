"""Fail-closed validation-volume and build/runtime boundary regressions."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('docker_validation_runner',ROOT/'tools/docker/runner.py')
RUN=importlib.util.module_from_spec(spec);spec.loader.exec_module(RUN)


class DockerValidationTest(unittest.TestCase):
    def shell_environment(self,root):
        binary=root/'bin';binary.mkdir();log=root/'docker.jsonl';output=root/'output';output.mkdir()
        fake=binary/'docker';fake.write_text('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['FAKE_DOCKER_LOG'],'a') as out:
 out.write(json.dumps(dict(args=sys.argv[1:],image=os.environ.get('ACHILLESNEXT_VALIDATION_IMAGE')))+'\\n')
if sys.argv[1:3]==['image','inspect']:print('sha256:'+('0'*64))
if 'run' in sys.argv and 'validator' in sys.argv and os.environ.get('FAKE_VALIDATOR_PASSES')!='1':raise SystemExit(7)
if 'stop' in sys.argv and os.environ.get('FAKE_STOP_FAILS')=='1':raise SystemExit(9)
''');fake.chmod(0o755)
        env=dict(os.environ,PATH=str(binary)+os.pathsep+os.environ['PATH'],FAKE_DOCKER_LOG=str(log),
            ACHILLESNEXT_VALIDATION_PROJECT='achillesnext-validation-test',ACHILLESNEXT_VALIDATION_OUTPUT=str(output),VALIDATION_UID='1000',VALIDATION_GID='1000')
        return env,log

    @unittest.skipUnless(os.name=='posix','POSIX wrapper')
    def test_wrapper_reports_cleanup_failure_after_successful_validation(self):
        with tempfile.TemporaryDirectory() as folder:
            env,log=self.shell_environment(Path(folder))
            env.update(FAKE_VALIDATOR_PASSES='1',FAKE_STOP_FAILS='1')
            result=subprocess.run(['sh',str(ROOT/'tools/docker/validate.sh'),'smoke'],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,1);self.assertIn('Could not stop',result.stderr)

    @unittest.skipUnless(os.name=='posix','POSIX wrapper')
    def test_wrapper_stops_only_its_database_after_failure_and_pins_image(self):
        with tempfile.TemporaryDirectory() as folder:
            env,log=self.shell_environment(Path(folder))
            result=subprocess.run(['sh',str(ROOT/'tools/docker/validate.sh'),'smoke'],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,7,result.stderr)
            calls=[json.loads(x) for x in log.read_text().splitlines()]
            self.assertEqual(calls[-1]['args'][-4:],['stop','--timeout','60','postgres'])
            self.assertTrue(all(c['args'][2:4]==['achillesnext-validation-test','--file'] for c in calls if c['args'][0]=='compose'))
            runs=[c for c in calls if 'run' in c['args']]
            self.assertEqual(len(runs),2);self.assertTrue(all(c['image']=='sha256:'+('0'*64) for c in runs))

    @unittest.skipUnless(os.name=='posix','POSIX wrapper')
    def test_wrapper_refuses_foreign_project_and_checkout_output_before_docker(self):
        with tempfile.TemporaryDirectory() as folder:
            env,log=self.shell_environment(Path(folder))
            for change in [dict(ACHILLESNEXT_VALIDATION_PROJECT='unrelated-production'),dict(ACHILLESNEXT_VALIDATION_OUTPUT=str(ROOT)),dict(ACHILLESNEXT_VALIDATION_OUTPUT=str(ROOT.parent))]:
                result=subprocess.run(['sh',str(ROOT/'tools/docker/validate.sh'),'smoke'],env=dict(env,**change),capture_output=True,text=True)
                self.assertEqual(result.returncode,2);self.assertFalse(log.exists())

    @unittest.skipUnless(hasattr(os,'chown'),'Unix validation volume ownership')
    def test_bootstrap_retains_password_and_refuses_foreign_marker(self):
        with tempfile.TemporaryDirectory() as folder,patch.object(RUN.os,'chown'):
            state=Path(folder)/'state';credentials=Path(folder)/'credentials'
            RUN.bootstrap(state,credentials,uid=1000,gid=1000)
            before=(credentials/'postgres_password').read_bytes()
            RUN.bootstrap(state,credentials,uid=1000,gid=1000)
            self.assertEqual((credentials/'postgres_password').read_bytes(),before)
            self.assertEqual((credentials/'postgres_password').stat().st_mode&0o777,0o600)
            (state/'docker-validation.json').write_text('{}')
            with self.assertRaisesRegex(ValueError,'ownership/marker'):RUN.bootstrap(state,credentials,uid=1000,gid=1000)
            self.assertEqual((credentials/'postgres_password').read_bytes(),before)

    @unittest.skipUnless(hasattr(os,'chown'),'Unix validation volume ownership')
    def test_bootstrap_rejects_unmarked_data_symlinks_and_root(self):
        with tempfile.TemporaryDirectory() as folder,patch.object(RUN.os,'chown'):
            root=Path(folder);state=root/'state';state.mkdir();(state/'unrelated').write_text('keep')
            with self.assertRaisesRegex(ValueError,'nonempty unmarked'):RUN.bootstrap(state,root/'credentials',1000,1000)
            self.assertEqual((state/'unrelated').read_text(),'keep')
            link=root/'link';link.symlink_to(state,target_is_directory=True)
            with self.assertRaisesRegex(ValueError,'Symlink'):RUN.bootstrap(link,root/'credentials',1000,1000)
            with self.assertRaisesRegex(ValueError,'Non-root'):RUN.bootstrap(root/'new',root/'credentials',0,0)

    def test_missing_cgroup_counters_are_not_zero_and_values_are_bounded(self):
        def missing(name):raise OSError('unreadable')
        values=RUN.cgroup_files(missing)
        self.assertTrue(all(x==dict(state='unavailable',raw=None) for x in values.values()))
        self.assertTrue(all(x['state']=='unavailable' for x in RUN.cgroup_files(lambda name:None).values()))
        values=RUN.cgroup_files(lambda name:'9\n' if name=='memory.peak' else 'x'*65537)
        self.assertEqual(values['memory.peak'],dict(state='available',raw='9\n'))
        self.assertEqual(values['cpu.stat']['state'],'unavailable')

    def test_source_manifest_detects_changes_and_excludes_host_dependencies(self):
        with tempfile.TemporaryDirectory() as folder,patch.object(RUN,'ROOT',Path(folder)):
            root=Path(folder);(root/'R').mkdir();(root/'R/example.R').write_text('42')
            (root/'node_modules').mkdir();(root/'node_modules/irrelevant').write_text('secret')
            before=RUN.source_pins();self.assertEqual(set(before),{'R/example.R'})
            (root/'R/example.R').write_text('43');self.assertNotEqual(before,RUN.source_pins())

    def test_build_lock_matches_fixture_tuple_and_dependency_closure(self):
        lock=json.loads((ROOT/'tools/docker/runtime-lock.json').read_text())
        fixture=json.loads((ROOT/'tests/fixtures/postgresql/lock.json').read_text())
        runtime=json.loads((ROOT/'tests/tracer/runtime-lock.json').read_text())
        self.assertEqual(lock['postgresql_client']['version'],fixture['psql_client'])
        self.assertEqual(lock['jdbc']['sha256'],runtime['jdbc_sha256'])
        for kind,text in [('r',(ROOT/'tools/docker/Dockerfile').read_text()),('node',(ROOT/'tools/docker/Dockerfile').read_text()),('postgres',(ROOT/'tools/docker/compose.yaml').read_text())]:
            self.assertIn(lock['images'][kind],text);self.assertRegex(lock['images'][kind],r'@sha256:[0-9a-f]{64}$')
        packages={p['name']:p for p in lock['R_packages']};self.assertEqual(len(packages),len(lock['R_packages']))
        self.assertEqual(packages['DatabaseConnector']['version'],runtime['DatabaseConnector'])
        done=set()
        while len(done)<len(packages):
            ready={n for n,p in packages.items() if set(p['dependencies'])<=done}-done
            self.assertTrue(ready,'Missing or cyclic build dependency');done|=ready
        for p in packages.values():self.assertRegex(p['sha256'],r'^[0-9a-f]{64}$')


if __name__=='__main__':unittest.main()
