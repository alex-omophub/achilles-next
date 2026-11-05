# Characterization refresh contracts

`planCharacterizationRefresh()` creates a source-free request for a complete
core-characterization refresh. `inspectResultStore()` separately reads an existing
restricted store's version marker. These are planning/readiness tools. `executeCharacterizationRefresh()` consumes
an unmodified current plan and computes a fresh complete restricted candidate.
The separate [candidate generator](core-characterization.md)
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

The executor implements full candidate recomputation. The remaining publication
operations are explicit and use separate operator credentials:

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
not a checkpoint. Precommit cancellation or a late failure rolls back the candidate
transaction. A lost commit acknowledgement may leave candidate status uncertain;
the previous approved publication remains intact because generation never promotes.
Long repeatable-read transactions can impose source/storage costs; stage budgets
and timeouts do not establish a production-scale guarantee. The older bounded
[recovery API](recovery.md) is not a general whole-core refresh worker.

## Execute and review a full refresh

```r
plan <- planCharacterizationRefresh("cdm", "local-source", "results", "serving", "5.5")
candidate <- executeCharacterizationRefresh(workerDetails, plan)
stopifnot(candidate$profile_complete, !candidate$publishable)

# Explicit store-operator steps; generation alone does not publish.
sealResultRelease(operatorDetails, "results", candidate$release_id)
validateResultRelease(operatorDetails, "results", candidate$release_id)

# Use an institution-defined policy and approval callback for this exact release.
# NULL prepares approved bytes without changing the current pointer.
approved <- publishResultRelease(operatorDetails, "results", candidate$release_id,
  newExportDirectory, audienceId, approvalId, policy, institutionalPolicy,
  expectedRevision = NULL)
# Obtain the expected revision for this source/profile/audience from trusted state.
promoteResultPublication(operatorDetails, "results", approved$publication_id,
  expectedRevision = expectedRevision)
```

The request is recreated against the installed implementation before opening a
connection. Unknown fields, changed safety flags/metrics and stale definitions are
rejected even if the caller recomputes a matching digest. A plan is a trusted local
R request, not an authorization token. After changing the installed package or its
SQL/registered definitions, create a fresh plan.

The worker verifies the storage marker and required table privileges before any
staging/result write, then applies the existing required-source/profile preflight.
It needs `USAGE` on both the source and results schemas, SELECT on the
version/profile registry and SELECT/INSERT on the seven
producer tables (`source_release`, `analysis_run`, `operation`, `result_release`,
`dataset`, `aggregate_cell`, `denominator_edge`), all with the `achillesnext_` prefix,
plus UPDATE on `analysis_run` and `result_release`. Source privileges remain
SELECT-only; database TEMPORARY is required. Generation needs no publication,
current-pointer or serving-view privileges. Version/privilege checks do not certify
all physical structures, trigger definitions, RLS behavior or migrations; an actual
write/validation failure still fails closed. The serving schema is retained in the
plan for subsequent publication but its view wiring and audience grants are not
validated by this worker.

Readiness errors use class `AchillesRefreshReadinessFailure` and a safe
`reason_code`: `refresh.store_version_unavailable_or_unsupported`,
`refresh.store_privilege_missing` or `refresh.store_privilege_check_failed`.
Messages identify the version/access check or required privilege and table. Raw
JDBC/SQL diagnostics are excluded. These errors retain their refresh context
through the generation wrapper; they do not become domain-baseline errors.

Each successful execution commits distinct run, source-release and result-release
identities, the complete requested plan, configured limits and actual telemetry.
The run request hash binds that work; it never proves immutable source contents.
Unchanged inputs yield identical numeric aggregates with new run/timing metadata.
Changed rows, unknown ETL/vocabulary identities or changed definitions always cause
a full recomputation, with no cache or checkpoint reuse.

Generation errors/cancellation before commit roll back all candidate rows and
run records. No durable failed-attempt log is claimed; retain the scheduler/process
error separately if needed. A lost commit acknowledgement can leave an uncertain
candidate outcome; a retry creates another candidate and never promotes either
implicitly. Sealing/validation/approval are separate transactions. A later failure
can leave a building or sealed/validated unpublished candidate for diagnosis; it
must not delete or rewrite the previous approved pages or current pointer. Explicit
CAS promotion is the only step in this recipe that replaces current.

Cancellation is cooperative between bounded operations; SQL statement timeouts
bound individual statements, not the entire job or peak spill allocation. The
optional `check` callback is trusted application code: it should return or signal
cancellation, without making database writes of its own. External schedulers can
call the same entry point; this package does not install a scheduler or run work
from chart interactions. The [operations proof and procedures](store-operations.md) cover controlled
overlap, precommit session loss, CAS contention and pinned reads. Version-pair
migration/retention rehearsals and production-scale qualification remain separate work.

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

The full-refresh proof uses tiny disposable source/store schemas and a serving-only
reader with no CDM privileges:

```sh
Rscript --vanilla tests/tracer/refresh-execution-offline.R
python3 tools/test_characterization_refresh.py --state .local/postgresql \
  --config tools/tracer_fixture_config.R --output-dir "$(mktemp -d)/refresh"
```

It compares all 138 numeric outputs on unchanged inputs, checks fresh identities
and persisted plan binding, changes rows without changing schema, rejects stale
implementation plans, executes a fresh definition plan, and exercises readiness,
late precommit error/cancellation, validation and approval failures. After each,
the previous publication's pointer and every saved page byte remain unchanged;
the serving-only reader still retrieves the original count. Concurrent refresh,
promotion races and production-scale qualification are not implied by this proof.

For concurrent generation, promotion conflicts, versioned upgrade/interruption
procedures and retention of pinned readers, see [store operations](store-operations.md).
The controlled concurrency proof is separate from the serial failure proof above.
