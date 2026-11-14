# Whole-source resource registration and admission

[source_execution_resources.py](../../tools/source_execution_resources.py) records
an operator-approved allocation, observes its resources and issues short-lived
leases for the [partition stream](partition-stream.md). The original
[source-run registration](source-run-registration.md) remains a planning record;
it cannot authorize whole-source execution.

This tool does not provision a host, reserve disk, create cgroups, grant access,
change database settings or start generation. Incomplete allocations produce
**blocked** records with explicit observed/unavailable states. Registration and
leases are never benchmark qualification receipts.

The [bounded metadata/STOP worker](resource-admission-trial.md) exercises an
existing live admission with operator-controlled revocation and separate resource
observation. It supplies no allocation or reference-qualification bypass.

## Prerequisites

- A dedicated Linux allocation with at least eight visible CPUs and 32 GiB RAM.
  PostgreSQL and worker must be the only children of the dedicated common
  cgroup-v2 parent checked by the [observer](../development/docker-resource-audit.md).
- A parent cap of eight CPUs, 28 GiB memory, no swap and 128–1,024 processes.
  Restrictive ancestors, missing counters, OOM events or excessive lifetime peak
  memory block admission. Child limits are recorded and must remain unchanged.
- An existing scoped non-root observer account with metadata access and authority
  to stop the owned pair. No host-wide root/ptrace workaround is supplied.
- Reservations and host/worker mappings for source, inventory, database, temporary
  and export storage. Pool IDs describe physical capacity, not aliases. One known
  filesystem cannot be split into multiple pools to inflate available space;
  filesystems sharing physical capacity must use one operator-supplied pool ID.
- An operator-reviewed projection and hashed evidence file. S1 uses a bounded
  witness; S2 requires an S1-calibration basis. Total projected growth is at most
  384 GiB. Each pool's reservation covers its summed role costs plus 25% headroom.
  Initially observed free space, counted once per pool, totals at least 512 GiB.
- A verified bounded source witness and exact database identity/settings snapshot.
  Locked local fixture target guards still apply. `huge_pages` must be `off`;
  separate HugeTLB accounting must not escape the memory envelope.

Allocation, reservations, scoped authority, cache lifecycle and projection review
are explicit operator attestations. Filesystem metadata cannot prove exclusive
physical capacity. The operator must establish the actual PGDATA, temporary and
output mappings. Registration and renewal verify the database mapping through
the registered postmaster's `/proc/PID/root` view: host/container directory
device and inode must agree, `postmaster.pid` must match the process namespace,
start time and port, and data/base/WAL must share the registered filesystem.
The scoped observer needs read/stat access to these specific paths; missing
access blocks admission. No Docker socket or extra host-wide capability is used.
The registered postgres init PID must be the postmaster. External/symlink WAL
and non-default tablespaces are unsupported and block admission (CLI exit 3).
The tool does not replace allocation or infrastructure review.
It checks projection identity/arithmetic, not the scientific validity of a cost
model or the contents of arbitrary evidence files. Leave attestations false when
those arrangements are unverified.

## Prepare a private specification

Freeze a source schedule and obtain its `partition_plan_sha256`. Generate an
exclusive, mode-0600 template outside the checkout:

```sh
python3 tools/source_execution_resources.py template \
  --job-dir /absolute/work/whole-job \
  --plan-sha256 PLAN_SHA256 --tier S1 \
  --output-file /absolute/private/allocation.json
```

The template is deliberately unapproved. Complete these fields after review:

