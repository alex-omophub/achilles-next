# Guarded source materialization and restart

[scale_materialization.py](../../tools/scale_materialization.py) streams a frozen,
bounded selection from the [indexed source](indexed-scale-cdm.md) into immutable
CSV chunks. It checkpoints verified progress and can resume after interruption.
It does not load a database, publish analytical results or execute a full tier.
This development tool requires a local POSIX filesystem with working file locks,
hard links, atomic replacement and file/directory sync support. It has no Python
package dependencies beyond the standard library and existing generator modules.

## Prepare, run and verify

Choose a new output directory outside the checkout. Preparation freezes the
source/recipe/DDL/profile/code hashes, selected row windows and resource controls.
For example, from the checkout root:

```sh
mkdir -p ../streaming-source-work
cat > ../streaming-source-work/selection.json <<'JSON'
[
  {"table":"measurement","start":41999990,"rows":10},
  {"table":"concept","start":14850007,"rows":10}
]
JSON
python3 tools/scale_materialization.py prepare --tier S2 --cdm-version 5.5 \
  --selection ../streaming-source-work/selection.json --chunk-rows 4 \
  --output-dir ../streaming-source-work/job
python3 tools/scale_materialization.py run \
  --output-dir ../streaming-source-work/job
python3 tools/scale_materialization.py verify \
  --output-dir ../streaming-source-work/job
```

Versions 5.3, 5.4 and 5.5 use their locked physical columns. Windows are sorted
by table/start; overlapping or duplicate windows are refused. Offsets are
zero-based and end-exclusive. An empty table can have a zero-row window whose
chunk contains only its CSV header. Each nonempty chunk holds at most the
registered `--chunk-rows`, so duplicate rows spanning chunk boundaries are kept.
Every chunk has a header; readers must skip it separately for every file.

Preparation must finish successfully before `run`. An interrupted preparation
can leave an uninitialized directory; preserve it for inspection and prepare a
new location. Existing directories are never reset by `prepare`.

## Fixed controls and invocation limits

| Control | Allowed range/default |
|---|---|
| Selected rows | At most 100,000 across the whole job |
| Selected windows | 1–64 |
| Chunk rows | 1–10,000; default 1,000 |
| Total chunks | At most 128, including empty-table headers |
| CSV byte limit | 1 byte–64 MiB; default 64 MiB, cumulative across restart |
| Free-space floor | 16 MiB–1 GiB; default 64 MiB |
| Invocation duration | 1–120 seconds; default 120, including validation |

`prepare` accepts `--byte-limit`, `--min-free-bytes` and `--seconds`. Controls
are part of the frozen plan; editing them invalidates its binding. CSV bytes
include committed and pending chunk data, with a temporary hard link counted
once. Metadata is separately bounded to 1 MiB per file, with a fixed inventory.
Limits concern logical file bytes; filesystem allocation and metadata overhead
are additional. Free-space monitoring is not a disk reservation or quota.

The invocation checks stop/deadline at CSV-write and verification boundaries,
and polls free space periodically and before starting each new chunk. The indexed
renderer also retains its per-chunk byte/time bounds. Blocking filesystem calls
can exceed a sampled deadline; this is cooperative stopping, not a hard OS timer.
CPU reservations, whole-job memory and native-host allocation are not established.

For shorter work sessions, use `run --max-chunks 1`. When chunks remain, it
returns status `stopped`/exit 3 after committing that invocation's chunk allowance.
Run the same command again to continue; omit the option to use the normal limit.
Verification of the existing prefix still consumes invocation time.

## Checkpoint and recovery semantics

`plan.json` defines the immutable job. `checkpoint.json` records a contiguous
prefix of chunk filenames, row windows, hashes, byte sizes, row widths and null
counts. Before trusting that prefix, restart streams its files against the
current pinned row generator; a self-consistent edited hash is not sufficient.
Changed code/source/recipe/DDL/profile inputs, corrupt data, reordered checkpoints,
unexpected files, symlinks or external hard links cause refusal. Restore the exact
registered inputs to resume, or create a separate job for changed inputs.

Writing follows this order:

1. Exclusively create the next `.part` file and stream rows within all budgets.
2. Flush and sync its data, publish the immutable `.csv` link without replacing
   an existing chunk, and sync the directory.
3. Remove the staging link, sync, then atomically replace and sync the checkpoint.

On restart, a valid uncheckpointed next CSV is replay-verified and adopted. A
partial `.part` must match the expected byte prefix before it is discarded and
that chunk is regenerated. A corrupt partial is preserved and refused. Known
uncommitted metadata scratch files are discarded only after validating the saved
prefix. Committed CSV chunks are never appended to or rewritten. A nonblocking
exclusive lock prevents cooperating materializers from using the same directory.
Use a private operator-owned directory; this is not a sandbox against arbitrary
writers controlling its parent directory or the generator code.

After all chunks are committed, the materializer revalidates them and writes
`complete.json` atomically. Completion is recoverable if the final checkpoint
survives but the receipt write is interrupted. A valid existing completion receipt
is checked and preserved, not replaced. `verify` requires both a complete validated
prefix and the matching receipt; it never promotes an incomplete selection.
`attempt.json` retains the latest completed invocation outcome when writable;
it is diagnostic and cannot substitute for a checkpoint or completion receipt.

File/directory syncing establishes the intended ordering on supported local
filesystems; storage hardware, OS and filesystem durability guarantees still
apply. Network filesystems and hostile concurrent writers are not certified.

## Cancellation and failures

Create `STOP` inside the job directory to request a cooperative pause. Remove
that marker deliberately before restarting. SIGINT/SIGTERM request stopping at
the same boundaries; already committed chunks remain valid. Exit codes are 0
for completion/verification, 3 for a cooperative stop/chunk limit/deadline, 130
for SIGINT and 143 for SIGTERM. A refusal or operational failure returns 1;
argument-parser syntax errors return 2. Check `attempt.json` and the checkpoint.

SIGKILL or process death can leave no final attempt record and may retain partial
or orphaned files. The next `run` validates that state before recovering. It does
not delete unknown/corrupt output or alter any earlier job directory. If writing
failure metadata also fails, the durable checkpoint and retained files remain
the recovery evidence. No success is inferred from a missing/incomplete receipt.

## Scope of completion

`complete.json` means only that the **selected source windows** are materialized
and validated. Its kind is `bounded_source_selection_complete`. Plans, completion
receipts and attempt records set `full_tier_generated=false` and `qualifying=false`.
Checkpoints bind to that frozen plan and cannot broaden its selection. This
layout is not an analytical result bundle or a complete
CDM source manifest and is not accepted by the small-preview database loader.

Full-tier streaming orchestration, source-wide histograms, resource registration,
scoped native observer access, calibrated capacity/headroom and matched analytical
qualification remain separate work. This command never allocates a server,
changes host permissions or launches a full S1/S2 source.

For measured widths, exact duplicates, marginals and conditional distributions of
a completed selection, use the separate [source inventory collector](source-inventories.md).
Its output belongs outside the materialization directory; it does not broaden
the selected windows or establish full-tier coverage.
