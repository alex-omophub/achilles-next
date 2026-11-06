# Store operations: refresh, upgrades and retention

Procedure revision **1.0.0**. Storage **2.0.0**. These are separate from the
mathematical profile, result wire format, package and host versions.

The package installs new empty stores and generates/validates/publishes candidates.
It has no migration runner or retention/deletion API. The procedures below define
operator responsibilities and the evidence required before an upgrade or cleanup
path can be offered. Recording a procedure does not certify a migration.

## Current compatibility boundary

| Starting state | Operation | Current behavior |
|---|---|---|
| No results/serving schemas | Initialize storage 2.0.0 | `initializeResultStore()` creates new schemas atomically |
| Existing matching 2.0.0 store | Run checked refresh | Version and worker privileges are checked; actual writes/native validation still must pass |
| Existing schemas | Run installer again | Refused; installation does not overwrite or repair them |
| Missing, denied, ambiguous or other version | Refresh/readiness | Refused; no automatic marker change or migration |
| Package update retaining storage 2.0.0 | Install code and create fresh plans | No database migration implied; verify included profile/wire compatibility against saved artifacts |
| Any storage-version change | Upgrade existing data | Unsupported until a reviewed version-pair migration bundle and restore/failure rehearsal exist |

`inspectResultStore()` reads the marker only. A matching marker is not a complete
structural/content, RLS, ownership or write-privilege check. Never edit the marker
to make an incompatible or partially migrated store appear ready.

## Normal refresh and concurrent operators

Use the [checked refresh lifecycle](refresh.md) with a worker that has source
SELECT, schema USAGE, database TEMPORARY and the documented producer grants.
Keep installer/migration, generation, publication/approval and serving roles
separate. Generation does not need grants on current-pointer or publication tables.
A serving principal needs only approved views and its enabled audience grant.

