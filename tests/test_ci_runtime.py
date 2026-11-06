"""Check CI cost controls without installing dependencies or starting Docker."""
import json
import os
import re
from collections import Counter
import shlex
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class CiRuntimeTests(unittest.TestCase):
    @staticmethod
    def integration_steps(workflow):
        # Parse the deliberately flat step list; workflow syntax is also checked
        # with actionlint. Do not silently accept new unrecognised conditions.
        section=workflow.split('  integration:\n',1)[1].split('\n  # Keep the existing required check name;',1)[0]
        return re.split(r'(?m)^      - ',section)[1:]

    def check_suite_topology(self,workflow):
        self.assertIn('suite: [compatibility, domain, measurement]',workflow)
        self.assertIn('fail-fast: true',workflow)
        self.assertNotIn('continue-on-error:',workflow)
        assignments=[]
        for step in self.integration_steps(workflow):
            commands=re.findall(r'(?m)^\s*(?:run: )?(?:PGPASSFILE="[^"\n]*" |ACHILLES_NEXT_TEST_NUMERIC_STRATEGY=weighted )?(?:Rscript(?: --vanilla)?|python3) ((?:tests/tracer|tools)/[^\s]+)([^\n]*)',step)
            for path,args in commands:
                if not (path.startswith('tests/tracer/') or path.startswith('tools/test_') or path.startswith('tools/benchmark/')):continue
                owner=re.search(r"(?m)^        if: matrix[.]suite == '(compatibility|domain|measurement)'$",step)
                self.assertIsNotNone(owner,'A test would run in every suite: '+path)
                assignments.append((path,args.strip(),owner[1]))
        return assignments

    def test_all_integration_checks_have_one_suite_owner(self):
        workflow=(ROOT/'.github/workflows/count-tracer.yml').read_text();assignments=self.check_suite_topology(workflow)
        # Explicit coverage inventory: moving a suite must not omit or duplicate
        # an old check, including both measurement strategies and serving roles.
        core=['request.R','native-validation.R','result-validation-offline.R','baseline-reader-once.R','result-wire.R','result-store.R',
              'implementation-identity.R','recovery-offline.R','run-ledger-offline.R','recovery.R','publication.R','run-ledger.R',
              'postgresql.R','observation.R','quantile-request.R','measurement.R','measurement.R','analysis-definitions.R',
              'registered-profile-offline.R','source-store-offline.R','measurement-baseline-offline.R','refresh-contract-offline.R','core-metadata-offline.R',
              'persistence-offline.R','batch-plan.R','refresh-execution-offline.R']
        expected=Counter(('tests/tracer/'+name,'compatibility') for name in core)
        expected.update({('tools/test_result_serving.py','compatibility'):3,
                         ('tools/benchmark/weighted_quantiles.py','compatibility'):1,
                         ('tools/benchmark/batch_primitives.py','compatibility'):1,
                         ('tests/tracer/domain-review-offline.R','domain'):1,
                         ('tools/test_population_baseline.py','domain'):1,
                         ('tools/test_domain_baseline.py','domain'):1,
                         ('tools/test_measurement_baseline.py','measurement'):1,
                         ('tools/test_core_characterization.py','measurement'):1,
                         ('tools/test_characterization_refresh.py','measurement'):1,
                         ('tools/test_refresh_operations.py','measurement'):1})
        self.assertEqual(Counter((path,suite) for path,args,suite in assignments),expected)
        complete=[args for path,args,suite in assignments if path=='tools/test_core_characterization.py']
        self.assertEqual(len(complete),1)
        self.assertIn('--full-matrix',shlex.split(complete[0]))
        measurements=[args for path,args,suite in assignments if path=='tests/tracer/measurement.R']
        self.assertTrue(any('MEASUREMENT_TEST_BUNDLES' in args for args in measurements))
        self.assertTrue(any('WEIGHTED_TEST_BUNDLES' in args for args in measurements))
        self.assertIn('ACHILLES_NEXT_TEST_NUMERIC_STRATEGY=weighted Rscript tests/tracer/measurement.R',workflow)
        serving=[args for path,args,suite in assignments if path=='tools/test_result_serving.py']
        self.assertTrue(any('--test-script registered-profile' in args for args in serving))
        self.assertTrue(any('--test-script refresh-contract' in args for args in serving))
        self.assertEqual(sum('--test-script' not in args for args in serving),1)
        conformance=[args for path,args,suite in assignments if path=='tools/test_core_characterization.py']
        self.assertEqual(len(conformance),1)
        self.assertIn('--with-publication',conformance[0])
        for step in self.integration_steps(workflow):
            if any(command in step for command in ['actions/setup-node@','npm ci ','npm run package-viewer',
                                                   'npm run check','npm test','python3 -m unittest','node packages/contracts/']):
                self.assertIn("if: matrix.suite == 'compatibility'",step)
        self.assertIn('services:\n      postgres:',workflow)

    def test_required_tracer_gate_rejects_failure_cancellation_and_skips(self):
        gate=(ROOT/'.github/workflows/count-tracer.yml').read_text().split('\n  tracer:\n',1)[1]
        self.assertIn('if: always()',gate);self.assertIn('needs: integration',gate)
        self.assertIn('INTEGRATION_RESULT: ${{ needs.integration.result }}',gate)
        command=re.search(r'(?m)^        run: (.+)$',gate)[1]
        for status in ['success','failure','cancelled','skipped']:
            result=subprocess.run(['sh','-c',command],env=dict(os.environ,INTEGRATION_RESULT=status))
            self.assertEqual(result.returncode==0,status=='success')

    def test_serving_workflow_invocations_pass_admin_credentials(self):
        workflow=(ROOT/'.github/workflows/count-tracer.yml').read_text()
        commands=[shlex.split(line.strip()) for line in workflow.splitlines()
                  if any(tool in line for tool in ['python3 tools/test_result_serving.py','python3 tools/test_characterization_refresh.py','python3 tools/test_refresh_operations.py','python3 tools/test_core_characterization.py'])]
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
