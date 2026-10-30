# Exact weighted quantiles on PostgreSQL

`generateMeasurementReport()` supports `numericStrategy = "weighted"` as an
explicit alternative to the default `"reference"`. Both implement the unchanged
`measurement.numeric_summary` version 1.0.0 in the frozen profile. All other
measurement, observation, request, precision, failure and publication semantics
stay the same. Only marked synthetic PostgreSQL fixtures are accepted.

```r
# Same trusted fixture configuration as the measurement reference guide.
library(AchillesNext)
source("tools/tracer_fixture_config.R")
outputDir <- tempfile("weighted-measurement-")
do.call(generateMeasurementReport,
        c(config, list(outputDir = outputDir, numericStrategy = "weighted")))
# Validate the bundle, then open using the installed viewer:
viewResults(outputDir)
```

Run from the checkout root after fixture setup. See the
[measurement guide](measurement-reference.md) for validation, configuration and
source restrictions. Choose `numericStrategy = "reference"` to retain physical
order-statistic calculation. Unknown strategies are rejected before connecting
or writing. There is no automatic or data-driven strategy selection.

## Algorithm and exactness

Both paths share the selected physical rows, observation-membership check,
ordered numeric eligibility rules, exact frequency inputs and n/sum calculation.
Units and raw NULL/zero operators remain separate. No conversions, comparator
pooling or changes to missing/suppressed states are introduced.

The reference sorts every eligible physical value and selects order statistics
at rank `ceil(a × n / b)`. The weighted operator sorts distinct exact NUMERIC
values and computes `SUM(frequency)` over an explicit `ROWS` running frame.
It selects the first value whose cumulative weight reaches the requested rank.
The rank uses exact integer `DIV(a × n + b − 1, b)`, with NUMERIC cumulative
weights, so large n does not pass through FLOAT or JavaScript Number.

Ties retain their full frequency. A boundary equal to a cumulative weight selects
that value; a boundary just after it selects the next. There is no physical
expansion, cumulative self-join, interpolation or approximate percentile. Empty
observed groups retain n=0 with all statistics NULL. Exact sums and rational
means are unchanged. Insignificant decimal trailing zeros are not a numerical
parity difference; validation never permits rounding or epsilon tolerances.

Grouping and scanning the input is still required. A reduction from N physical
rows to D distinct values can reduce numeric sorting/ranking work. It does not
promise faster complete reports, especially when D approaches N or other
measurement outputs dominate. Frequency tables stay restricted in-database
scratch and are not exported.

## Bundle and viewer compatibility

The request/profile/metric versions are unchanged. The manifest records
`AchillesNext-measurement-reference` or `AchillesNext-measurement-weighted` as the
generator name, and the run identity includes the strategy. Both use the same
provider, typed metric documents and installed React view. The viewer rejects
unsupported implemented outputs for either generator. Reopen a generated bundle
with `viewResults(outputDir)`; viewing needs no Node/npm/Shiny. Contributor
validation/benchmark commands still require Node.

These are partial 12-of-15 development reports. Capability and execution reports
remain unsupported, disclosure unapplied and durable snapshot identity unknown.
Neither strategy can publish a complete current pointer or authorize input reuse.

## Reproduce parity and optional measurements

Install the package and contract dependencies first. The saved fixture
configuration must define `config` and `fixtureConnection("owner")` as in
`tools/tracer_fixture_config.R`. The harness verifies the marked synthetic
database and nonsuperuser fixture owner before creating scratch.

```sh
python3 tools/benchmark/weighted_quantiles.py \
  --config tools/tracer_fixture_config.R \
  --output-dir /path/to/local/new-quantile-evidence
```

This runs independent Python-sorted oracle cases against both installed SQL
operators, including deterministic random ties, small N, negatives, exact
fractions, different decimal scales, missing/non-finite values and 100,000
physical/distinct values. Two huge-weight boundary cases use independent Python
integer cumulative ranks because expanding their physical population is
impractical; that limitation is explicitly recorded.

Add `--benchmark` to measure four synthetic workloads with one excluded
correctness preflight, one excluded warmup and five retained trials per strategy.
Order alternates per trial; all trials and observed minima/medians/maxima are
retained. No p95 is inferred from five warmed serial samples. Each native pair
is contract-validated and compared across every metric after removing run IDs.

The numeric-stage timings include separate materialization of classified rows
and grouped frequencies, then the selected operator and JDBC result transfer.
Full report timings independently run the actual generator, including connection,
prerequisites, all implemented metrics, JSON materialization/file export and
manifest writing, followed by timed contract validation. Export is included in
generator wall time; a separate export value stays unavailable. These measurements
are not durable publication, browser latency, all-15-output or legacy-dispatcher
benchmarks. Source preparation/ANALYZE and instrumented EXPLAIN probes are excluded
and identified separately. Readback/parity audit overhead is outside the retained
slice timings and included in harness wall time.

Fixed session settings are 64MB work_mem, no parallel gather workers, JIT off,
30-second statement and 2-second lock timeouts. Data is warmed, unindexed and
synthetic; background contention, server CPU/peak RSS and cold-cache behavior
are not controlled/measured. SQL/source hashes, runtime, source content hashes,
plans/buffer counters, individual trials and generated bundles stay in the chosen
local evidence directory. Optional `--budget-file /path/to/reviewed-budgets.json`
applies local numeric and regression thresholds to the report; no delivery
threshold or automatic promotion is built into the package. The optional JSON
uses `numeric_compute_materialize_ms` (workload ID → positive milliseconds) and
`validated_slice_regression` (`multiplier` ≥ 1 and `allowance_ms` ≥ 0); all
thresholds must be finite numbers.

Parity uses session-local temporary tables rolled back on exit. Benchmark mode
also creates new per-process marked source schemas for native generation, then
drops only those owned schemas. Canonical fixtures, SynPUF and existing results
are not reset; database grants/global settings are unchanged. Failed runs leave
their local evidence for inspection; use a new output directory to retry.
