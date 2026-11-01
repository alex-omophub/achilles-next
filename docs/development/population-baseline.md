# Population and observation baseline

`generatePopulationObservationBaseline()` precomputes 19 frozen core outputs from
ordinary PostgreSQL OMOP schemas into the typed aggregate store. It is separate
from the marked synthetic 15-output measurement tracer. Seven PERSON outputs cover
total, recorded gender/birth year/race/ethnicity and birth-year × gender/race ×
ethnicity. Twelve observation outputs cover union opportunity, continuous coverage,
year/gender/approximate-age counts, first-age and first-interval summaries and
histograms, interval counts, total days, boundaries, raw types and integrity.

This experimental producer creates a **building** release under the 142-result
profile. Its 19 outputs have complete declared scope. The other 123 have
`not_requested / generator.not_implemented`, incomplete coverage and no payloads.
They are neither zero nor policy-suppressed results. Full-profile sealing rejects
the release. No receipt, approval, approved pages or current pointer is created.

## Setup and generation

Use a dedicated installer with `initializeResultStore()` to create fresh results
and serving schemas. The worker needs source SELECT on the required PERSON and
OBSERVATION_PERIOD columns, database TEMPORARY, results-schema USAGE, SELECT on
the profile/producer/readback tables, INSERT on source/run/operation/release/dataset/
cell/denominator tables, and UPDATE on run/release tables (including trigger-driven
content revisions).
The installed release-transition trigger also requires SELECT on validation
receipts, even for building revisions; no receipt INSERT/UPDATE privilege is needed.
Functions/installation and disclosure approval remain institution-administered;
generation itself requires no serving/publication authority.

The generator rejects source INSERT/UPDATE/DELETE/TRUNCATE or column INSERT/UPDATE
privileges. Required identifiers/demographics must be integer columns and interval
endpoints DATE columns. Missing, inaccessible or mistyped dependencies fail rather
than return fabricated zeros.

```r
baseline <- generatePopulationObservationBaseline(
  workerDetails, cdmSchema = "cdm", sourceId = "institution-source",
  resultsSchema = "achillesnext_results", declaredCdmVersion = "5.5")
baseline$release_id
baseline$publishable  # FALSE: 19 of 142 outputs generated
```

Full valid recorded observation history is the default. Optional
`window = list(start = "2020-01-15", end = "2024-06-20")` clips observed coverage,
year and continuous panels. Demographics, raw types/integrity, first-interval
statistics, interval-count and total-days histograms retain their frozen full-history
populations. No ten-concept or 120-month fixture restriction applies.

## Semantics and exact values

- Null/duplicate PERSON IDs fail. Raw demographic NULL, zero, negative and
  unrecognized values remain distinct, without imputation. The unreleased core v2
  schemas/codec now allow string `"null"` for gender, race, ethnicity, birth year
  and raw period type. Its key `N` differs from every signed integer. Counts and
  IDs remain strings; numerical definitions and legacy v1/v1.1 schemas are unchanged.
- Raw observation rows are classified in order: null person, orphan person,
  null endpoints, reversed interval, valid. Types retain every physical row,
  including duplicates/invalid intervals. Only valid linked intervals enter the
  union. Non-NULL endpoints outside finite Gregorian years 0001–9999, including
  infinity, fail instead of silently inventing a new integrity category.
- Overlap, duplicate and adjacent intervals are merged. Inclusive person-days
  count each observed day once; window/month/year people are distinct at each
  grain. Empty intersections have zero days. Monthly people are never summed to
  obtain window people.
- Complete calendar bounds use `full_calendar_period = "true"`. Partial edge
  periods and the full-scope clipped window use `"false"`; their continuous counts
  describe those explicitly clipped bounds, not full-calendar opportunity.
- Approximate year-age uses calendar year minus recorded birth year. First-age
  uses first merged start; yearly panels use that year's anchor. Invalid/missing
  birth years and proxies outside 0–130 have eligibility/unknown strata. No precise
  birthday age is inferred. First-interval durations are inclusive and measured
  before clipping; duration summaries include unknown-age strata.
- Summaries retain exact `(sum,n)` means and integer-rank quantiles, with included
  `n` reconciled to eligibility counts. All-ineligible groups have `n = "0"` and
  NULL statistics. Histograms include people with zero intervals or zero days.
  Empty raw sources, no eligible population and ungenerated outputs differ.

With no valid intervals and no requested window, coverage has one full-scope row
with `"null"` bounds/zero values; no calendar is invented. An explicit window gives
dense clipped month/year rows with known zero opportunity.

## Atomic storage and source-independent readback

One writable repeatable-read worker materializes narrow backend-private
`achillesnext_` TEMP tables and streams numerical aggregates through 128-row JDBC
fetches into typed storage. No patient-level intermediate returns to R. Commit
saves the aggregates and drops TEMP; failure, interrupt or cancellation rolls back
all new results. This producer does not create a durable failed-run recovery record.

The default `maxStageBytes` is 64 MiB, checked after each relation/index stage.
It cannot prevent one statement's transient overshoot or bound sort/hash spill.
Statement/lock timeouts are transaction-local (30 seconds/two seconds); server
settings are unchanged. `statementTimeoutMs` lets an operator increase the statement
budget for larger sources; JDBC timeout is aligned above it. Existing store APIs
keep their previous timeout. Larger sources may need operator-selected budgets and
preflight. Production resource/representative-scale qualification is outstanding.

Unknown durable identity means a fresh generation transaction and release. A
backfill can alter history/first-interval statistics; old saved rows retain their
as-generated values. Reading never checks or refreshes the source.

```r
context <- readPopulationObservationBaseline(
  resultsReadDetails, "achillesnext_results", baseline$release_id,
  visit = function(metricId, row) {
    print(list(metric = metricId, dimensions = row$dimensions, values = row$values))
  })
context$profile_complete  # FALSE
```

This restricted developer readback needs SELECT on saved results, without CDM
permission. It validates rows/inventory/reconciliations in a read-only repeatable-read
snapshot. Building facts are not immutable approved pages: this is neither a UI
provider nor a disclosure/distribution boundary. Approved serving still requires
full generation, validation and institutional approval. Serving principals continue
to have no base-results/CDM access.

## Contributor checks

After installing the package and configuring the marked synthetic sandbox/JDBC:

```sh
population_proof_root="$(mktemp -d "${TMPDIR:-/tmp}/achillesnext-population.XXXXXX")"
python3 tools/test_population_baseline.py \
  --config tools/tracer_fixture_config.R --output-dir "$population_proof_root/baseline"
Rscript --vanilla tests/tracer/result-wire.R "$population_proof_root/row-corpus.json"
node packages/contracts/tools/validate-v2-corpus.mjs "$population_proof_root/row-corpus.json"
```

The temporary parent is private and writable; the baseline child does not exist
yet, as required by the harness. Keep it outside the checkout and retain or remove
the temporary evidence after review.

The independent Python day-set/integer-rank oracle checks all 19 results, states
and denominators for eight tiny cases under three declared schema versions.
These are required-column fixtures, not full CDM certification. Tests cover empty
and malformed intervals, partial periods/leap days, NULL/zero/large identifiers,
shared age buckets, date bounds, multi-fetch streaming beyond 128 rows, backfills,
early/late cancellation, budget failure,
infinite dates, duplicate IDs and missing columns. Fresh-process saved readback
runs with source access revoked; full-profile sealing is rejected. Temporary
schemas/grants are restored. No scale/performance or production claim is implied.
