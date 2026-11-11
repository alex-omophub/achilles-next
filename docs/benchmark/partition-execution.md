# Resume selected source partitions

[partition_execution.py](../../tools/partition_execution.py) runs an explicitly
bounded set of partitions from a verified [schedule](source-partition-plan.md).
It connects chunk generation, source checkpoints and measured inventory collection
with durable parent/partition/materialization identities. It uses local POSIX
storage and local SQLite databases for inventories. It does not connect to the
source/PostgreSQL database or publish analytical results.

## Prepare, run and verify

Create a schedule with the current tools first. Select **1–8 distinct partition
indices**, with at most **100,000 rows and 128 chunks in total**. Choose smaller
partitions when several full-size ranges would exceed those limits. For example,
after selecting an appropriate schedule and partition indices:

```sh
mkdir -p ../partition-work
python3 tools/partition_execution.py prepare \
  --schedule-dir ../source-schedule-work/schedule \
  --partitions 0 1 --output-dir ../partition-work/execution

python3 tools/partition_execution.py run \
  --output-dir ../partition-work/execution --max-units 1

# Continue the same frozen selection, including after a unit-limit stop.
python3 tools/partition_execution.py run \
  --output-dir ../partition-work/execution

python3 tools/partition_execution.py verify \
  --output-dir ../partition-work/execution
```

`--max-units` limits newly completed work units in one invocation. Reaching that
limit before all selected work completes exits 3 and preserves the checkpoint.
Already completed units are replay-verified and reused. A successful repeated run
does not regenerate source chunks or rebuild completed inventories.

Preparation creates a new private directory outside the checkout, separate from
the schedule, registration and optional witness paths, including their ancestors.
Existing outputs, direct output symlinks and duplicate/out-of-range selections
are refused. Use operator-owned storage; this is not a hostile-writer sandbox.
Do not manually edit the request, checkpoints or generated artifacts.

## Recorded identities and completion

`request.json` freezes the schedule path/digest, selected partition indices,
materialization plan digests and executor/inventory code pins. `checkpoint.json`
tracks each unit and its current inventory attempt. `unit-NNN/source` contains
the unchanged bounded materializer's plan, chunks and checkpoint;
`unit-NNN/inventory-NNN` contains the inventory database and its verified receipt.

Before accepting a unit, the controller verifies the exact scheduled source plan,
replays the source chunks and verifies the inventory against those chunks. A unit
result binds the parent schedule digest, partition index, materialization digest,
source completion/binding and inventory digest. This preserves the provenance
that a plain selection array omits. The controller accepts no supplied success
flag in place of those checks.

`complete.json` appears only after every selected unit is verified. Its counts
describe **selected partitions only**; it retains `full_tier_generated=false` and
`qualifying=false`. Inventory distinct counts and histograms remain per unit:
they are not merged into whole-source statistics. `attempt.json`, when present,
describes a historical failed/stopped invocation; it may remain after a later
successful completion.

Verification does not generate missing data. Missing or changed completed
artifacts, contradictory checkpoints, changed schedules/code and unexpected
files are refused. Code-pinned schedules must be recreated after planner changes;
older execution requests are not automatically upgraded or rebound.

## Cancellation and recovery

Run and verification take a nonblocking operation lock. Concurrent controllers
are refused. SIGINT/SIGTERM request cooperative stopping with exits 130/143. An
empty regular `STOP` file in the execution root stops further work with exit 3;
remove it before resuming or verifying. `--seconds` accepts 1–120 seconds per
invocation, including schedule/witness and artifact verification. The outer stop
callback reaches witness scans, the materializer and inventory verification.

Committed source chunks resume through the existing checked materializer
checkpoint. A completed inventory whose controller checkpoint was not saved is
verified and adopted, without rebuilding it. An inventory directory without its
completion receipt is retained and blocks the default run. After inspecting it,
explicitly request a new attempt:

```sh
python3 tools/partition_execution.py run \
  --output-dir ../partition-work/execution --retry-incomplete-inventory
```

This retains the old directory and allocates the next named attempt, with at most
three attempts per unit. Every earlier attempt must remain a nonsymlink directory;
missing or replaced retained attempts block run, retry and verification.
A corrupt inventory that claims completion is refused
even with the retry flag. Lost or corrupt initial source/controller metadata is
also refused; there is no destructive repair or automatic reset. Preserve the
evidence and prepare a new execution directory after inspecting such failures.

## Limits and scope

The selection-wide row/chunk caps apply across all invocations of this request.
Each unit retains the materializer's 64 MiB CSV budget and inventory's 128 MiB
database/one-million-bin limits. Retained failed inventory attempts consume
additional storage: up to 8 units × 3 attempts, plus SQLite journals and verification
scratch. The controller samples a 64 MiB free-space floor. These are bounds and
checks, not disk reservations or OS CPU/memory containment. Blocking filesystem
calls can outlast a cooperative deadline. No external processes are launched.

This is bounded development execution, not a full-tier controller or admission
decision. The registered resource observations remain `planned_not_admitted`.
The [bounded shared loader](partition-shared-load.md) can combine verified units
into one candidate schema and calculate an exact inventory of that selection.
Full-tier loading, whole-source measured inventories,
allocated reference resources, observer/stop access and calibration remain separate
prerequisites for large S1/S2 execution. A verified unit may be registered as a
fresh bounded witness for the existing [fixture loader](bounded-source-loader.md),
which continues to create a separate disposable schema per load.
Keep those new registration and load outputs outside the execution directory;
the controller refuses additional artifacts inside its managed directories.
