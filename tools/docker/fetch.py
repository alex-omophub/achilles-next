"""Fetch only checksummed validation build inputs, with finite byte/time limits."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import urlsplit

MAX_BYTES=64*1024**2


def download(entry,path,byte_limit=MAX_BYTES):
    if urlsplit(entry['url']).scheme!='https':raise ValueError('HTTPS build sources required')
    process=None;owned=False
    try:
        with path.open('xb') as output,tempfile.TemporaryFile() as errors:
            owned=True;digest=hashlib.sha256();total=0
            process=subprocess.Popen(['curl','--fail','--location','--silent','--show-error',
                '--proto','=https','--proto-redir','=https','--connect-timeout','15',
                '--max-time','180','--retry','2',entry['url']],stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,stderr=errors)
            while True:
                chunk=process.stdout.read(min(65536,byte_limit-total+1))
                if not chunk:break
                total+=len(chunk)
                if total>byte_limit:raise ValueError('Build source exceeds byte limit: '+path.name)
                output.write(chunk);digest.update(chunk)
            code=process.wait(timeout=15)
            if code:raise RuntimeError('Build source transfer failed (curl exit '+str(code)+'): '+path.name)
            if digest.hexdigest()!=entry['sha256']:raise ValueError('Build source checksum mismatch: '+path.name)
    except BaseException:
        if owned:path.unlink(missing_ok=True)
        raise
    finally:
        if process is not None:
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait()
            process.stdout.close()


def main():
    root=Path('/opt/validation');lock=json.loads((root/'runtime-lock.json').read_text())
    downloads=root/'downloads';downloads.mkdir();jdbc=root/'jdbc';jdbc.mkdir()
    entries=[(lock['postgresql_client'],downloads/'postgresql.tar.bz2'),(lock['jdbc'],jdbc/lock['jdbc']['file'])]
    entries += [(p,downloads/(p['name']+'_'+p['version']+'.tar.gz')) for p in lock['R_packages']]
    for entry,path in entries:
        download(entry,path)


if __name__=='__main__':main()