One generation pins a PostgreSQL repeatable-read snapshot. The controlled fixture
proof demonstrates ordinary local tables across a committed PERSON insert,
condition delete/backfill and vocabulary change: the earlier refresh sees the
old correlated data and the later one sees the new correlated data. A snapshot
does not turn an ETL spread across multiple commits into a completed business
release. Coordinate generation after the source owner's ETL completion signal;
record unknown source/vocabulary identities honestly. Foreign tables, volatile
views and cross-database inputs need separate consistency qualification. PostgreSQL
defines the snapshot boundary at the first non-control statement. See its
[isolation documentation](https://www.postgresql.org/docs/17/transaction-iso.html#XACT-REPEATABLE-READ).

Concurrent refreshes create different source-release/run/result identities and
use their own temporary stages. A successful candidate does not become current
until sealing, native validation, exact institutional approval and explicit
promotion. A serialization/deadlock/cancellation failure requires a fresh full
rerun; no module/checkpoint reuse is offered under unknown input identity.

Obtain the expected revision from trusted current state for the same source,
profile and audience. Competing different publications at that revision have one
CAS winner; the other reports `Current publication conflict`. Review the new
current descriptor before deciding whether to promote another publication.
Do not automatically retry with an incremented revision. Retrying promotion of
the already-current publication is idempotent and returns its current revision.
CAS does not decide which source snapshot is clinically preferable or newest;
that decision belongs to the institutional approval/promotion policy.

Readers pin source, publication, audience and root hash. They keep that context
while paging; they must not repeatedly resolve current and combine objects from
different publications. Replacing current leaves approved old pages readable
while the audience grant remains enabled. A non-current approved publication can
still be serving an active or offline reader.

Monitor long transactions, stage storage and lock waits. Per-statement timeouts,
cooperative cancellation and post-stage byte checks do not establish a total job,
hard memory/spill or production-scale limit.

## Failure and restart

| Failure boundary | Persisted outcome | Operator action |
|---|---|---|
| Plan/readiness rejection | No candidate from this attempt | Correct access/version or create a fresh plan; do not bypass the check |
| Generation failure/cancellation before commit | Candidate transaction rolls back | Check session exit; rerun fully after correcting the cause |
| Server session lost before commit | Uncommitted work rolls back | Verify session termination and inspect only this attempt's identities; rerun fully |
| Commit acknowledgement lost | Candidate completion may be uncertain | Inspect committed run/result identities; retain uncertain candidates and rerun rather than infer a checkpoint |
| Seal/native validation/approval fails after generation | An unpublished building/sealed/validated candidate can remain | Keep prior current; diagnose the candidate before any explicit publication attempt |
| Promotion conflicts | Another approved publication may now be current | Re-read trusted current state and review intent; do not force overwrite |
| Promotion acknowledgement lost | Promotion may already have committed | Resolve trusted current context; an identical-target retry is idempotent |

The session-loss proof terminates a fixture-owned backend at the final precommit
callback and checks rollback plus the previous pointer/page bytes. It does not
simulate every network partition, server crash or ambiguous commit outcome.
PostgreSQL documents the confirmation behavior of
[`pg_terminate_backend`](https://www.postgresql.org/docs/17/functions-admin.html#FUNCTIONS-ADMIN-SIGNAL).

## Controlled upgrade procedure

Before authorizing any future supported version pair:

1. **Assign ownership and stop writers.** The institution appoints a migration
   operator using an installer role. Pause external generation/validation/publisher
   jobs and drain their sessions. The package has no maintenance-lock service;
   a scheduler/operator gate must enforce this. Keep pinned readers on the old
   endpoint/artifact where compatible; otherwise arrange a documented read window.
2. **Inventory exact versions and identities.** Record source/target storage
   versions, schema names, ownership/grants, package/R/dependency/JDBC versions,
   installed profile/row-schema hashes and supported wire/host contracts. Record
   each current source/profile/audience descriptor, its revision and approved
   publication/release/receipt/root identities. Inventory every retained approved
   page tree and offline export with byte hashes and institutional reader pins.
3. **Take and prove a recoverable backup.** Preserve results and serving objects,
   approved payload bytes, receipts, definitions, grants/current pointers and
   exported trees. Include external dependencies and required role/database
   configuration separately. A schema-selected dump must be reviewed for omitted
   dependencies and is not automatically self-contained. Restore to an isolated
   target and verify roles, audience filtering, current descriptors, exact approved
   bytes and native artifact reads using the supported pinned package/runtime.
   A backup file existing is not a successful restore rehearsal. See PostgreSQL's
   [dump/restore documentation](https://www.postgresql.org/docs/17/app-pgdump.html).
4. **Review the migration bundle.** It must identify the exact supported version
   pair, script checksums/order, required privileges, pre/post structural/content
   invariants and rollback/restore method. Identify nontransactional steps in
   advance. Refuse unknown/newer or partially applied states. No such script bundle
   is provided by this package version.
5. **Rehearse success and interruption.** Start from the saved prior store fixture,
   keep a reader pinned to the prior root, inject failures before/after each
   transaction boundary and every nontransactional step, then perform the documented
   recovery. Validate current-pointer context, all retained bytes/receipts,
   explicit projections and serving-role access. Test both old pinned reads and a
   freshly generated candidate. Only a completed version-pair rehearsal permits
   that migration to be described as supported.
6. **Execute in the controlled window.** Apply only the approved checksummed
   scripts. Mark the target version after successful target validation, following
   the reviewed transaction design. Recheck the actual structures/content; the
   version marker alone cannot establish completion. Never reserialize approved
   pages, rewrite their hashes/IDs or replace pinned exports to update storage.
7. **Verify and reopen deliberately.** Re-run stored-artifact and serving-principal
   checks, including denied cross-audience reads. Verify the preserved current
   contexts/revisions and prior pins before creating any new publication. Create
   fresh plans for the new installed definitions, then resume writers under the
   normal approval/CAS procedure. Keep the recoverable old store/export and backup
   until the institution's retention/pin conditions permit retirement.

An implementation upgrade must preserve or explicitly retain a reader/runtime
that understands each pinned mathematical profile and wire version. A database
migration does not authorize silently converting old analytical definitions or
approved object bytes.

### Interrupted upgrade decision table

| Observed state | Required response |
|---|---|
| Failure before migration writes | Leave the old store available after verifying the original inventory |
| Transaction abort confirmed, all steps transactional | Verify rollback against the old inventory, then review retry; do not assume a log line proves rollback |
| Lost commit acknowledgement | Freeze writers and compare actual version, structures, content and script ledger to the reviewed bundle; do not blindly rerun |
| Nontransactional/partial/unknown state | Keep writers stopped; follow the reviewed recovery path or restore to an isolated replacement and validate before routing |
| Target marker present but checks fail | Treat as incomplete; do not permit generation/publication based on the marker alone |

Recovery must preserve the old approved artifacts/current context. A repair may
never consist of changing the marker or deleting referenced pages. Unsupported
states remain blocked until a validated recovery or restoration is available.

## Retention and pinned readers

The current package has no deletion endpoint, external-reader lease registry or
automatic garbage collector. Table triggers/foreign keys also protect content;
a logical expiry date is not permission to bypass them with SQL.

The institution maintains a protected pin/retention inventory outside the package:
publication/source/profile/audience, root hash and wire/profile versions, reader or
offline-export holder, responsible owner, creation/review/expiry and release-of-pin
acknowledgement. If active-reader or offline-export status is unknown, retain the
publication. A current-pointer change or last-access timestamp alone cannot prove
that a publication is unused. A released pin permits review; it does not itself
perform or authorize deletion.

For any future retention implementation, the review set must exclude:

- Every current publication and every publication pinned by an active reader,
  approved offline export, rollback procedure or institutional hold.
- All reachable objects/indexes, validation receipts, releases/runs, source and
  profile definitions needed by those publications. Shared/referenced data must
  remain until every reference is released; child objects are not independently
  disposable because their metric is absent from a current view.
- Backups/archives and pinned package/viewer runtimes still needed for recovery
  and supported readback. An export is a complete immutable pointer plus reachable
  object tree, not a selection of visible chart files.

Before a supported cleanup path is introduced, rehearse two approved publications,
a pinned old reader, a newly current reader, an offline export and a simulated
cleanup interruption. Demonstrate refusal while any required pin/hold exists,
consistent reachability/current-pointer validation, recovery after interruption
and intact reads for all retained contexts. Record the reviewed deletion manifest
and backup/restore evidence. This version provides the retention rules, not the
executor for that destructive operation.

Disabling an audience grant stops new database page reads. It cannot erase copies
already distributed as approved offline exports; those need institution-controlled
retention with their holders. No remote export deletion is implemented.

## Contributor operations proof

After [fixture setup](count-tracer.md#developer-setup) and installation, from the
repository root:

```sh
python3 tools/test_refresh_operations.py --state .local/postgresql \
  --config tools/tracer_fixture_config.R --output-dir "$(mktemp -d)/operations"
```

The marked synthetic harness uses separate R/JVM processes and bounded file barriers.
Its process control requires Unix `ps`/signals and targets macOS/Linux; Windows
process control is outside this proof.
It observes two active repeatable-read snapshots around one committed ETL-like
mutation, confirms backend termination before commit, observes both promotion
sessions waiting on the actual CAS advisory key, checks one winner/stale conflict
and verifies pinned old/losing page bytes through the CDM-denied serving principal.
It stops only its own identified child processes/sessions and restores fixture
permissions. This proof does not run a migration, delete retained data, or certify
production-scale, foreign-table or second-engine behavior.
