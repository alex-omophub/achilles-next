# Accumulate exact inventories across source partitions

[partition_inventory.py](../../tools/partition_inventory.py) merges verified
[partition](source-partition-plan.md) inventories into one disk-backed SQLite row
bag and histogram set. It avoids copying all CSVs into a single bounded selection
before counting global duplicates. It generates no rows, connects to no
PostgreSQL/CDM database and publishes no analytical results.

## Prepare and append

Use a current code-pinned registration and partition schedule. Generate a bounded
scheduled partition and its [source inventory](source-inventories.md) first. The
materialization must match exactly that partition's table, offset, row count,
chunk controls and source/code pins. Unscheduled selections are refused.

```sh
mkdir -p ../scale-work
python3 tools/partition_inventory.py prepare \
  --schedule-dir ../scale-work/schedule \
  --output-dir ../scale-work/reduction

python3 tools/partition_inventory.py append \
  --output-dir ../scale-work/reduction --partition 0 \
  --source-dir ../scale-work/partition-0/source \
  --inventory-dir ../scale-work/partition-0/inventory

python3 tools/partition_inventory.py status \
  --output-dir ../scale-work/reduction
```

The output must be new and outside the checkout, separate from the schedule,
registration, optional registered witness and their ancestors. Appended sources
and inventories must also be separate from it. Direct symlinks and unexpected
artifacts are refused. Use operator-owned storage; arbitrary hostile filesystem
or SQLite writers are not isolated by this protocol.

Partitions may arrive out of order. The accumulator has no eight-partition or
100,000-total-row selection limit: each append retains existing bounded input
limits while the accumulator has explicit total storage/key budgets. Only new
partition inputs are verified; earlier CSVs are not replayed. Keep the schedule,
registration and any witness needed to verify that registration. Previously merged
partition artifacts can otherwise be archived independently.

## Exact counts and durable restart

The input inventory is independently verified against its source. Under the
source operation lock, its plan is checked against the schedule and its SQLite
file is copied to a temporary snapshot. Size/hash must match the verified record.
The reducer streams that immutable snapshot one key at a time. It never loads
the complete global key set or journal into Python memory.

Row keys include the table and complete encoded CSV row. Histogram keys include
the table, dimension and tagged value. Observation counts are added by key. Two
identical rows in different partitions contribute two observations but one
distinct row. Global distinct counts are **not** sums of per-partition distinct
counts. Null counts, encoded row widths, histogram cardinalities and observations
are retained per table. Empty scheduled tables remain explicit.

Each append commits rows, histograms, cached summaries and its
`achillesnext_inventory_partition` receipt in one SQLite transaction. Failure or
cancellation preserves the previous committed state. Retrying a committed
partition checks its stored receipt and returns `already_committed`, without
rereading old input files or adding observations again. This also recovers from
a lost commit response or failure writing local progress metadata. Retried inputs
are not revalidated or presented as newly verified.

The SQLite journal/header are authoritative. `progress.json` is informational;
`status` reads the database, including hot rollback journal recovery after a
killed process. The operation lock excludes cooperating writers to that output.
Do not independently edit its SQLite tables. Append does not rescan/hash the
accumulated database or reread historical partition receipts. Header consistency
checks are not an independent global audit.

## Budgets and stops

Defaults are **128 MiB of accumulator database and one million combined row/
histogram keys**. `prepare --database-bytes` and `--bins` explicitly freeze other
total budgets; allowed ceilings are 512 GiB and 2,147,483,647 keys. Resume cannot
silently raise them. These are refusal ceilings, not disk reservations or
execution admission. A larger ceiling does not allocate reference resources.

Inputs remain capped at 100,000 selected rows, 128 chunks, 64 MiB CSV and a
128 MiB source inventory. Allow disk space for verification/snapshot copies,
the growing accumulator and its rollback journal, including spill headers and
checksums. Recovery allows a journal up to twice the database ceiling plus 64 KiB;
reserve space accordingly. The sampled free-space floor is 64 MiB. SQLite uses
4 KiB pages, a 4 MiB
accumulator cache, disk-backed temporary work and synchronous DELETE journals.
Per-input verification retains its own bounded working set.

`--seconds` is a finite cooperative 1–120-second invocation budget. SIGINT/SIGTERM
and a regular empty output `STOP` file propagate through verification, copy and
SQLite work. Remove `STOP` before resuming. SQLite progress callbacks retain the
original cancellation cause. Blocking filesystem calls can exceed a sampled
deadline; these checks are not OS containment. Failures keep `attempt.json` and
committed data; uncertain outcomes instruct the caller to inspect the partition
journal. CLI exits: 0 success, 1 refusal/failure, 2 syntax, 3 STOP/deadline,
130/143 INT/TERM. A subsequent attempt can overwrite the latest attempt record.

## Coverage boundary

`status=accumulating` and the selected/committed/scheduled counts describe actual
reduction progress. `all_scheduled_partitions_accumulated` is a checkpoint-counter
observation, not certification. `whole_source_audited`, `full_tier_generated` and
`qualifying` remain false. No full-source completion/publication receipt is emitted.
Independent global audit/finalization, execution admission, source-to-database
streaming and representative-scale qualification remain separate work.

Use the [independent inventory auditor](partition-inventory-audit.md) to regenerate
expected observations, audit global keys and finalize a separately scoped receipt.
It supports resumable work and refuses reuse after the source inventory changes.
