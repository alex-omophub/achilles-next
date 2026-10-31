# Cancellation and isolated recovery

The synthetic PostgreSQL runner supports a durable cancellation request and a
linked recovery attempt. Old run history and any complete release remain intact.
A recovery target executes at most once; repeating the command observes that
same attempt. Work is recomputed because the current generators have no durable
immutable source snapshot assertion. Matching SQL, schema, vocabulary metadata
or source IDs alone cannot authorize reuse.

## Cancel a run

From a separate R process, use the run directory and the same marked-fixture
PostgreSQL role/database used for execution:

```r
library(AchillesNext)
source("tools/tracer_fixture_config.R") # Trusted contributor fixture configuration.
response <- cancelMeasurementRun("/path/to/run", config$connectionDetails)
response$database
inspectMeasurementRun("/path/to/run")$state$status
```

The request is recorded before signalling. `signal_sent` means PostgreSQL accepted
a query-cancellation signal; `acknowledged = TRUE` means the executor persisted
`cancelled`. These are separate facts. Supplying no connection details records a
cooperative request without opening a connection. A planned run sees that request
before connecting and records cancellation without executing queries.

An executing run registers a backend PID/start time, a run-specific PostgreSQL
application name and a hash of the marked database endpoint/role. The canceller
checks these before calling `pg_cancel_backend` from another connection. It does
not use backend termination or process killing and does not require an elevated
role. The PID is a backend process identity, not a warehouse query identifier.
The signal guard refuses stale/mismatched session identities. See PostgreSQL's
[server signalling functions](https://www.postgresql.org/docs/17/functions-admin.html#FUNCTIONS-ADMIN-SIGNAL)
and [session activity fields](https://www.postgresql.org/docs/17/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW).

The executor checks the durable request before/after operations and query calls.
Query/transaction failures cannot turn a pending cancellation into success. On
acknowledgement it rolls back/disconnects its own source connection, marks
remaining work cancelled, records cleanup and removes only its run's bundle
staging. A symlinked staging parent is refused for cleanup; other directories and
complete release stores are never traversed or removed. Earlier completed
operation timings remain factual, while the cancelled run's outputs are
unavailable and cannot publish. JDBC statement cleanup also attempts cancellation
when a query is interrupted before completion.

A request and the final run record use the same short control lock. A request
accepted first prevents a successful final record; a request arriving after a
terminal record is an explicit no-op. Requests and last signal receipts are local
control metadata, separate from the single-writer ledger and absent from exports.

Cancellation may remain unacknowledged during connection establishment, a network
stall, unavailable signal permissions or a hard-killed executor. The API reports
unavailable/no matching session rather than claiming success. Signalling does not
prove that a process has stopped; inspect the last persisted state and handle a
remaining stale lock explicitly. There is no stale-lock takeover or backend
termination. Existing completed/failed/cancelled runs are not relabelled by late
cancellation.

## Recover into a new attempt

```r
r <- resumeMeasurementRun("/path/to/old-run", "/path/to/new-attempt",
                          config$connectionDetails)
r$plan$recovery
r$state$status
r$state$input_identity
r$state$analytical_sha256
```

The original bounded request, source ID, marked schema, declared CDM version and
numeric strategy are retained. Recovery uses current installed definitions and a
new run ID, and records the parent plan/revision hashes, root run ID, chain attempt
number and the operations to recompute. A different request, schema or strategy
requires a new explicit `planMeasurementRun()` call. Configuration for a recovery
CLI supplies the connection; it cannot silently revise the recorded request.

`newRunDir` must be outside the old run directory, under an existing parent. It
is the idempotency key: repeated calls with the same parent and definitions return
the existing running/terminal attempt, or execute a matching unclaimed planned
attempt. Observing an existing target does not check contemporary source data;
choose a new target to analyze a changed source. A reused destination for another
parent or changed definitions is
rejected. Each actual operation has one attempt within that run; the recovery
lineage counts linked runs. To retry a failed/cancelled recovery, choose another
new directory using that attempt as the parent.

The old writer lock is never stolen or removed. This makes recovery possible
after hard termination without asserting that the old process is dead. A new
attempt may overlap an earlier live attempt, but owns its own connection/staging
and copies none of its work. Concurrent creation of the same new directory may
fail closed while its initial plan is incomplete; retry the same command after
initial creation finishes. If a recovery itself crashes, use another new target;
repeating a stale running target only inspects it. There is no automatic retry
loop, partial cache reuse or in-place resume of a dead writer.

Endpoint, schema/capability, declared vocabulary and aggregate terminology hashes
are recorded independently from source snapshot identity. The snapshot/data
release remains unknown. All recovery operations are recomputed, including after
source, vocabulary, schema or metric-definition changes and even when the
observed hashes match. There is no institutional immutability-assertion input in
this implementation. A future reuse path needs sufficient verified identity;
operator assertions cannot currently override recomputation.

Successful runs record canonical analytical hashes for person, observation and
measurement metric payloads (metric ID/version, state/reason and rows). They
exclude envelope IDs/request hashes, passport metadata and execution timings.
Unchanged analytical inputs/definitions produce the same hashes after recovery;
new run IDs, attempt/timing provenance and manifest hashes truthfully differ.
Publication is always a separate [approval step](publication.md); recovery never
changes `current.json` by itself.

## CLI

```sh
Rscript --vanilla tools/measurement_run.R cancel /path/to/run /path/to/config.R
Rscript --vanilla tools/measurement_run.R status /path/to/run --json
Rscript --vanilla tools/measurement_run.R resume /path/to/config.R /path/to/old-run /path/to/new-attempt
# retry is an alias of the same isolated recovery action.
Rscript --vanilla tools/measurement_run.R retry /path/to/config.R /path/to/old-run /path/to/another-attempt
```

Status and cancellation without configuration never evaluate a config file.
Resume/retry exits 0 only for a succeeded target, 2 for an observed running,
failed or cancelled target. Cancellation returns the request/acknowledgement and
signal result as JSON; callers must inspect state rather than assume a request
has stopped database work. These APIs operate on trusted local filesystems;
atomic renames/locks are not power-loss, network-filesystem or hostile-edit
protection.

## Contributor verification

After fixture setup and package installation:

```sh
Rscript --vanilla tests/tracer/recovery-offline.R
Rscript --vanilla tests/tracer/recovery.R tools/tracer_fixture_config.R /path/to/new-recovery-tests
```

The live test holds an exclusive lock on a disposable marked fixture table,
observes a worker blocked in PostgreSQL, signals it and verifies persisted
cancellation/cleanup. It also kills a test worker, recovers without touching its
old history/lock, compares analytical hashes, checks idempotent and concurrent
attempts, mutates synthetic source/vocabulary/schema and simulated prior metric
definitions, and screens artifacts against actual fixture credentials without
printing them. Python 3 is used only to manage independent test processes. The
same existing CI job runs recovery tests with the existing R installation.
