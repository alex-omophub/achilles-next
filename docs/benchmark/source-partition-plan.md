# Freeze a complete logical source schedule

[source_partition_plan.py](../../tools/source_partition_plan.py) turns a verified
[source-run registration](source-run-registration.md) into an immutable partition
schedule for every physical table in the declared S1/S2 source. It calculates
ranges and emits one bounded materializer selection on request. It does not
generate CSV files, allocate resources, connect to PostgreSQL or run a workload.

This is scheduling metadata for source orchestration. Registration and schedule
remain `planned_not_admitted`, `execution_enabled=false`,
`full_tier_generated=false` and `qualifying=false`. A complete **logical schedule**
does not establish generated rows, measured source-wide inventories, relational
completeness, calibrated capacity or scale qualification.

## Create and verify

First register the desired tier and CDM version using the registration guide.
A bounded witness is optional for scheduling; when present, it must still verify.
From the checkout root:

```sh
mkdir -p ../source-schedule-work
python3 tools/source_partition_plan.py create \
  --registration-dir ../source-run-work/registration \
  --output-dir ../source-schedule-work/schedule \
  --rows-per-partition 100000 --chunk-rows 10000

python3 tools/source_partition_plan.py verify \
  --output-dir ../source-schedule-work/schedule
```

The new output directory must be outside the checkout and separate from the
registration and its optional source/inventory witness, including their ancestors.
Direct symlinks and existing outputs are refused. Keep these artifacts in
operator-owned local storage; this is not isolation from hostile filesystem writers.
An interrupted write may leave an incomplete directory; there is no automatic
overwrite or repair. Use a fresh directory after inspecting the failed attempt.

`partition-plan.json` contains the complete indexed source definition and its
recipe/DDL/profile/code pins, the registration path and digest, materializer and
planner pins, controls, table layouts, total rows and partition count. A canonical
digest binds the record. Verification regenerates the layouts and record from the
current code and verified registration; changing a count, range, control, flag or
digest is not sufficient to rebind the schedule. Existing registration/witness
files stay unchanged. Verification checks the recorded registration snapshot;
it does not resample resources or establish current execution permission.

## Coverage and bounded work units

Tables are sorted by name. A nonempty table is partitioned into consecutive,
nonoverlapping zero-based ranges covering `[0, table_rows)`. Each empty physical
table receives one zero-row partition, retaining its explicit schema presence.
Every table has a first partition index and partition count. The layout requires
one metadata entry per table; it never builds a list with one entry per row or
partition. Random access visits at most the physical table list.

The default S2 schedule represents 117,050,021 logical rows: 100,000,000 clinical
events plus 17,050,021 person, vocabulary and other auxiliary rows. S1 represents
6,705,021 rows. These are recipe-derived target counts, not measured data.
CDM 5.3/5.4/5.5 retain their own 37/39/42 physical tables, including empty ones.

Choose a zero-based partition index from the table layouts. To emit just its
selection array:

```sh
python3 tools/source_partition_plan.py selection \
  --output-dir ../source-schedule-work/schedule --partition 0
```

Standard output is a JSON array containing one `table/start/rows` window, in the
existing [bounded materializer](streaming-scale-cdm.md) selection format. It contains
no status prefix. The command verifies the schedule and asks the unchanged
materializer to build the exact bounded plan before returning the selection.
Use the schedule's tier/version, `chunk_rows`, CSV byte budget, invocation budget
and free-space floor when preparing the work unit. A selection array alone does
not carry the parent schedule identity. The [bounded partition executor](partition-execution.md)
records the parent digest, partition index and materialization identity together,
with checkpoints for selected source generation and inventory collection.

Controls retain the existing limits: 1–100,000 rows per partition, 1–10,000 rows per
chunk, at most 128 chunks, 64 MiB CSV, 120-second materializer invocation and 64 MiB
sampled free-space floor. Invalid row/chunk combinations are refused before
writing a schedule. Row/chunk limits cannot predict encoded bytes or runtime:
a work unit may hit the existing byte/time guards and need a smaller newly
registered partition size. This planner does not reserve storage or bypass a guard.

The emitted selection can be used for an explicitly bounded development probe
through materialization, [inventory collection](source-inventories.md), a fresh
registration with that witness, and the [fixture loader](bounded-source-loader.md).
That loader creates a separate disposable schema per selection. It does not
assemble partitions into one whole-source database. Do not loop over a full tier
as a substitute for resource admission, full-tier loading or source-wide inventory
verification. Full-tier execution/controller capabilities remain unavailable.
