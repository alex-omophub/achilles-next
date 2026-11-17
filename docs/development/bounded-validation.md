# Bounded validation scratch

AchillesNext separates SQL computation from handling saved aggregates. CDM scans,
joins, sorting and aggregation run in the configured PostgreSQL engine. The R
client can run on a laptop and use a remote engine without a local PostgreSQL
service or Docker. Complete artifact validation reads saved output and does not
query the CDM.

Validation scratch limits bound one part of that client work. They do not establish
a laptop hardware minimum, total client memory usage or large-source performance.
See the [client-path inventory](client-paths.md) for the other execution and
saved-result boundaries.

## Public controls

`validateResultArtifact()` accepts an explicit scratch limit and a cooperative
cancellation predicate:

```r
validateResultArtifact(
  bundleDir = "approved-results",
  maxScratchBytes = 256 * 1024^2,
  cancel = function() FALSE
)
```

The default `maxScratchBytes` is `1024^3` (1 GiB). A caller may supply a finite,
nonnegative whole number of bytes, up to `2^53 - 1`. Zero is valid but cannot fit
the validator's initial indexes. This configured default is not a statement that
every artifact fits within 1 GiB.

`publishResultRelease()` accepts the same named controls. Its `maxScratchBytes`
applies separately to each of its two sequential artifact admission passes: the
first before institutional approval, and the second while inserting the exact
approved pages into the database publication. Each pass has one shared budget;
the limit is not multiplied by the number of spools within a pass. Existing
arguments and defaults remain available. See the [result-store guide](result-store.md)
for sealing, release validation, institutional approval and current-pointer
promotion.

The `cancel` function must return exactly `TRUE` or `FALSE`. A host can supply a
predicate that reads its cancellation request. Checks occur between validation
operations, rows and rehash-copy batches. Cancellation is cooperative; a predicate
does not impose a deadline on a blocking filesystem operation. An R interrupt such
as Ctrl+C is also handled during ordinary unwinding.

## What is counted

One admission budget covers the logical lengths of all validation-owned files:

- Both row and concept hash indexes and their serialized values.
- Reconciliation group-sum files, including their newline bytes.
- Any replacement index while the old index remains live during rehashing.

Page-reachability marks have zero payload bytes. A separate fixed cap of
1,000,000 scratch files counts those marks, group files, value files and indexes,
including a replacement index. This cap prevents zero-byte marks from growing
without a file-count bound; it is not configurable through these public APIs.

The validator checks and charges growth before creating or extending a file.
Rehashing must fit the full old-plus-replacement index peak, not just the final
retained index size. Thus an artifact can fail its scratch budget even when the
final retained scratch files would fit. Index copying stays on disk and does not
load the complete row or concept map into memory. None of these controls removes
reference, denominator, partition, terminology or artifact-closure validation.
Approved page bytes and analytical availability/suppression states are unchanged.

## Errors, cancellation and publication

Invalid control values fail argument validation before work starts. Budget and
scratch I/O failures use the condition class `achillesnext_scratch_error`. Callers
can handle its `code` without parsing operating-system messages or local paths:

| Code | Meaning |
|---|---|
| `byte_limit` | The next growth or replacement index would exceed the shared logical byte limit. |
| `file_limit` | The next scratch file would exceed the fixed file-count limit. |
| `io_failure` | Scratch allocation, reading, writing, flushing, closing or removal failed. |

Filesystem warnings that indicate uncertain writes are failures. An uncertain
spool I/O failure or interruption makes that spool unusable. Cancellation at a
check while a replacement index is being copied removes the replacement and
preserves the prior map; the short final index handoff defers asynchronous
interrupts until the replacement is installed. These are internal safety
properties, not a public resumable-validation API. Start a fresh validation after
a failed admission.

`validateResultArtifact()` propagates predicate cancellation as
`achillesnext_read_error` with code `aborted`. R interrupts retain their interrupt
condition. `publishResultRelease()` preserves the specific scratch-error class;
pre-COMMIT predicate cancellation attempts rollback and cleanup. Uncertainty is
reported explicitly through the publication outcome diagnostics below.

An admission failure occurs before COMMIT is invoked. Confirmed rollback and
cleanup preserve prior current and remove only this attempt's files. Publication
file cleanup now checks removal; uncertainty produces `publication.cleanup_failed`.
Once COMMIT has been invoked, a missing acknowledgement does not prove rollback:
`publication.commit_unknown` retains the approved export. A confirmed commit
followed by a disconnect/return failure also retains it. Use the safe IDs and
outcome described in the [result-store guide](result-store.md) for manual
inspection; these cases never claim that prior current is unchanged.

Validation-owned scratch cleanup attempts all its actions even if one close or
removal fails and reports a cleanup failure. Filesystem deletion can fail when
storage is unavailable. An institutional approval callback may already have run
before a later failure; arbitrary side effects in that callback are not rolled
back. Cleanup applies to ordinary R error/interrupt unwinding, not process
termination or a machine crash.

## Limits of this budget

Logical file lengths do not reserve physical disk blocks, directory metadata or
inodes. Sparse index files may occupy fewer physical blocks than their logical
lengths. Shared free space, quotas and filesystem failures can still stop a run
within the configured limit.

The budget excludes the input artifact, immutable export-page staging, the private
terminology snapshot copy, result-store storage, database temporary relations and
R/JVM/driver/decoded-page memory. The fixed page, row, reader/cache and engine-stage
controls have their own scopes. Complete admission still visits the saved
inventory, so time and scratch requirements grow with output cardinality. Growing
inventory measurements and a declared client/engine workload are needed before
making performance or hardware claims; a finite scratch cap alone supplies no
such qualification.
