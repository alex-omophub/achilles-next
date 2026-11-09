"""Fetch only checksummed validation build inputs, with finite byte/time limits."""
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    root=Path('/opt/validation');lock=json.loads((root/'runtime-lock.json').read_text())
    downloads=root/'downloads';downloads.mkdir();jdbc=root/'jdbc';jdbc.mkdir()
    entries=[(lock['postgresql_client'],downloads/'postgresql.tar.bz2'),(lock['jdbc'],jdbc/lock['jdbc']['file'])]
    entries += [(p,downloads/(p['name']+'_'+p['version']+'.tar.gz')) for p in lock['R_packages']]
    for entry,path in entries:
        if not entry['url'].startswith('https://'):raise ValueError('HTTPS build sources required')
        subprocess.run(['curl','--fail','--location','--silent','--show-error','--connect-timeout','15',
            '--max-time','180','--max-filesize',str(64*1024**2),'--retry','2',entry['url'],'-o',str(path)],check=True,timeout=600)
        if path.stat().st_size>64*1024**2 or hashlib.sha256(path.read_bytes()).hexdigest()!=entry['sha256']:
            raise ValueError('Build source checksum mismatch: '+path.name)


if __name__=='__main__':main()
