"""Bounded independent R/JVM workers for cancellation/recovery integration tests."""
import json
from pathlib import Path
import subprocess
import sys
import time

mode, rscript, script, config, root, parent = sys.argv[1:]
root = Path(root)
workers = []
release = root / "release-lock"

def start(args, name):
    log = (root / f"{name}.log").open("w")
    proc = subprocess.Popen([rscript, "--vanilla", script, *args], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    workers.append((proc, log))
    return proc

def state(path):
    records = sorted((path / "ledger").glob("[0-9]*.json")) if path.exists() else []
    return json.loads(records[-1].read_text())["state"] if records else None

def wait_for(condition, proc):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        if proc.poll() is not None:
            raise RuntimeError("Worker stopped before reaching the synchronized state")
        time.sleep(0.02)
    raise RuntimeError("Worker synchronization deadline exceeded")

def computing(path):
    current = state(path)
    return current and current["status"] == "running" and current["operations"]["measurement.compute"]["status"] == "running"

try:
    if mode in ("cancel", "kill"):
        proc = start(["worker", config, parent], mode)
        subprocess.run([rscript, "--vanilla", script, "control", config, parent, mode, str(proc.pid), str(root / "control.json")], check=True, timeout=30)
        code = proc.wait(timeout=20)
        if code != (0 if mode == "cancel" else -9):
            raise RuntimeError("Unexpected recovery worker exit")
    elif mode in ("parallel", "same-target", "claim-race"):
        # A separate owner connection holds the test table lock until overlap
        # has been observed. A terminal first worker can never satisfy this test.
        locked = root / "locked"
        holder = start(["hold", config, str(locked), str(release)], "lock-holder")
        wait_for(locked.exists, holder)
        first = root / "attempt-a"
        second = root / "attempt-b" if mode == "parallel" else first
        result_a, result_b = root / "a-result.json", root / "b-result.json"
        action = "race-resume" if mode == "claim-race" else "resume"
        a = start([action, config, parent, str(first), str(result_a)], "attempt-a")
        if mode == "claim-race":
            wait_for(Path(str(result_a) + ".ready").exists, a)
        else:
            wait_for(lambda: computing(first), a)
        b = start([action, config, parent, str(second), str(result_b)], "attempt-b")
        evidence = {}
        if mode == "claim-race":
            wait_for(Path(str(result_b) + ".ready").exists, b)
            evidence.update(both_ready=True, planned_at_gate=state(first)["status"] == "planned")
            assert evidence["planned_at_gate"] and not (first / ".writer-lock").exists()
            (root / "go").touch()  # Both passed the planned/unlocked pre-check.
            wait_for(lambda: computing(first), holder)
            wait_for(lambda: result_a.exists() or result_b.exists(), holder)
            observed = json.loads((result_a if result_a.exists() else result_b).read_text())
            assert observed["state"] == "running"
            assert a.poll() is None or b.poll() is None
        elif mode == "same-target":
            wait_for(result_b.exists, b)
            observed = json.loads(result_b.read_text())
            assert observed["state"] == "running" and a.poll() is None
        else:
            wait_for(lambda: computing(second), b)
            assert a.poll() is None and b.poll() is None
        evidence.update(first_state=state(first)["status"], second_state=state(second)["status"])
        assert evidence["first_state"] == evidence["second_state"] == "running"
        (root / "overlap.json").write_text(json.dumps(evidence))
        release.touch()
        for proc, _ in workers:
            if proc.wait(timeout=30) != 0:
                raise RuntimeError("Recovery worker failed; inspect its test log")
    else:
        raise ValueError("Unknown test worker mode")
finally:
    release.touch()
    for proc, log in workers:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        log.close()
