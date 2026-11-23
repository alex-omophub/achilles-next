"""Opt-in real Chromium checks for the installed standalone and two embedded viewers."""
import contextlib
import os
from pathlib import Path
import subprocess
import unittest

from test_local_viewer import InstalledViewerCase, LIBRARY


@unittest.skipUnless(LIBRARY and os.environ.get('ACHILLES_NEXT_BROWSER_TEST') == '1',
                     'Set ACHILLES_NEXT_BROWSER_TEST=1 and ACHILLES_NEXT_VIEWER_TEST_LIBRARY')
class DomainWorkspaceTests(InstalledViewerCase):
    def test_installed_and_embedded_domain_navigation(self):
        tests = Path(__file__).resolve().parent
        fixture = tests / 'tracer' / 'saved-result-fixture.R'
        tracer = tests.parent / 'packages' / 'tracer'
        with contextlib.ExitStack() as servers:
            urls = []
            for source in ('first', 'second'):
                folder = self.root / source
                approved = self.root / (source + '.json')
                subprocess.run([
                    self.rscript, '--vanilla', '-e',
                    'args <- commandArgs(TRUE); library(AchillesNext); source(args[1]); '
                    'fixture <- makeSavedResultFixture(args[2], pageRows=32L, '
                    'extraConceptIds=as.character(100:115), sourceId=args[3], saveCalendar=TRUE, saveBirthYears=TRUE); '
                    'jsonlite::write_json(fixture$context, args[4], auto_unbox=TRUE)',
                    str(fixture), str(folder), 'fixture:' + source, str(approved),
                ], check=True, env=dict(os.environ, R_LIBS=LIBRARY))
                urls.append(servers.enter_context(self.serving(folder, trusted_context=approved)))
            subprocess.run(['node', 'tests/browser/domain-workspaces.mjs', *urls],
                           cwd=tracer, check=True, timeout=120)


if __name__ == '__main__':
    unittest.main()