| Field | Meaning |
|---|---|
| `allocation_id`, `operator_uid`, `expires_at` | Approved allocation and actual observer UID; UTC expiry at most eight hours after registration |
| `partition_plan_sha256`, `tier`, `job_dir` | Exact schedule/tier and worker-visible job output |
| `authority` | Explicit booleans for allocation, reservations, scoped access, stop authority, cache lifecycle and projection review |
| `common_parent`, `containers` | Host cgroup path, full Docker IDs and host init PIDs |
| `storage` | Five dedicated I/O-directory `host_path`/`worker_path`/`pool` mappings; source/inventory/export contain the job, temporary contains actual TMPDIR, database is the exact canonical PGDATA in the postgres container |
| `pools` | One `reserved_bytes` value per physical pool |
| `projection` | `basis`, `evidence_file`, ordinary file `sha256`, and `peak_bytes` for each role |
| `database` | Actual snapshot from the worker's fixture connection |

Capture the database snapshot inside the worker namespace, against already
provisioned fixture services, and copy the noncredential fields into the spec:

```sh
python3 tools/source_execution_resources.py database-identity \
  --state-dir /absolute/private/fixture-state
```

It includes database/owner/OID, postmaster start time, server version, loopback
address/port, initial database size and selected settings; no passwords. The size
is a measured growth baseline, not an editable capacity estimate. Register under the host observer
account outside the measured parent, with actual metadata/storage access:

```sh
python3 tools/source_execution_resources.py register \
  --allocation-file /absolute/private/allocation.json \
  --output-dir /absolute/private/resources \
  > /absolute/private/registration-report.json
```

Keep resources separate from the job, schedule, source registration and every
registered storage directory in both containment directions. Do not register an
entire shared parent such as `/tmp` if it also contains the resource metadata;
use dedicated sibling work/scratch/data directories instead. Mount
the metadata read-only into the worker, without another writable alias. Establish
required file-read permissions separately; the tool creates private files and
does not configure cross-account ACLs/mounts. Host and worker paths may differ
but must resolve to the registered filesystems. The host observer retains access
to the hashed projection evidence.

## Keep the lease live

`registration.json` is immutable. Each observation atomically replaces
`lease.json`, valid for at most ten seconds. An external operator controller must
renew it while the worker runs, for example:

```sh
while python3 tools/source_execution_resources.py renew \
  --output-dir /absolute/private/resources \
  > /absolute/private/latest-resource-lease.json; do
  sleep 2
done
```

Renewal rechecks boot/process/cgroup identity, membership, ancestor/child limits,
counters, projection evidence, filesystem identity and remaining space. Disk
growth beyond the projection or use of reserved headroom blocks renewal. CPU is
conservatively limited to 40 parent core-hours since registration, including
database/worker activity rather than claiming generation-only attribution.
Waiting consumes the eight-hour allocation window. Counter epochs must not
regress; statistics are not reset. An initially blocked record cannot become
ready through renewal.

The worker matches its PID namespace, cgroup inode/member limits, boot and
filesystem device/inode identities. These worker checks repeat at cooperative
lease checks during execution, including same-filesystem mapping changes.
Each invocation rechecks the source witness and exact
database/settings binding. During work, cooperative guards check the lease at
least every half second. Expiry, revocation or a blocked lease uses the existing
SQLite/owned-psql cancellation path. The observer itself signals no container.
Blocking operations and time between checks can overrun sampled budgets; kernel
caps and verified operator stop authority remain necessary. These observations
do not replace complete job telemetry or prove a cache-lifecycle claim.

An empty regular resource-directory `STOP` blocks workers and renewal. Permanent
revocation is explicit:

```sh
python3 tools/source_execution_resources.py revoke \
  --output-dir /absolute/private/resources
```

Expiry can recover through renewal within the unchanged allocation. Boot,
container/postmaster restart, code/settings or storage changes require a reviewed
new registration/job; existing work is never silently rebound. Revocation retains
evidence and candidate data. Guarded stream cleanup does not require a live lease.

Records are trusted operator-controlled local files, not cryptographic credentials
or protection against a hostile owner. Every record sets `qualifying=false`.
CLI exits: 0 success (including a successful `revoke`), 1 refusal, 2 syntax,
3 blocked, STOP, expired lease or refusal to use already-revoked resources.
