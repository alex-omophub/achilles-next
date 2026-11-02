# Whole-source measurement baseline

`generateMeasurementBaseline()` precomputes the nineteen measurement outputs in
`core-characterization-v2`, together with the existing population, observation
and eight-domain reports. It accounts for **138 of 142** outputs. The four source/
execution metadata outputs remain not requested, so this is a restricted building
release and cannot be approved as the complete core profile yet.

This PostgreSQL batch reads all recorded measurement rows and all raw concepts,
including NULL, zero, unknown and wrong-domain IDs. It preserves physical
duplicates. Record counts and linked distinct people are separate measures;
orphan/null people are counted explicitly and never become valid PERSON members.
No concept selection or chart interaction runs a source query.

## Generate and read saved results

Use an initialized restricted store and institution-controlled worker credentials
with SELECT-only source access, TEMPORARY and the result permissions described in
the [domain baseline guide](domain-baseline.md). The source requires the existing
nine-domain tables plus PERSON, OBSERVATION_PERIOD and local CONCEPT, with actual
columns probed independently of the declared CDM version.

```r
run <- generateMeasurementBaseline(
  runnerDetails, "cdm", "local-source", "results", "5.5",
  maxStageBytes=256*1024^2, maxAggregateRows=1000000L)

readMeasurementBaseline(resultReaderDetails, "results", run$release_id,
  function(metricId, row) consumeSavedRow(metricId, row),
  metricIds="core.measurement.numeric_summary",
  conceptTag=list(kind="id", value="3004249"))

page <- listDomainConcepts(resultReaderDetails, "results", run$release_id,
  "measurement", pageSize=64L)
```

The example credentials and consumer are institution supplied. Readback validates
the entire saved inventory before emitting a selected row; it uses restricted
result tables without CDM/vocabulary access. Concept pages retain exact raw tags
and bind cursors to release/revision/domain. These are development building-result
readers, not approved UI providers or a new general report renderer. Unknown saved
periods and unsupported filter grains fail explicitly; they do not schedule work.

The existing `generateDomainBaseline()` / `readDomainBaseline()` still produce/read
the 119-output baseline. Use the measurement reader for a measurement release.
`generateMeasurementReport()` retains its older bounded synthetic, observed-window
profile and viewer. It is a different population/version, not relabelled parity
with this all-recorded baseline.

## Saved reports and meanings

| Reports | Saved grain and meaning |
|---|---|
| Capture, source, type | Full-history raw concept counts; capture also has separately computed month/year/undated and ALL selectors. Source text exports only null/blank/nonblank presence. |
| First age, event frequency, distinct concepts | Shared domain definitions: first dated record's approximate year-age; whole-scope person histograms with zero-event PERSON members; no incidence claim. |
| Integrity, observation qualification | Independent defect flags and exclusive observation-membership categories. Observed capture/year-gender-age reports use the merged inclusive observation union and same-period saved denominators. |
| Representation | All eight supported numeric/coded/source-text presence combinations per observed raw concept, including zero-count combinations. Numeric presence includes non-finite values; source text trims only U+0020 spaces. |
| Units, coded values, operators | Separate NULL, zero and every raw signed ID. No unit conversion, vocabulary roll-up or pooling of operator strata. |
| Numeric eligibility and summary | Exact values by known positive Unit-domain concept and separate NULL/zero operators. Summary eligibility follows the frozen order: missing numeric, non-finite, unit NULL, unit zero, unknown/wrong-domain unit, nonzero operator, eligible. |
| Range low/high summaries | Independent exact finite boundary summaries within known-unit strata, regardless of result/other-bound presence, operator or reversed paired bounds. Other raw unit strata retain their first-match boundary exclusions as eligibility-only rows. They describe recorded boundaries, not valid clinical intervals. |
| Range status | Same-row value/unit/operator/bounds. Ordered exclusive reasons: missing/non-finite value; unavailable unit; explicit operator; both/one bounds missing; non-finite bound; reversed bounds; below/within/above. Endpoints are inclusive. No normal-range harmonization or clinical normality claim. |

The capture/observed, age, histogram and integrity families account for ten
measurement outputs; the representation/value/range families account for nine.
All nineteen use the frozen definitions and existing typed row schemas.

Numeric eligibility deliberately differs from the old tracer's ordering: the
core profile checks unit exclusions before operator exclusion. Raw NULL and zero
operators mean no explicit comparator, not proof of uncensored data. A positive
local Unit-domain concept establishes grouping; historical vocabulary invalidity
does not erase the recorded unit identity.

## Exactness and resource limits

Exact NUMERIC/integer source fields are required. Floating physical types are
rejected before any cast. Analytical values cross JDBC/R/JSON as strings, including
large counts and arbitrary supported decimal scales. Mean is the exact sum/n
pair; quantiles use the physical-value rank `ceil(p*n)`, preserving duplicates.
No approximate percentile, standard deviation or interpolated mean is substituted.

The default `numericStrategy="weighted"` uses cumulative frequencies. The
`"reference"` operator sorts every eligible physical value. Both apply to numeric
and range-boundary summaries; first-age uses the shared exact domain operator in
both modes. The strategy is recorded in requested-work identity. Observed allowed
unit/operator strata with no eligible values retain n=0 and NULL statistics.
Unobserved unit/operator cross-products and monthly summaries are not invented.

Set-based source-private stages are shared across reports. The result writer uses
the [bounded persistence path](persistence.md). Intermediate numeric-value
frequencies, patient IDs, source text and individual measurements stay private
to source execution. Event-frequency and distinct-concept histograms are saved
aggregate outputs. The current
[source/store topology](source-store-boundaries.md) remains one PostgreSQL database.
Warehouse adapters and remote aggregate transfer remain unimplemented.

`maxAggregateRows` (1–1,000,000) bounds the total generated aggregate inventory,
including population and other domains. It fails rather than truncates. Stage/
index bytes are checked after materialization; `maxStageBytes` does not cap peak
disk/sort allocation. Per-statement timeouts and cooperative cancellation are
explicit. A failed batch rolls back the complete candidate, including prior
writer flushes; no durable checkpoint or source reuse is inferred. Saved reads
have a separate private spool byte budget.

## Verify from a checkout

After package installation and [fixture setup](count-tracer.md#developer-setup),
run from the repository root:

```sh
Rscript --vanilla tests/tracer/measurement-baseline-offline.R
python3 tools/test_measurement_baseline.py --full-matrix \
  --config tools/tracer_fixture_config.R \
  --output-dir "$(mktemp -d)/measurement-baseline"
```

Without `--full-matrix`, the suite uses the CDM 5.5 adversarial and empty-source
cases plus a physical-row reference comparison. The full matrix adds 5.3/5.4
schemas, an accessible empty measurement domain and an unobserved population.
It compares every generated clinical/domain output and population dependencies
to independent Python Decimal/day-set oracles. It also checks exact strategy
parity, typed concept paging, source-denied saved readback, failure/cancellation
rollback, budgets, missing/denied columns and late corruption with zero emitted
rows. Synthetic schemas and temporary permissions are cleaned up on exit.

This is correctness evidence, not representative-scale qualification, legacy
distribution equivalence, warehouse support or complete core publication.
