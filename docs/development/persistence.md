# Bounded numerical aggregate persistence

Population, eight-domain and registered-profile generation use the same internal
bounded writer. It validates each typed row, groups compatible numerical column
sets into multi-row `INSERT ... VALUES` statements and inserts all batch cells
before their denominator edges. Exact counts/decimals stay canonical strings
until PostgreSQL parses their numeric literals. No patient rows or CDM queries
are introduced by persistence.

The default queue holds at most **128 rows** and **1 MiB of conservatively counted
SQL text**. It flushes before exceeding either bound and rejects a single oversized
entry. Numerical row validation and the existing 64 KiB row limit still apply.
These bounds cover queued SQL, not total R/JVM memory or source scan/sort work.

Population/domain producers also flush at metric boundaries so subsequent
denominator joins can see completed targets. Registered-profile dependencies can
share one batch: cells are inserted before any edges. A failed writer cannot be
reused. SQL errors and cancellation roll back the surrounding generation
transaction, including previously flushed batches; a flush is not a commit or
durable checkpoint.

The existing SQL guards remain authoritative. Every cell/edge mutation still
checks the building-release lock and advances its content revision. Batching
reduces submitted write statements; it does **not** reduce the number of per-row
revision updates. Sealed content, receipt binding and publication semantics are
unchanged. No store migration, trigger bypass or output-format change is involved.

Generation operation telemetry includes a `persistence` object with written row/
edge counts, cell/edge statement counts, SQL bytes, configured queue bounds and
observed peak queued rows/SQL bytes. It is generation telemetry, not an analytical
result. Total generation, source aggregation and publication costs must still be
measured independently. The one-row internal seam remains available to contributor
tests and benchmarks as a reference.

## Reproduce a bounded persistence pilot

After [fixture setup](count-tracer.md#developer-setup) and package installation,
run from the checkout root:

```sh
python3 tools/benchmark/persistence.py \
  --config tools/tracer_fixture_config.R \
  --output-dir "$(mktemp -d)/persistence" \
  --sizes 100,1000,5000 --trials 3
```

The harness refuses an unmarked database or an output directory in the checkout.
It creates disposable results schemas, prepares synthetic typed aggregates outside
the timed section and alternates row/batch trial order. It records elapsed/CPU
time, submitted JDBC write calls, SQL bytes, managed R-heap high water, transaction
row statistics and exact revision deltas. Independent SQL checks and canonical
readback digests verify values and parity outside timing. A small executed
`EXPLAIN (ANALYZE, BUFFERS, WAL)` probe records server work separately.

The managed-heap measure excludes JVM/native allocations. JDBC execute submissions
are measured; network packets are not captured. Transaction timing includes
connection/commit and diagnostic probes, while writer timing includes row
validation, serialization and writes. The server probe excludes R preparation
and is not an end-to-end comparison. The bounded pilot does not establish
production-scale performance or throughput on another engine.

## Safety checks

The CI conformance tests cover mixed count/eligibility/summary rows, exact large
values, row/byte bounds and failed-writer reuse. The marked registered-profile
integration checks rollback after earlier flushes, cancellation, sealed-write
rejection, stale receipts and both writer/sealer orderings using observed database
lock waits. Independent domain/population oracles continue to check numerical
outputs. Timing comparisons remain an explicit contributor command rather than
an additional CI job.
