# Characterization refresh contracts

`planCharacterizationRefresh()` creates a source-free request for a complete
core-characterization refresh. `inspectResultStore()` separately reads an existing
restricted store's version marker. These are planning/readiness tools: the full
refresh worker is not implemented yet. The separate [candidate generator](core-characterization.md)
produces all 142 outputs, including metadata; the older measurement baseline still
accounts for 138 of 142 outputs.

```r
plan <- planCharacterizationRefresh(
  "cdm", "local-source", "results", "serving", "5.5")
stopifnot(plan$execution$state == "planning_only")

# Institution-supplied PostgreSQL credentials with schema USAGE and SELECT on
# results.achillesnext_storage_version; no CDM access is needed by this probe.
readiness <- inspectResultStore(storeReaderDetails, "results")
```

The plan binds the full batch/profile/definition identities, all 142 requested
metric IDs, the exact numeric strategy and distinct source/results/serving schemas.
Its hash identifies the request and implementation. It does not identify a source
snapshot, inspect a current publication or enable reuse. Repeated identical plans
have the same hash; future executions must still create separate candidates and
recompute their inputs. No candidate, source query, checkpoint or publication is
created by planning. There is no implicit scheduler or chart-time refresh.

The probe requires exactly one `2.0.0` marker. It reads at most two bounded marker
values in a read-only transaction and fails on missing, denied, duplicate, NULL,
oversized or unsupported markers. It never repairs, initializes or migrates a
store. A matching marker is a precondition, not structural/content validation or
evidence that worker writes will succeed. The complete candidate generator checks
the marker before generation; older partial-baseline and publication APIs do not
automatically invoke this diagnostic. Serving-only approved-page readers
do not need SELECT on the version table.

## Required refresh lifecycle

The plan records the following requirements for the future worker; it does not
claim to implement them:

1. Verify store compatibility, required capabilities and source consistency before
   work. Create a new restricted run/release rather than mutate the old publication.
2. Compute the full declared profile in a consistent source transaction. Source,
   vocabulary, schema, scope and implementation evidence belong to this candidate.
   A verified immutable release is different from a timestamp or operator label.
3. Record passport, capabilities, output status and timing honestly, including
   unknown source/vocabulary identities. Missing implementation is an incomplete
   result, not a reason to invent suppression. All 142 outputs must be accounted for.
4. Seal and natively validate the complete candidate, apply the institution's
   disclosure policy and obtain explicit approval before promotion. The old
   publication remains current through generation, validation and approval failure.
5. Promote using the existing compare-and-swap current-pointer semantics. Concurrent
   refreshes must not mix candidate facts, steal approval or overwrite an unexpected
   current revision. Saved reads continue to pin immutable publication identities.

Until sufficient source immutability and dependency evidence are implemented and
proved, recovery means a full rerun. Matching SQL/profile hashes or ETL dates cannot
turn unknown source state into a cache hit. Updates, deletes, backfills and changed
vocabulary/definitions require recomputation. Module reuse and durable checkpoints
are not provided by this plan.

A successful statement or bounded-writer flush is executed but uncommitted work,
not a checkpoint. Cancellation, connection loss or a late failure must roll back
the candidate transaction and leave the previous approved publication intact.
Long repeatable-read transactions can impose source/storage costs; stage budgets
and timeouts do not establish a production-scale guarantee. The older bounded
[recovery API](recovery.md) is not a general whole-core refresh worker.

## Store upgrade and retention design boundary

Storage `2.0.0`, mathematical profiles and wire formats are separate versions.
The version marker installed by `initializeResultStore()` is unchanged. No upgrade
or deletion API is implemented by these functions. Before institutional upgrade support
is claimed, the procedure must specify:

- A source/target version matrix and reviewed, checksum-bound migration scripts;
  refuse unknown, newer and partially applied versions. A matching marker alone
  cannot prove physical schema compatibility.
- An institution-controlled installer/migration role, serialized maintenance and
  backup/restore checks. Generation and serving roles must not acquire installer
  privileges or automatic repair behavior.
- A failure boundary for each migration: transactional rollback where supported,
  and a recorded restoration/resume procedure for nontransactional steps. Mark
  the target version only after successful structural/data validation.
- Preservation of old approved artifacts, protocol-compatible serving views,
  audience grants and current-pointer integrity. Do not rewrite immutable bytes
  merely to update database storage.
- Explicit retention ownership and publication/reader pins. Becoming non-current
  is not permission to delete pages that a pinned or offline reader still needs.
  Interrupted candidates and approved publications need different retention rules.

Upgrade/failure rehearsal and actual retention deletion remain separate work.
No existing result data is removed or migrated by either new function.

## Contributor checks

After package installation and [fixture setup](count-tracer.md#developer-setup):

```sh
set -e
Rscript --vanilla tests/tracer/refresh-contract-offline.R
python3 tools/test_result_serving.py --test-script refresh-contract \
  --state .local/postgresql --config tools/tracer_fixture_config.R \
  --output-dir "$(mktemp -d)/refresh-contract"
```

Offline checks cover deterministic identity, full-recompute/no-publication flags,
schema/source-ID limits and bounded marker handling. The marked PostgreSQL harness
uses a disposable reader with only version-table access and no CDM privileges. It
rejects denied/absent/empty/future/duplicate/NULL/oversized markers, creates no result
candidate or current pointer, and cleans up its owned schemas/role. The same small
checks run in the cached compatibility suite, with no new dependencies.
