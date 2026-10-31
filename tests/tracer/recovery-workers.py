"""Bounded independent R/JVM workers for cancellation/recovery integration tests."""
import json
from pathlib import Path
import subprocess
import sys
import time

mode, rscript, script, config, root, parent = sys.argv[1:]
root = Path(root)
workers = []

def start(args, name):
    log = (root / f"{name}.log").open("w")
    proc = subprocess.Popen([rscript, "--vanilla", script, *args], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    workers.append((proc, log))
    return proc

def await_state(path):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        records = sorted((path / "ledger").glob("[0-9]*.json")) if path.exists() else []
        if records:
            state = json.loads(records[-1].read_text())["state"]
            if state["status"] != "planned" and state["status"] != "requested":
                return
        if workers[0][0].poll() is not None:
            raise RuntimeError("Worker stopped before recording an execution state")
        time.sleep(0.02)
    raise RuntimeError("Worker state deadline exceeded")

try:
    if mode in ("cancel", "kill"):
        proc = start(["worker", config, parent], mode)
        subprocess.run([rscript, "--vanilla", script, "control", config, parent, mode, str(proc.pid), str(root / "control.json")], check=True, timeout=30)
        code = proc.wait(timeout=20)
        if code != (0 if mode == "cancel" else -9):
            raise RuntimeError("Unexpected recovery worker exit")
    elif mode in ("parallel", "same-target"):
        first = root / "attempt-a"
        start(["resume", config, parent, str(first)], "attempt-a")
        await_state(first)
        second = first if mode == "same-target" else root / "attempt-b"
        start(["resume", config, parent, str(second)], "attempt-b")
        for proc, _ in workers:
            if proc.wait(timeout=30) != 0:
                raise RuntimeError("Recovery worker failed; inspect its test log")
    else:
        raise ValueError("Unknown test worker mode")
finally:
    for proc, log in workers:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        log.close()
