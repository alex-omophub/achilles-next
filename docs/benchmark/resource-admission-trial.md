# Registered metadata and STOP trial worker

[resource_admission_trial.py](../../tools/resource_admission_trial.py) exercises
the worker side of an existing [resource admission](source-execution-resources.md).
It checks the registered worker/storage bindings, live lease, pinned local fixture
server and database settings before connecting the trial to its evidence output.
It then performs fixed metadata-only queries with PostgreSQL's default read-only
transactions enabled. It never reads OMOP rows, generates a source, writes a
result store, publishes results, renews admission or provisions resources.

This contributor tool is one component of the operator's resource trial. It does
not establish common-parent telemetry, exclusive reservations, cache conditions,
SQL cancellation latency or S1/S2/benchmark qualification. An actual registered
allocation and scoped operator are still required. No smaller-machine bypass is
provided; an unapproved/blocked registration refuses before connection or output.

## Run inside the registered worker

Use the existing marked fixture service state and a **new** evidence directory
under the registered worker-visible export directory. The evidence directory must
be separate from the resource registration, fixture state, source job and cost
projection evidence. Its parent must already exist.

```sh
python3 tools/resource_admission_trial.py \
  --resource-dir /shared/private/resources \
  --state-dir /validation/state/postgresql \
  --output-dir /registered/export/stop-trial-01 \
  --seconds 10
```

The deadline is an integer from 1 to 30 seconds, including preflight and queries.
Queries and cancellation use the existing bounded fixture client. Settlement of
an already-running owned psql process can add its bounded signal/wait grace.
There is no arbitrary SQL or shell-command input. Probes are at least 250 ms
apart, capped at 120 journal frames and 64 KiB. Existing output is never reused.

## Operator coordination

Run the existing [common-parent observer](../development/docker-resource-audit.md)
separately under the scoped observer identity. Keep admission renewed using the
existing `source_execution_resources.py renew` command while the worker runs;
the worker never renews its own authority. Preserve that observer journal and
the allocation/lease evidence separately for review.

Wait for the worker's `ready.json`. It means that a read-only metadata query has
**completed**, not that a long SQL statement is currently executing. Then use the
existing `source_execution_resources.py revoke --output-dir ...` command, or
create a regular empty `STOP` file in that resource-registration directory.
This deliberately stops admission for the entire registered source job. Coordinate
it while that allocation is idle; this tool does not stop or resume other jobs.
STOP/revocation is retained. Do not remove it automatically to resume work.

A passed result requires at least one completed metadata probe followed by the
actual resource STOP/revocation. Initial STOP, lease expiry/loss, deadline,
unavailable settings, wrong worker/target, code drift, malformed control files
and observation/output errors do not pass. They either refuse preflight or leave
a failed result with bounded evidence. A callback claiming STOP without the real
control cannot manufacture success. Abrupt process termination can prevent a
terminal result; retained request/journal files are not a passing receipt.

## Evidence and interpretation

The mode-0600 files in the mode-0700 trial directory are:

- `request.json`: trial, registration, schedule/job/tier and implementation pins;
  initial database identity/settings and application name.
- `samples.jsonl`: fsynced, bounded read-only metadata observations.
- `ready.json`: the exact trial/registration binding after the first observation.
- `trial.json`: terminal status, STOP reason, completed frame/byte counts and
  journal/result hashes. `qualifying`, `allocation_qualified`, `source_scanned`
  and `lease_renewed` remain false.

CLI exit zero means the worker completed this narrow STOP exercise. Refusal or a
failed result is nonzero. It is not approval for large generation or an end-to-end
resource/cancellation performance claim. Inspect the actual common-parent audit,
operator actions and all failures together before approving any reference trial.
No source job, previous analytical publication or resource registration is edited
by the worker.
