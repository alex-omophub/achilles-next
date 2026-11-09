"""Fail-closed validation-volume and build/runtime boundary regressions."""
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import signal
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('docker_validation_runner',ROOT/'tools/docker/runner.py')
RUN=importlib.util.module_from_spec(spec);spec.loader.exec_module(RUN)
spec=importlib.util.spec_from_file_location('docker_validation_fetch',ROOT/'tools/docker/fetch.py')
FETCH=importlib.util.module_from_spec(spec);spec.loader.exec_module(FETCH)


class DockerValidationTest(unittest.TestCase):
    def shell_environment(self,root):
        binary=root/'bin';binary.mkdir();log=root/'docker.jsonl';output=root/'output';output.mkdir()
        fake=binary/'docker';fake.write_text('''#!/usr/bin/env python3
import json,os,sys,time
with open(os.environ['FAKE_DOCKER_LOG'],'a') as out:
 out.write(json.dumps(dict(args=sys.argv[1:],image=os.environ.get('ACHILLESNEXT_VALIDATION_IMAGE')))+'\\n')
if sys.argv[1:3]==['image','inspect']:print('sha256:'+('0'*64))
if 'run' in sys.argv and 'validator' in sys.argv and os.environ.get('FAKE_VALIDATOR_READY'):
 open(os.environ['FAKE_VALIDATOR_READY'],'w').close()
 time.sleep(20)
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
            stops=[c for c in calls if 'stop' in c['args']]
            self.assertEqual(len(stops),1)
            self.assertEqual(stops[0]['args'][-4:],['stop','--timeout','60','postgres'])
            self.assertFalse(any('down' in c['args'] for c in calls))
            self.assertTrue(all(c['args'][2:4]==['achillesnext-validation-test','--file'] for c in calls if c['args'][0]=='compose'))
            runs=[c for c in calls if 'run' in c['args']]
            self.assertEqual(len(runs),2);self.assertTrue(all(c['image']=='sha256:'+('0'*64) for c in runs))

    @unittest.skipUnless(os.name=='posix','POSIX signals')
    def test_wrapper_hangup_stops_only_its_database(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);env,log=self.shell_environment(root);ready=root/'ready'
            env['FAKE_VALIDATOR_READY']=str(ready)
            process=subprocess.Popen(['sh',str(ROOT/'tools/docker/validate.sh'),'smoke'],env=env,
                stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
            try:
                deadline=time.monotonic()+5
                while not ready.exists() and time.monotonic()<deadline:time.sleep(.02)
                self.assertTrue(ready.exists())
                os.killpg(process.pid,signal.SIGHUP);process.communicate(timeout=5)
                self.assertEqual(process.returncode,129)
                calls=[json.loads(x)['args'] for x in log.read_text().splitlines()]
                self.assertEqual([c[-4:] for c in calls if 'stop' in c],[['stop','--timeout','60','postgres']])
                self.assertFalse(any('down' in c for c in calls))
            finally:
                if process.poll() is None:os.killpg(process.pid,signal.SIGKILL);process.communicate()

    @unittest.skipUnless(os.name=='posix','POSIX wrapper')
    def test_wrapper_validates_both_identity_ranges_and_tag_before_docker(self):
        with tempfile.TemporaryDirectory() as folder:
            env,log=self.shell_environment(Path(folder))
            bad=[]
            for key in ['VALIDATION_UID','VALIDATION_GID']:
                bad.extend({key:v} for v in ['0','-1','2147483648','99999999999999999999999','1:1','invalid'])
            bad.extend(dict(ACHILLESNEXT_VALIDATION_TAG=t) for t in ['-debug','.debug','x'*129,'bad/tag'])
            for change in bad:
                with self.subTest(change=change):
                    result=subprocess.run(['sh',str(ROOT/'tools/docker/validate.sh'),'status'],env=dict(env,**change),capture_output=True,text=True)
                    self.assertEqual(result.returncode,2,result.stderr);self.assertFalse(log.exists())
            good=dict(env,VALIDATION_UID='000000000000000001',VALIDATION_GID='2147483647',ACHILLESNEXT_VALIDATION_TAG='_'+('x'*127))
            result=subprocess.run(['sh',str(ROOT/'tools/docker/validate.sh'),'status'],env=good,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr);self.assertTrue(log.exists())

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

    def test_client_version_pin_refuses_extended_numbers(self):
        self.assertTrue(RUN.client_version_matches('psql (PostgreSQL) 17.10','17.10'))
        self.assertTrue(RUN.client_version_matches('psql (PostgreSQL) 17.10 (Ubuntu)','17.10'))
        for value in ['17.10.1','117.10','17.100','.17.10','16.1.2']:
            with self.subTest(value=value):self.assertFalse(RUN.client_version_matches('psql (PostgreSQL) '+value,'16.1' if value=='16.1.2' else '17.10'))

    def download_process(self,data):
        class Input(io.BytesIO):
            consumed=0
            def read(self,size=-1):
                chunk=super().read(size);self.consumed+=len(chunk);return chunk
        class Process:
            returncode=None;terminated=False
            stdout=Input(data)
            def wait(self,timeout=None):
                if self.returncode is None:self.returncode=0
                return self.returncode
            def poll(self):return self.returncode
            def terminate(self):self.terminated=True;self.returncode=-15
            def kill(self):self.returncode=-9
        return Process()

    def test_download_verifies_digest_and_enforces_https_on_redirects(self):
        data=b'pinned source';process=self.download_process(data)
        entry=dict(url='https://example.invalid/source',sha256=hashlib.sha256(data).hexdigest())
        with tempfile.TemporaryDirectory() as folder,patch.object(FETCH.subprocess,'Popen',return_value=process) as popen:
            path=Path(folder)/'source';FETCH.download(entry,path)
            self.assertEqual(path.read_bytes(),data);args=popen.call_args.args[0]
            self.assertEqual(args[args.index('--proto')+1],'=https');self.assertEqual(args[args.index('--proto-redir')+1],'=https')
            self.assertTrue(process.stdout.closed)

    def test_download_rejects_http_before_launch_and_preserves_existing_files(self):
        with tempfile.TemporaryDirectory() as folder,patch.object(FETCH.subprocess,'Popen') as popen:
            path=Path(folder)/'source';path.write_bytes(b'keep')
            with self.assertRaisesRegex(ValueError,'HTTPS'):FETCH.download(dict(url='http://example.invalid',sha256='0'*64),path)
            with self.assertRaises(FileExistsError):FETCH.download(dict(url='https://example.invalid',sha256='0'*64),path)
            popen.assert_not_called();self.assertEqual(path.read_bytes(),b'keep')

    def test_download_checksum_failure_removes_only_its_partial_file(self):
        process=self.download_process(b'changed')
        with tempfile.TemporaryDirectory() as folder,patch.object(FETCH.subprocess,'Popen',return_value=process):
            path=Path(folder)/'source'
            with self.assertRaisesRegex(ValueError,'checksum mismatch'):FETCH.download(dict(url='https://example.invalid',sha256='0'*64),path)
            self.assertFalse(path.exists());self.assertTrue(process.stdout.closed)

    def test_unknown_length_download_stops_at_byte_cap_and_reaps_child(self):
        process=self.download_process(b'0123456789')
        with tempfile.TemporaryDirectory() as folder,patch.object(FETCH.subprocess,'Popen',return_value=process):
            path=Path(folder)/'source'
            with self.assertRaisesRegex(ValueError,'exceeds byte limit'):FETCH.download(dict(url='https://example.invalid',sha256='0'*64),path,byte_limit=4)
            self.assertEqual(process.stdout.consumed,5);self.assertTrue(process.terminated)
            self.assertFalse(path.exists());self.assertTrue(process.stdout.closed)

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
