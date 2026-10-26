# Synthetic PostgreSQL reference benchmark

This developer harness measures a **selected published Achilles 1.7.2 SQL slice**: analyses 1, 1800, 1801 and 1815 plus the numeric-distribution export query. It uses the installed Achilles templates and SqlRender 1.19.0 through `psql`. It does not call the complete Achilles dispatcher or `exportToJson`, run all default analyses, generate a native AchillesNext bundle or measure a browser/user workflow.

## Run

Prerequisites: the [marked fixture database](../../tests/fixtures/postgresql/README.md), `psql` and Python versions matching its lock, R with Achilles 1.7.2, SqlRender 1.19.0 and jsonlite. The harness does not install packages, download data, change database grants or reset fixtures.

From the checkout root, use the saved PostgreSQL service state and a **new evidence directory outside the checkout**:

```sh
python3 tools/benchmark/reference_baseline.py \
  --postgresql-state /path/to/local/postgresql-state \
  --output-dir /path/to/local/benchmark-evidence/run-001
```

Output includes `report.json`, rendered SQL/provenance, each workload's input/oracle, five measured trial records after one warmup, query plans and synthetic export artifacts. Raw evidence may contain detailed synthetic records and local environment information; keep it outside the package checkout. Existing evidence directories are never overwritten.

The [workload definition](../../tests/fixtures/benchmark/workloads.json) fixes the parameters and resource bounds. Original installed analysis bytes must match the Git blob hashes for the [published baseline](../../inst/analysis/legacy-baselines.json). The export template is separately pinned. Package-version labels alone are insufficient. The audited development snapshot is a separate definition reference and is not substituted for this published execution baseline.

## Inputs and correctness

The harness reads only five allowlisted, marked source schemas in `achilles_next_fixtures`: tiny A on CDM 5.3/5.4/5.5 and native GiBleed 5.3/5.5. It copies the required columns to session-local tables without indexes. Source-specific indexes are not inherited. Two deterministic cases each create 100,000 measurements and 10,000 people, with either 32 or 4,096 distinct exact values. Every fifth person has an overlapping duplicate observation period. Numeric values use `(row_index mod distinct_count) + 0.125`; no randomness is involved. Recorded distinct cardinality, maximum frequency, row counts and content hashes accompany timings.

The existing read-only runner intentionally lacks database TEMP permission. The harness uses the isolated nonsuperuser fixture owner for temporary tables, checks the database and source ownership/markers, and rolls back every session. It does not use a superuser or change the runner's privileges. Existing source, SynPUF and result tables are not modified.

Before reporting timings, an independent Python oracle enumerates interval membership and multiplicity, distinct people and sorted empirical quantile ranks. A preflight must match legacy counts and p10/p25/p50/p75/p90/min/max. The same checks run after every trial; input/terminology hashes must remain unchanged. Decimal normalization does not use a finite precision arithmetic context. Export files preserve the original server JSON bytes; audit decoding uses exact Decimal values, never a float round trip. Legacy JSON numeric literals still require a precision-aware consumer and do not satisfy the native contract's decimal-string transport.

Legacy semantics remain visible: observation overlaps multiply records, nonzero operators are pooled and NULL units are excluded from numeric distributions. Alpha observation membership counts are recorded separately. A difference between legacy and alpha scope is not an algorithm failure, nor permission to accept a wrong native result. Matched-scope oracle checks are required before any later speed comparison. Numeric-empty GiBleed workloads cannot establish distribution performance; the deterministic distinct-value cases address that gap.

The SQL text and translation are both retained. SQL Server `FLOAT` syntax is not by itself evidence of floating-point execution on another engine; assess the actual translated types and outputs.

The published 1.7.2 distribution export contains a unit label without its concept ID. Its exported quantiles are checked against the oracle using captured local terminology; ambiguous unit labels fail validation. This does not make the old format equivalent to a native typed result with explicit unit/operator identity.

## Timing and resources

- Fixed session settings: `work_mem=64MB`, parallel gather workers 0, JIT off, statement timeout 30 seconds and lock timeout 2 seconds. R rendering and PostgreSQL execution run serially.
- Source copies, temporary input generation and input statistics collection are preparation. They are excluded from the selected generation phase, but included in the separately labelled `psql_process_wall_ms` together with connection, input extraction and process overhead.
- `generation_compute_materialize_ms` sums `psql` statement timings for the four translated analyses, their temporary-table operations and merging the selected result tables. The raw `server_statement_ms` arrays contain these client-observed elapsed durations, including local protocol/command overhead. Compute and materialization cannot be separated reliably here; their separate values remain NULL.
- `legacy_export_query_ms` times the published distribution-export SELECT wrapped in PostgreSQL JSON aggregation. This includes server serialization and `psql` result handling. It is not the complete R export pipeline.
- `audit_file_write_ms` and `audit_file_read_decode_ms` describe the harness's local JSON artifact, not durable publication or rendering. No fsync/atomic-publication claim is made. Publication and view durations remain NULL.
- The first SQL execution is a discarded correctness preflight; the next is an excluded warmup. Five retained repetitions yield median, min and observed max. No p95 or confidence interval is inferred from these warmed serial samples. R render/translate samples have their own excluded first sample and use R's elapsed-time resolution.
- No cache eviction, server restart or global setting change is attempted. Input capture and correctness checks warm caches. Background contention is not controlled and trials are not independent institutional workloads.
- Separate `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, TIMING OFF, FORMAT JSON)` probes retain physical plans, local/shared/temp buffer counters and execution statistics. These instrumented probes are excluded from baseline samples. Server peak RSS, server CPU time and uncollected I/O telemetry remain unavailable.

[PostgreSQL EXPLAIN documentation](https://www.postgresql.org/docs/17/sql-explain.html) describes the measured plans and execution side effects. Transactions use [repeatable-read isolation](https://www.postgresql.org/docs/17/sql-set-transaction.html), with explicit rollback of temporary writes. Separate sessions are checked for equal input content; the content hash is a benchmark identity, not an institutional snapshot assertion usable for application cache/resume.

These measurements establish a reproducible local reference, not a production speedup or full CDM clinical coverage. User-task protocols, participant records and project budgets are maintained outside the package repository.
