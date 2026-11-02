"""Check CI cost controls without installing dependencies or starting Docker."""
import json
import os
import shlex
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class CiRuntimeTests(unittest.TestCase):
    def test_serving_workflow_invocations_pass_admin_credentials(self):
        workflow=(ROOT/'.github/workflows/count-tracer.yml').read_text()
        commands=[shlex.split(line.strip()) for line in workflow.splitlines()
                  if 'python3 tools/test_result_serving.py' in line]
        self.assertGreaterEqual(len(commands),2)
        for args in commands:
            self.assertIn('PGPASSFILE=$GITHUB_WORKSPACE/.local/admin.pgpass',args[:args.index('python3')])
            self.assertEqual(args[args.index('--admin-user')+1],'postgres')

    def test_dependency_fingerprint_ignores_prose_but_tracks_imports(self):
        with tempfile.TemporaryDirectory() as folder:
            folder=Path(folder);description=folder/'DESCRIPTION';out=folder/'spec';original=(ROOT/'DESCRIPTION').read_text()
            def fingerprint(text):
                description.write_text(text)
                subprocess.run(['Rscript','--vanilla',str(ROOT/'tools/ci/r-dependency-spec.R'),str(description),str(out)],check=True,capture_output=True)
                return out.read_bytes()
            baseline=fingerprint(original)
            self.assertEqual(baseline,fingerprint(original.replace('Description:','Description: Prose change. ')))
            self.assertNotEqual(baseline,fingerprint(original.replace('Imports:','Imports: extraPackage, ')))

    def test_psql_reuses_client_and_forwards_environment_and_arguments(self):
        with tempfile.TemporaryDirectory() as folder:
            folder=Path(folder);fake=folder/'docker'
            fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\nprint(json.dumps(dict(args=sys.argv[1:],options=os.getenv("PGOPTIONS"),input=sys.stdin.read())))\n');fake.chmod(0o700)
            env=dict(os.environ,PATH=str(folder)+os.pathsep+os.environ['PATH'],PGOPTIONS='-c timezone=UTC')
            result=subprocess.run(['sh',str(ROOT/'tools/ci/psql'),'-X','-c','SELECT 1'],input='input unchanged',capture_output=True,text=True,env=env,check=True)
            value=json.loads(result.stdout);self.assertEqual(value['args'][:2],['exec','-i'])
            self.assertIn('achillesnext-psql-client',value['args']);self.assertNotIn('run',value['args'])
            pairs=[value['args'][i:i+2] for i in range(len(value['args'])-1)]
            self.assertIn(['--env','PGOPTIONS'],pairs)
            self.assertEqual(value['args'][-4:],['psql','-X','-c','SELECT 1'])
            self.assertEqual(value['options'],'-c timezone=UTC');self.assertEqual(value['input'],'input unchanged')


if __name__=='__main__':unittest.main()
