# Durable synthetic measurement execution

The optional run API wraps the existing exact measurement generator. It records
work before connecting and leaves an inspectable history after failure or process
exit. Existing `generateMeasurementReport()` calls retain their direct-bundle API.
Only the marked synthetic PostgreSQL sandbox is accepted.

```r
library(AchillesNext)
source("tools/tracer_fixture_config.R") # Trusted local configuration.
runDir <- tempfile("measurement-run-") # Parent must already exist.
planMeasurementRun(runDir, config$cdmSchema, config$sourceId, config$request,
                   config$declaredCdmVersion, numericStrategy = "weighted")
planned <- inspectMeasurementRun(runDir) # No connection needed.
executed <- executeMeasurementRun(runDir, config$connectionDetails)
executed$state$status
executed$state$operations
```

Run these contributor examples from the checkout root after fixture setup and
package installation. Connection details stay in the caller and are never written
to a plan or ledger. Raw SQL, raw driver errors, source records and frequency
rows are not stored. Run storage is restricted local working data, not an export
approved for sharing.

## Plan and sharing boundaries

`plan.json` is a fixed development-format plan (`0.1.0`), separate from the frozen
result contracts (`1.0.0` for direct generators, `1.1.0` for complete run outputs). It records the canonical bounded request and hash,
all fifteen requested metric IDs/versions, logical metric dependencies, physical
operations, descriptive resource classes, strategy, loaded implementation/SQL
fingerprints and runtime versions. Changed installed definitions require a new
plan. There is no arbitrary SQL, cube, concept expansion or operation plug-in API.
Resource classes are not measured cost or cardinality estimates.

The physical graph is:

```text
source.connect -> source.guard -> person.count -> observation.compute
                                                 -> measurement.compute
person.count + observation.compute + measurement.compute -> bundle.write
```

Measurement requires successful observation prerequisites. Bundle export waits
for terminal states so a failure can still be represented as a partial result.
Logical profile dependencies remain visible. The source guard now captures all
frozen capability probes in the same read-only session. Existing inline
prerequisite/type checks still control execution.

One observation computation supplies window/monthly denominators to measurement
outputs. Materialized CTEs share interval union results within the observation
statement and classified rows across measurement metric families. The frequency CTE stays
foldable for the reference strategy, which has one consumer; PostgreSQL can
materialize it by default for the weighted strategy, which shares it between
exact totals and weighted ranks. See
[PostgreSQL CTE materialization](https://www.postgresql.org/docs/17/queries-with.html#QUERIES-WITH-CTE-MATERIALIZATION).
Their compatibility boundary is the same
source, request window/concepts, strategy, definitions and read-only snapshot.
Observation membership is recomputed within measurement SQL; there is no
cross-statement interval cache or cross-run input reuse. The reference still sorts
physical eligible rows; weighted still ranks exact cumulative frequencies.

`maxConcurrency = 1` is the only supported value. It bounds operations within a
run, not all independent processes on an institution's database. Each execution
owns its read-only repeatable-read source connection, local staging folder and
run ID. No shared source table or durable scratch schema is created.

## Persisted state and telemetry

`ledger/00000000.json` first records requested work; the next revision records
planned work. Subsequent immutable snapshots persist operation start and terminal
states with causes, dependencies, one attempt, timestamps and measured elapsed
milliseconds. They distinguish requested, planned, running, succeeded, failed,
skipped and cancelled. A dependency skip has no fabricated duration. Completed
queries record SQL SHA-256, query/execute kind, duration and outcome. PostgreSQL
JDBC exposes no warehouse query ID; identifiers remain NULL with an explicit
reason. No backend PID is passed off as a query identifier.

Operation state describes computation; metric availability describes analytical
results. Empty populations and exact zero can be successful computations. A
failed query cannot become a succeeded requested metric. The bundle-write operation includes final manifest writing and validation. If
export or finalization fails, the operation is failed; previously completed
compute operations remain recorded, but no finalized metric success is inferred.
An existing unvalidated partial staging bundle is identified explicitly. The ledger is outside `staging/bundle`, so bundle cleanup does not
erase failure evidence.

The full-profile executor now exports all fifteen outputs using contract 1.1,
including capabilities, output status and timing. It validates staging before
recording metric success; failed or unsupported requested outputs still fail the
run. Successful staging remains partial and ineligible for current until the
separate [approved publication](publication.md) action. Execution success does
not assert disclosure approval, immutable source identity or reusable inputs.
Compute timing rows repeat their shared physical-operation duration; unmeasured
phases remain NULL with a reason. Direct generator APIs still produce their
partial contract 1.0 development bundles.

## CLI and inspection after restart

```sh
Rscript --vanilla tools/measurement_run.R plan /path/to/config.R /path/to/new-run
Rscript --vanilla tools/measurement_run.R execute /path/to/config.R /path/to/new-run
Rscript --vanilla tools/measurement_run.R status /path/to/new-run
Rscript --vanilla tools/measurement_run.R status /path/to/new-run --json
```

Plan/execute evaluate trusted configuration. Status never reads it or connects.
The text view exposes dependencies, causes, operation durations, explicit absent
query IDs and metric availability. JSON includes the full plan and committed
history. Execute exits 2 for failed/incomplete or cancelled work and 0 only for a
successful requested run; callers must check the state rather than infer success
from R function return alone.

A directory reservation isolates runs, and an atomic writer-lock directory admits
one executor. Each snapshot is written to a private temporary file then renamed
within the ledger directory. Readers check contiguous revision numbers, the plan
hash and the previous revision hash. Uncommitted temporary files are ignored;
missing or corrupt committed history fails closed. Files use mode 0600 and run
folders 0700 where supported by the operating system.

A caught R interrupt persists cancellation. The separate
[cancellation/recovery APIs](recovery.md) also record cooperative requests, target
the registered PostgreSQL query where available, and recover into a linked new
attempt. Unknown input identity forces full recomputation. Hard termination can
leave `running` and a writer lock; inspection reports last persisted facts without
claiming liveness. There is no stale-lock takeover or in-place resumption.
Atomic rename covers process interruption on trusted local filesystems, not
power-loss durability, network filesystem guarantees or authentication against
hostile edits. Do not import untrusted run directories.

Verify with `tests/tracer/run-ledger-offline.R` and the marked-database
`tests/tracer/run-ledger.R <config.R> <new-evidence-directory>`. The latter also
requires Python 3 for its concurrent worker launcher and installed contract
dependencies/Node for result validation.
