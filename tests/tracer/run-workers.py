"""Start independent R/JVM processes without R's asynchronous shell launcher."""
from pathlib import Path
import subprocess
import sys

rscript, script, config, evidence = sys.argv[1:]
root = Path(evidence)
workers = []
try:
    for name in ("parallel-a", "parallel-b"):
        log = (root / f"{name}.log").open("w")
        proc = subprocess.Popen(
            [rscript, "--vanilla", script, config, str(root / name), str(root / f"{name}.done")],
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
        )
        workers.append((proc, log))
    for proc, _ in workers:
        if proc.wait(timeout=40) != 0:
            raise RuntimeError("Synthetic run worker failed; inspect its private log")
finally:
    for proc, log in workers:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        log.close()
