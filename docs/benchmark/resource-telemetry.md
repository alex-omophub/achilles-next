# Small-fixture resource and phase telemetry

This opt-in contributor harness observes one synthetic PostgreSQL core-profile
pair with four people and 24 clinical events. It runs all 142 outputs with and
without observers, checks parity after declared timestamp/timing normalization,
natively validates and publishes both paths, and tests cancellation after
approval. Measurements are sidecars, not changes to analytical
metadata, package APIs or the frozen result contract.

## Run

Use the [fixture environment](../../tests/fixtures/postgresql/README.md), install
the current package and configure R/JDBC as in [conformance](../development/conformance.md).
From the checkout, choose a new output directory outside the checkout whose
parent exists:

```sh
mkdir -p ../benchmark-output
python3 tools/benchmark/telemetry.py --state .local/postgresql \
  --config tools/tracer_fixture_config.R \
  --output-dir ../benchmark-output/telemetry --with-projected
```

Default publication scope is restricted/full; `--with-projected` also measures
the same two-PERSON projection for each path. Both use artifact 2.0.0. The optional
saved-label/index 2.1.0 path, browser heap, serving-only latency and representative
scale remain separate qualification work. No CI job or dependency installation
is added; short offline sampler regressions join Python discovery.

Only new marked synthetic source and disposable result/serving schemas are used.
The fixture runner remains SELECT-only on source. TEMP privileges and temporary
schemas are cleaned up. There is no database restart, cache drop, statistics reset,
server setting change, cgroup allocation/membership change or large-tier control.
Protocol R files are copied before execution so an editor cannot change a running
R input stream. Source pins are checked before success; partial outputs survive
failure and are never treated as a passing receipt.

## Measurement scope

| Observation | Meaning and limits |
|---|---|
| Phase wall time and R self CPU | Generation, metadata assembly, seal/validation, publication, artifact admission, filesystem writes, approval, commit and file-read sample. R includes its in-process JVM; self CPU excludes PostgreSQL/child comparisons. Nested observations overlap and must not be summed across levels. |
| Writer and SQL counters/timing | Original bounded writer counters, content revision, method costs and statement families. Cell SQL includes existing revision-trigger work; trigger CPU is not isolated. Streams include client callbacks. No raw SQL/clinical values enter the phase journal. Native producer stage/SQL-hash telemetry is retained separately. |
| Temp relation allocation | Sampled after CREATE/index within the job transaction. Includes observed relation/index/TOAST allocation, not executor spill or every transient peak. |
| Worker CPU/lifetime RSS | OS `wait4` child usage and platform-correct RSS units. R/JVM worker scope, not whole-job/database/cache memory. Sampled RSS is retained separately; missing samples stay unavailable. |
| PostgreSQL counters | Read-only database temp/block counters and instance WAL endpoints. Shared with other activity, asynchronously flushed, and affected by observer queries. Reset/unknown epochs invalidate deltas. Disabled I/O timing is unavailable, not zero disk work. |
| Storage | Allocated bytes for owned source/results/serving relations, shared database size, sampled logical output bytes and output-volume free space. Not physical I/O, isolated WAL/temp volume peaks or an aggregate across aliased volumes. |
| Optional cgroup v2 | `--cgroup /existing/path` reads memory current/peak, CPU, device I/O and worker membership. The harness neither creates nor resets the cgroup. It does not establish inclusion of PostgreSQL workers/shared cache, exclusivity or reference-host registration. Missing allocation/files remain explicitly unavailable. |

The optimized adapter optionally observes its transaction, writer and metadata
helpers. Publication uses copies of unchanged installed function bodies with
observer bindings for shared helpers. No namespace binding or installed source
is modified. The unobserved generation controls and independent expectations
check that instrumentation preserves all 142 outputs, except the existing declared
factual timestamp/timing normalization. All complete exports are independently
traversed and compared with their candidates.

Observer SQL/timers add overhead and can warm caches. The worker is fresh; server,
database and OS caches are uncontrolled. Baseline/control candidates and cancellation
are auxiliary work; process-lifetime totals include them. Phase measurements are
inclusive observations, not a registered paired speedup trial or a new resource
budget for the product.

## Stops, failure evidence and cleanup

Sampling defaults to 0.5 seconds, a 600-second deadline, 4 GiB worker-RSS threshold,
256 MiB logical output threshold and 64 MiB minimum free output-volume space. These
are small-development guard settings, not qualification budgets. CLI byte options
and intervals/deadlines are bounded; no option launches a scale tier.

The supervisor records a stop file when a sampled threshold/deadline is exceeded.
R polls it between SQL operations and streamed rows; statements have 30-second
local timeouts. After five seconds the supervisor may send one SIGINT to its owned
worker. These are cooperative controls, not hard OS reservations or a guarantee
of termination at the exact threshold. Startup and an in-flight operation may
finish before observing the stop. No automatic SIGKILL or signal to PostgreSQL is
used; abnormal process death may require recovery from `fixture-state.json`.

The cancellation probe requests cancellation after synthetic approval and the
first database page insert. It rolls back the attempted publication before promotion, and verifies that publication count and
previous current pointers are unchanged, with staged files removed. It records the
expected failed phase rather than erasing it from the observations.

`worker.log`, `samples.jsonl` and `process-telemetry.json` survive a failed worker.
`phases.jsonl` records phase boundaries/status and a final SQL/writer summary;
`phase-report.json` retains incomplete phases and scoped/reset-aware deltas.
`results.json` contains the correctness/cancellation results and native operation
telemetry. `receipt.json` is written only after parity, all exports, stable code
pins and schema/privilege cleanup pass. It explicitly sets `qualifying=false`.
A stopped run has no success receipt. The synthetic source is removed by the
controller after the worker is reaped; R attempts store and privilege cleanup.

On a development Mac, database CPU/memory, a verified whole-job cgroup peak and
browser heap remain unavailable. A dedicated registered reference environment,
complete process/cgroup membership, sampler validation on that host and measured
budgets are still required before any scale/performance claim.

## Observer regressions

From the checkout root, run `Rscript --vanilla tests/tracer/resource-telemetry-observer.R`
after installing the current package to check journal failure handling without
PostgreSQL. Add
`tools/tracer_fixture_config.R` as its argument to reproduce a real SQL probe
failure and verify savepoint recovery on the marked synthetic database. Failed
temporary-allocation samples are counted separately as unavailable; probe errors
roll back to their savepoint before analytical SQL continues.
