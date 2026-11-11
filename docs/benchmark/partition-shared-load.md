# Load selected partitions into one fixture schema

[partition_shared_load.py](../../tools/partition_shared_load.py) consumes a completed
[bounded execution](partition-execution.md), copies its verified chunks into one
combined selection, builds a fresh local SQLite inventory, and loads a new marked
PostgreSQL fixture schema. It does not regenerate saved CSV chunks or replace an
existing schema. All artifacts are synthetic development data.

## Load

Prepare current code-pinned registration, schedule and execution artifacts first.
The executor and registration changes in this increment require recreating older
artifacts; the tools refuse silent rebinding across code versions. The existing
marked fixture database/roles and native psql must already be provisioned.

```sh
mkdir -p ../partition-shared-work
python3 tools/partition_shared_load.py load \
  --execution-dir ../partition-work/execution \
  --output-dir ../partition-shared-work/load-one \
  --state-dir .local/postgresql
```

The output must be new, outside the checkout and separate from execution,
schedule, registration and optional witness paths, including their ancestors.
Direct symlinks, existing outputs and invalid/incomplete execution artifacts are
refused. Keep these artifacts in operator-owned local storage; arbitrary hostile
filesystem/database writers are not isolated.

The execution and output operation locks stay held throughout the load. The
controller first replays every execution unit and its inventory, then verifies
each source again under its own lock while copying. New chunk filenames follow
the combined materializer plan. Accepted internal hard links retain their topology;
identical bytes from separate files still represent separate logical chunks.
The combined selection is replayed against the indexed generator before inventory
collection or database access. Original execution artifacts remain unchanged.

## Combined inventory and transaction

The new `source/` and `inventory/` artifacts describe the union of all selected
windows. Inventory collection counts the combined row bag and histogram keys;
it does not sum per-partition distinct counts. If two partitions contain the same
complete row, each local inventory may have one distinct row and no duplicate,
while the combined inventory correctly has one distinct row and one duplicate.
No source-wide statistics are inferred for rows outside the selection.

A fresh `registration/` binds this combined witness. The existing
[bounded loader](bounded-source-loader.md) then performs one transaction that
creates all physical tables and copies all chunks into the same schema. Every
table's row count and every column's null count must match before commit;
unselected tables must be empty. Duplicates are preserved without primary-key
enforcement. Existing fixture runner access remains SELECT-only. The locked
PostgreSQL 17.11/psql 17.10 tuple and marked local owner connection are required.

`binding.json` records execution/request/schedule/partition identities, the
combined plan and code pins before copying. `complete.json` is written after the
underlying load succeeds and includes hashes of the inventory, registration and
load receipt plus the generated schema. Coverage remains `selected_partitions_only`,
with `whole_source_loaded=false`, `full_tier_generated=false`, `qualifying=false`.
It is not a relationally complete CDM, full-tier source or analytical publication.

## Bounds, stops and failures

Existing limits remain: at most 8 selected partitions, 100,000 rows, 128 chunks
and **64 MiB total combined CSV**, plus a 128 MiB/one-million-bin inventory budget.
The copy is retained on disk; the underlying loader also creates a temporary
verified copy. Allow space for both, SQLite verification scratch, journals and
database/WAL growth. Preflight checks combined-copy bytes plus a 64 MiB free-space
floor; sampled floors and deadlines are not reservations or OS containment.

`--seconds` is a cooperative 1–120-second invocation budget, covering execution
replay, copy, inventory, witness registration and loading. SIGINT/SIGTERM and the
execution's existing `STOP` control propagate through those stages and into the
owned psql loader. Blocking filesystem calls can exceed a sampled deadline. The
loader's finite child-stop escalation and connection/statement/lock timeouts still
apply. CLI exits are 0 on success, 1 on refusal/failure, 2 on syntax, 3 on deadline/
STOP, and 130/143 on INT/TERM.

Failures retain copied artifacts and `attempt.json` with the stage and available
commit outcome. SQL errors before commit roll back the new schema. A successful
database commit followed by a receipt failure leaves a recoverable schema; the
underlying `load/request.json` retains its exact owned identity. Missing success
metadata does not imply rollback. No automatic retry, reset or deletion occurs;
inspect the saved child request/attempt, clean up as appropriate, then choose a
fresh output directory.

## Cleanup

```sh
python3 tools/partition_shared_load.py drop \
  --output-dir ../partition-shared-work/load-one \
  --state-dir .local/postgresql
```

Use this wrapper so cleanup takes the parent operation lock before the child
loader lock. It checks the saved shared binding against the child's source plan,
then delegates live owner/marker/target checks to the existing loader. It does not
need the original execution artifacts or current generator pins, and does not
delete local evidence. An existing completion receipt is a historical record of
the load; cleanup does not rewrite it to claim the schema still exists. If no
child request was saved, cleanup refuses rather than inferring database state.

This adds one-schema **bounded** loading and an exact inventory of that selection.
For a separate candidate with committed chunk checkpoints and resumable loading,
pass this output's `registration/` to the [incremental loader](incremental-source-load.md).
Full-tier incremental loading, whole-source measured inventories, resource
allocation, observer/stop authority and capacity calibration remain separate
requirements before large S1/S2 execution or scale qualification.
