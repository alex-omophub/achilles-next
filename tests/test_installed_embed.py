"""Opt-in mounting probe for the installed ESM using separate React and Vue hosts."""
from contextlib import ExitStack
import os
from pathlib import Path
import subprocess
import unittest

from test_local_viewer import InstalledViewerCase, LIBRARY


@unittest.skipUnless(LIBRARY and os.environ.get('ACHILLES_NEXT_EMBED_TEST') == '1',
                     'Set ACHILLES_NEXT_EMBED_TEST=1 and ACHILLES_NEXT_VIEWER_TEST_LIBRARY')
class InstalledEmbedTests(InstalledViewerCase):
    def test_react_and_vue_mount_the_installed_module(self):
        tests = Path(__file__).resolve().parent
        env = dict(os.environ, R_LIBS=LIBRARY)
        embed = subprocess.check_output([
            self.rscript, '--vanilla', '-e',
            'library(AchillesNext); cat(system.file("embed", package="AchillesNext", mustWork=TRUE))',
        ], env=env, text=True)
        with ExitStack() as servers:
            urls = []
            for key in ('first', 'second'):
                folder = self.root / key
                trusted = self.root / (key + '-approval.json')
                subprocess.run([
                    self.rscript, '--vanilla', '-e',
                    'args <- commandArgs(TRUE); library(AchillesNext); source(args[1]); '
                    'x <- makeSavedResultFixture(args[2], pageRows=32L, sourceId=args[3], extraConceptIds=as.character(301:318)); '
                    'jsonlite::write_json(x$context, args[4], auto_unbox=TRUE)',
                    str(tests / 'tracer' / 'saved-result-fixture.R'), str(folder), 'fixture:' + key, str(trusted),
                ], check=True, env=env)
                urls.append(servers.enter_context(self.serving(folder, trusted_context=trusted,
                                                              admission=self.root / (key + '-context.json'))))
            subprocess.run(['node', 'tests/browser/installed-embed/run.mjs', str(self.root), embed, *urls],
                           cwd=tests.parent / 'packages' / 'tracer', check=True, timeout=120)


if __name__ == '__main__':
    unittest.main()
