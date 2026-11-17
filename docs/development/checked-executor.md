# Checked PostgreSQL execution

`renderCharacterizationSql()` produces SQL offline. `executeCharacterizationSql()`
executes a current compiler program through one owned PostgreSQL repeatable-read
transaction and delivers restricted aggregate records to a callback. Source scans,
joins, exact statistics and temporary materializations run on PostgreSQL. The
client does not retrieve clinical source rows.

The worker requires SELECT-only source access and permission to create temporary
tables. It has no result-store schema argument and performs no publication. On
success it confirms rollback and disconnection before returning a receipt;
temporary tables belong only to that connection. On failure it attempts both
cleanup operations and retries unconfirmed cleanup while unwinding. Driver or
network failures can prevent confirmation; cleanup is not guaranteed on those
failure paths, and no success receipt is returned. Unconfirmed cleanup is reported
as `execution.cleanup_failed`, including when source work had already failed.

## Stream to a restricted staging consumer

The example writes one bounded aggregate at a time inside a private temporary
directory. It retains the staging output only after execution and file closure
succeed. These JSON lines are restricted intermediates, not canonical result
pages or an approved export.

```r
captureRestricted <- function(connectionDetails, program) {
  directory <- tempfile("achillesnext-restricted-")
  stopifnot(dir.create(directory, mode = "0700"))
  output <- NULL
  complete <- FALSE
  on.exit({
    if (!is.null(output)) try(close(output), silent = TRUE)
    if (!complete) unlink(directory, recursive = TRUE)
  }, add = TRUE)
  output <- file(file.path(directory, "aggregates.jsonl"), "wt", encoding = "UTF-8")

  receipt <- AchillesNext::executeCharacterizationSql(
    connectionDetails, program,
    visit = function(metricId, row) {
      writeLines(jsonlite::toJSON(row, auto_unbox = TRUE, null = "null",
                                 digits = NA), output, useBytes = TRUE)
    },
    maxStageBytes = 64 * 1024^2,
    maxAggregateRows = 1000000,
    maxAggregateBytes = 256 * 1024^2,
    maxRowBytes = 131072,
    fetchSize = 128,
    statementTimeoutMs = 30000
  )
  close(output)
  complete <- TRUE
  list(receipt = receipt, restrictedDirectory = directory)
}
```

Supply `program` directly from the current installed renderer. The executor
reconstructs its declared inputs using that renderer and compares the complete
canonical program before connecting. Editing SQL and recomputing its digest does
not authorize arbitrary SQL. Re-render artifacts produced by an older compiler;
JSON serialization alone is not an authenticity or compatibility check.

`visit(metricId, row)` receives `metric_id`, `row_kind`, typed `dimensions`, exact
`values`, `state` and `reason_code`. Numeric strings are normalized without
floating-point conversion. Metadata uses actual observed schema/capabilities,
generation timestamps and captured timings. These facts are driver-bound JSONB
parameters; no offline declaration is reported as an observed source identity.

The receipt also contains `audit_totals`, collected before callback delivery from
independently staged physical inputs. `population` contains `person_count`,
`nonnull`, `distinct`, `raw_observation_count` and `merged_interval_count`.
`domains` contains all nine domain names, each with `raw`, `linked`, `observed`,
`start` and `end`, matching the existing producer's conservation inputs. Counts
are canonical integer strings. Domain bounds cover finite valid event dates,
including unlinked rows; both bounds are NULL when none exist. Raw counts include
unlinked and invalid-date records. These totals are not inferred from report
aggregates and are not additional report outputs or approved export content.

The compiler's fixed `source_audit` query and descriptor participate in exact
program reconstruction. The executor reads its single JSON row through the same
pretransmission payload guards and the separate bounded metadata budget. Required
source tables/columns must still be readable; missing required inputs fail rather
than being reported as zero. Optional unsupported field analyses retain their
explicit capability/inventory states while physical input totals remain available.
No conservation check against a persisted candidate is performed by this
source-only API; that requires a later consumer of the completed receipt.
A fixed metadata payload bounds client transfer; computing counts, distinct
identities and date bounds scans the staged inputs in the SQL engine. Tiny-fixture
parity does not establish large-source engine performance.

