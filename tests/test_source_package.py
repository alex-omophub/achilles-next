"""Exercise the R source distribution with synthetic workstation files."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SourcePackageTests(unittest.TestCase):
    def test_local_files_excluded_and_release_assets_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder)
            # Seed only committed input, never a maintainer's local files.
            archive = work / 'snapshot.tar'
            subprocess.run(['git', 'archive', '--prefix=AchillesNext/', '-o', str(archive), 'HEAD'],
                           cwd=ROOT, check=True)
            subprocess.run(['tar', '-xf', str(archive)], cwd=work, check=True)
            source = work / 'AchillesNext'
            shutil.copyfile(ROOT / '.Rbuildignore', source / '.Rbuildignore')
            guide = Path('inst/guides/installation.md')
            (source / guide).parent.mkdir(exist_ok=True)
            shutil.copyfile(ROOT / guide, source / guide)
            expected = {
                path.relative_to(source).as_posix(): hashlib.sha256(path.read_bytes()).digest()
                for path in (source / 'inst').rglob('*') if path.is_file()
            }
            marker = b'ACHILLESNEXT_SYNTHETIC_BUILD_CANARY'
            canaries = [
                '.env', 'inst/.env.fixture', '.pgpass', 'src/test.pgpass', '.Renviron.fixture',
                'inst/example.key', 'jdbc/postgresql-test.jar', 'private/delivery.md',
                'config/connection.R', 'scratch/raw.csv', 'hs_err_pid12345.log',
                '.local/database.conf', 'artifacts/output.csv', 'tests/fixtures/raw.csv',
            ]
            for name in canaries:
                target = source / name
                self.assertFalse(target.exists(), name)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(marker)
            env = dict(os.environ, R_ENVIRON_USER=os.devnull, R_PROFILE_USER=os.devnull)
            subprocess.run(['R', 'CMD', 'build', '--no-build-vignettes', '--no-manual', 'AchillesNext'],
                           cwd=work, env=env, check=True)
            tarball, = work.glob('AchillesNext_*.tar.gz')
            actual_assets = {}
            with tarfile.open(tarball) as package:
                for member in package:
                    if member.isdir():
                        continue
                    self.assertTrue(member.isfile(), member.name)
                    name = Path(member.name).relative_to('AchillesNext').as_posix()
                    data = package.extractfile(member).read()
                    self.assertNotIn(name, canaries)
                    self.assertFalse(marker in data, name)
                    if name.startswith('inst/'):
                        actual_assets[name] = hashlib.sha256(data).digest()
            self.assertEqual(actual_assets, expected)


if __name__ == '__main__':
    unittest.main()
