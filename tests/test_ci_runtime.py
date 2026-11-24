"""Check CI cost controls without installing dependencies or starting Docker."""
from contextlib import redirect_stdout
from io import StringIO
import json
import os
import re
import runpy
from collections import Counter
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]


class CiRuntimeTests(unittest.TestCase):
    @staticmethod
    def integration_steps(workflow):
        # Parse the deliberately flat step list; workflow syntax is also checked
        # with actionlint. Do not silently accept new unrecognised conditions.
        section=workflow.split('  integration:\n',1)[1].split('\n  # Keep the existing required check name;',1)[0]
        return re.split(r'(?m)^      - ',section)[1:]

    def conformance_checks(self, args):
        # Exercise the real CLI and capture its child processes without starting
        # R, PostgreSQL or Node. Keep the expected suite inventory independent.
        script = ROOT / 'tools/check_conformance.py'
        with patch.object(sys, 'argv', [str(script), *shlex.split(args)]), \
                patch('subprocess.run') as run, redirect_stdout(StringIO()):
            runpy.run_path(str(script), run_name='__main__')
        commands = [list(map(os.fspath, call.args[0])) for call in run.call_args_list]
        files = []
        for command in commands:
            if command[0] == 'Rscript':
                self.assertEqual(command[1], '--vanilla')
                files.append(command[2:])
            else:
                self.assertIn(command[0], [sys.executable, 'node'])
                files.append(command[1:])
        producer = next(command for command in files if command[0] == 'tests/tracer/result-wire.R')
        consumers = [command for command in files if command[0] in (
            'packages/contracts/tools/validate-v2-corpus.mjs', 'tests/tracer/persistence-offline.R')]
        self.assertEqual(len(producer), 2)
        self.assertEqual(len(consumers), 2)
        for consumer in consumers:
            self.assertLess(files.index(producer), files.index(consumer), 'Generate the corpus before validating it')
            self.assertEqual(consumer[1:], producer[1:], 'Both validators must get the corpus just written')
        return [(command[0], shlex.join(command[1:])) for command in files]

    def check_suite_topology(self,workflow):
        self.assertIn('suite: [compatibility, domain, measurement]',workflow)
        self.assertIn('fail-fast: true',workflow)
        self.assertNotIn('continue-on-error:',workflow)
        assignments=[]
        for step in self.integration_steps(workflow):
            commands=re.findall(r'(?m)^\s*(?:run: )?(?:PGPASSFILE="[^"\n]*" |ACHILLES_NEXT_TEST_NUMERIC_STRATEGY=weighted )?(?:Rscript(?: --vanilla)?|python3|node) ((?:tests/tracer|tools|packages/contracts/tools)/[^\s]+)([^\n]*)',step)
            for path,args in commands:
                if not (path.startswith('tests/tracer/') or path.startswith('tools/test_') or path.startswith('tools/benchmark/') or
                        path in ('tools/check_conformance.py', 'packages/contracts/tools/validate-v2-corpus.mjs')):continue
                owner=re.search(r"(?m)^        if: matrix[.]suite == '(compatibility|domain|measurement)'$",step)
                self.assertIsNotNone(owner,'A test would run in every suite: '+path)
                assignments.append((path,args.strip(),owner[1]))
                if path == 'tools/check_conformance.py':
                    self.assertEqual(shlex.split(args)[0], 'postgresql')
                    assignments.extend((child, options, owner[1]) for child, options in self.conformance_checks(args))
        return assignments

    def test_all_integration_checks_have_one_suite_owner(self):
        workflow=(ROOT/'.github/workflows/count-tracer.yml').read_text();assignments=self.check_suite_topology(workflow)
        # Explicit coverage inventory: moving a suite must not omit or duplicate
        # an old check, including both measurement strategies and serving roles.
        core=['request.R','native-validation.R','result-validation-offline.R','baseline-reader-once.R','result-wire.R','result-store.R',
              'implementation-identity.R','recovery-offline.R','run-ledger-offline.R','recovery.R','publication.R','run-ledger.R',
              'postgresql.R','observation.R','quantile-request.R','measurement.R','measurement.R','analysis-definitions.R',
              'registered-profile-offline.R','source-store-offline.R','measurement-baseline-offline.R','refresh-contract-offline.R','core-metadata-offline.R',
              'persistence-offline.R','batch-plan.R','refresh-execution-offline.R','saved-selection.R','saved-transport.R','saved-provider.R','saved-concepts.R','saved-labels.R',
              'canonical-json.R','validation-spool.R','inventory-inputs.R','saved-walkthrough.R']
        expected=Counter(('tests/tracer/'+name,'compatibility') for name in core)
        expected.update({('tools/check_conformance.py','compatibility'):1,
                         ('packages/contracts/tools/validate-v2-corpus.mjs','compatibility'):1,
                         ('tools/test_result_serving.py','compatibility'):3,
                         ('tools/benchmark/weighted_quantiles.py','compatibility'):1,
                         ('tools/benchmark/batch_primitives.py','compatibility'):1,
                         ('tools/benchmark/inventory.py','compatibility'):1,
                         ('tests/tracer/domain-review-offline.R','domain'):1,
                         ('tools/test_population_baseline.py','domain'):1,
                         ('tools/test_domain_baseline.py','domain'):1,
                         ('tools/test_characterization_candidate_sql.py','domain'):1,
                         ('tools/test_measurement_baseline.py','measurement'):1,
                         ('tools/test_core_characterization.py','measurement'):1,
                         ('tools/test_characterization_refresh.py','measurement'):1,
                         ('tools/test_refresh_operations.py','measurement'):1})
        self.assertEqual(Counter((path,suite) for path,args,suite in assignments),expected)
        inventory=[shlex.split(args) for path,args,suite in assignments if path=='tools/benchmark/inventory.py']
        self.assertEqual(len(inventory),1)
        self.assertEqual(inventory[0][inventory[0].index('--entries')+1],'96')
        self.assertEqual(inventory[0][inventory[0].index('--samples')+1],'3')
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
        fixture_steps=[step for step in self.integration_steps(workflow)
                       if step.startswith('name: Verify incremental and streaming fixture transactions\n')]
        self.assertEqual(len(fixture_steps),1)
        fixture=fixture_steps[0]
        self.assertIn("if: matrix.suite == 'measurement'",fixture)
        self.assertEqual(re.findall(r'(?m)^          (python3 .+)$',fixture),[
            'python3 -m unittest discover -s tests -p test_incremental_source_load_postgresql.py',
            'python3 -m unittest discover -s tests -p test_partition_stream_postgresql.py',
            'python3 -m unittest discover -s tests -p test_resource_admission_trial.py'])
        self.assertIn('ACHILLES_NEXT_TEST_STATE: ${{ env.ACHILLES_NEXT_FIXTURE_STATE }}',fixture)
        self.assertIn('TMPDIR: ${{ runner.temp }}',fixture)
        self.assertIn('timeout-minutes: ${{ inputs.full_calendar && 60 || 30 }}',workflow)
        for step in self.integration_steps(workflow):
            if step==fixture:continue
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
                  if any(tool in line for tool in ['python3 tools/check_conformance.py postgresql','python3 tools/test_result_serving.py','python3 tools/test_characterization_refresh.py','python3 tools/test_refresh_operations.py','python3 tools/test_core_characterization.py'])]
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
            fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\nprint(json.dumps(dict(args=sys.argv[1:],options=os.getenv("PGOPTIONS"),application=os.getenv("PGAPPNAME"),timeout=os.getenv("PGCONNECT_TIMEOUT"),input=sys.stdin.read())))\n');fake.chmod(0o700)
            env=dict(os.environ,PATH=str(folder)+os.pathsep+os.environ['PATH'],PGOPTIONS='-c timezone=UTC',PGAPPNAME='ci-transport-test',PGCONNECT_TIMEOUT='5')
            result=subprocess.run(['sh',str(ROOT/'tools/ci/psql'),'-X','-c','SELECT 1'],input='input unchanged',capture_output=True,text=True,env=env,check=True)
            value=json.loads(result.stdout);self.assertEqual(value['args'][:2],['exec','-i'])
            self.assertIn('achillesnext-psql-client',value['args']);self.assertNotIn('run',value['args'])
            pairs=[value['args'][i:i+2] for i in range(len(value['args'])-1)]
            for name in ('PGOPTIONS','PGAPPNAME','PGCONNECT_TIMEOUT'):
                self.assertIn(['--env',name],pairs)
            # Docker starts a per-invocation supervisor in the existing client;
            # psql receives the original vector as shell positional arguments.
            command=value['args'][value['args'].index('achillesnext-psql-client')+1:]
            self.assertEqual(command[:2],['sh','-c'])
            self.assertEqual(command[3],'sh')
            self.assertRegex(command[4],r'^/tmp/achillesnext-psql[.][^/]+$')
            self.assertEqual(command[5:],['-X','-c','SELECT 1'])
            self.assertEqual(value['options'],'-c timezone=UTC');self.assertEqual(value['input'],'input unchanged')
            self.assertEqual(value['application'],'ci-transport-test');self.assertEqual(value['timeout'],'5')


if __name__=='__main__':unittest.main()