The callback return value is ignored; use `check` or raise an error or interrupt
to cancel. Signaling a warning or an unrelated condition does not cancel.
Callbacks should stage data until success. A callback can receive some rows before
a later callback, timeout, cancellation or resource check fails. Source rollback
cannot undo files, database writes or messages performed by arbitrary callbacks.
The executor supplies no canonical row keys, denominator references, persistence,
validation receipt, approval or current-publication change. Existing candidate
and refresh APIs keep their own orchestration and do not yet consume this stream.

## Bounds and cancellation

| Control | Enforcement and scope |
|---|---|
| Program | Current closed compiler artifact, reconstructed before connection. Each ordered assertion must match before the next step proceeds; some assertions require temporary stages created by earlier steps. |
| Output rows and UTF-8 bytes | Global aggregate/metadata-output limits, fixed cursor fetch count, per-row and cumulative query guards on PostgreSQL before JDBC receives rejected payloads. A tiny overflow status may be received. |
| Metadata and receipt | Separate finite catalog, metadata-row/byte and statement-record caps. The receipt retains compact inventory and telemetry, not the aggregate stream. |
| Temporary stage bytes | Own-prefix relations and indexes measured after CREATE, INDEX and DROP. This is post-allocation detection, not a disk reservation; PostgreSQL sort/spill files and engine-process memory are outside this measurement. |
| Statement time | PostgreSQL statement timeout plus JDBC query timeout. Queue, lock and execution time are not attributed as engine CPU. |
| Whole-call deadline and `check` | Cooperative checks between JDBC calls and rows. `check` returning FALSE, raising an error or interrupting cancels execution. |

An unsuccessful owned statement is cancelled and closed. Cooperative checks do
not promise immediate interruption of an arbitrary blocked network/driver call;
statement timeout bounds synchronous SQL work. A callback that blocks must impose
its own deadline. Connection establishment is controlled by driver/network
settings, not the callback check. Row and fetch bounds are not a hard R/JVM RSS
reservation; callers can retain rows in their own callback.

Repeatable-read protects the data snapshot. Declared-schema assertions and
observational capability hashes do not freeze concurrent schema DDL or establish
a durable, reusable source release. Coordinate DDL outside the batch; the adapter
does not request broader source grants or stronger source locks. PostgreSQL's
[locking documentation](https://www.postgresql.org/docs/17/sql-lock.html) describes
the separate table-lock/snapshot boundary.

Failures have class `AchillesSqlExecutionFailure` with a fixed `reason_code`,
without raw SQL, credentials or callback exception text. A failed or partially
delivered operation has no success receipt. Consumers must discard or otherwise
isolate their incomplete staging data.

## What the receipt measures

The receipt includes the exact program/profile/source identities, actual observed
schema and capability facts, the complete 142-output inventory, runtime metadata
parameters and exact output row/byte counts. Metadata timings are captured before
metadata delivery; later metadata transport is still included in final telemetry.

Client process CPU includes R/JVM work, including callback work. Whole-call wall
time, program-validation wall time and decode/callback wall time are separate.
JDBC submit/fetch wall time is observed from the client and includes network,
driver and server waits. It is not isolated engine execution time. Engine CPU,
process memory and warehouse query ID remain NULL with an explicit unavailable
reason. A PostgreSQL backend identifier would not be a warehouse query ID.

These bounds are implemented controls, not qualification of a particular laptop,
large dataset or second engine. Complete wire normalization, bounded persistence,
validation/export and institutional approval remain separate stages. The optional
[compiled-candidate bridge](compiled-candidate.md) supplies bounded capture and
separate store persistence for this stream. Saved-result
viewing continues to use precomputed approved data with zero CDM access.
