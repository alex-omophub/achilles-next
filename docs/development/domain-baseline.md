# Eight-domain baseline and concept/time reports

Numerical aggregates use the shared [bounded persistence writer](persistence.md),
with metric-boundary flushes for denominator visibility and generation telemetry.

`generateDomainBaseline()` batch-generates the 100 frozen condition, drug,
procedure, visit, device, observation, death, specimen and density outputs, with
19 population/observation dependencies in the same repeatable-read transaction.
It reads all recorded concepts and history; there is no selected-concept loop or
chart-time CDM query. These are saved restricted aggregates, not a complete alpha
viewer. Measurement's 19 outputs and four metadata outputs remain explicitly
`not_requested / generator.not_implemented`. The building release cannot pass the
142-output sealing/publication gate. Nothing is marked policy-suppressed to stand
in for missing implementation.

## Generate once, select saved results

Initialize results/serving schemas with `initializeResultStore()` and provision
the worker as in the [population guide](population-baseline.md#setup-and-generation).
Add SELECT on all eight domain inputs, local CONCEPT identity/domain and
MEASUREMENT.person_id (density presence only). Optional CARE_SITE is read only
when accessible and unambiguous. The worker must have SELECT-only source access,
database TEMPORARY and restricted result writes, with no publication authority.
The result reader needs SELECT only on restricted results; it needs no CDM access.

```r
baseline <- generateDomainBaseline(
  workerDetails, cdmSchema = "cdm", sourceId = "institution-source",
  resultsSchema = "achillesnext_results", declaredCdmVersion = "5.5",
  maxStageBytes = 512 * 1024^2, statementTimeoutMs = 300000L)

page <- listDomainConcepts(
  resultsReadDetails, "achillesnext_results", baseline$release_id,
  domain = "condition", pageSize = 64L)
# NULL, zero and unknown IDs remain typed identities; ALL is not a catalogue item.
# Continue with cursor = page$next_cursor until it is NULL.

context <- readDomainBaseline(
  resultsReadDetails, "achillesnext_results", baseline$release_id,
  visit = function(metricId, row) print(row),
  metricIds = "core.condition.capture_count",
  conceptTag = list(kind = "all"),
  period = list(period_kind = "calendar_year",
                period_start = "2020-01-01", period_end = "2020-12-31"))
```

The reader validates the saved baseline once into a private temporary spool,
then replays exact validated rows without a second database traversal. Concept
paging queries a bounded indexed saved catalogue (up to 128 entries/page), and
cursors bind the release/content revision/profile/domain. They are positions, not
authentication tokens. All raw observed concepts are available, including those
that only occur on unlinked or undated rows. Empty domains have empty catalogues
and saved zero ALL capture totals. Calendar capture is precomputed for each raw
concept and ALL over canonical months/years spanning finite events and valid
observation intervals. Domain full-scope selectors have `"null"` boundaries, meaning all
recorded history; actual finite extent is separate telemetry, not a source release
identity. Undated capture is a separate NULL-date bucket. Invalid finite-range
source dates stay in full-scope/integrity/qualification counts and outside calendar
counts. Population observation outputs retain their observation-bound clipped
periods and clipped/full-calendar labels. Additional canonical coverage and
continuous-period rows support exact domain denominator scopes; coincident scopes
are deduplicated. The separate population window is returned as metadata.
Unsupported exact date ranges require generation; there is no dynamic
clinical query or percentile synthesis. Summaries and histograms are whole-scope.
Custom date-range generation and calendar-specific summaries are not implemented
in this slice; they need a separately declared batch capability. Explicit metric
selectors reject concept/date grains the selected metric does not store.

These APIs read **restricted building results**. They do not replace the approved
immutable provider or feed the installed v1 tracer viewer. The complete core
producer, metadata/projection and core UI path must be completed before approval
and general UI serving. Never give restricted result credentials to a browser.

## Populations, panels and exact values

For each domain the baseline saves physical records and linked distinct people,
source/standard concept pairs with source-text presence only, raw type, independent
integrity flags, first dated approximate year-age per linked person/concept,
frequency and distinct-concept histograms, observation-qualification categories,
observed concept/time counts and observed year/gender/approximate-age counts.
ALL people are counted independently; summing concept/month people is invalid.
Merged observation membership uses EXISTS, so overlapping intervals do not multiply
events. Vocabulary uses a canonical LEFT identity lookup; identical duplicate
concept entries cannot multiply rows. Conflicting domain identities fail.

Additional panels include condition status/type; drug recorded days supply,
refills and quantity; visit elapsed duration and four care-setting marginals;
procedure DATE/DATETIME precision; device quantity/raw unit; specimen quantity,
site/status and link presence; observation representation, raw unit/coded value,
qualifier, numeric eligibility and exact known-unit summary. Density uses nine
domain presence bits, including measurement, with no person/concept-pair cube.
No clinical/source strings, device identifiers or patient IDs enter result rows.

Counts and identities remain strings. NUMERIC/integer input values are preserved
as exact decimal strings; floating source types are rejected pending an explicit
precision adapter. Summaries use exact sum and rational mean plus empirical
`x[ceil(p*n)]` quantiles. The sample unit depends on the metric: recorded
scalar/numeric and visit-duration summaries use eligible physical records;
first-age summaries use one earliest dated age per linked PERSON/concept, by
gender. Frequency-weighted rank selection preserves multiplicity within each
metric's eligible sample, without weighting first ages by event frequency. Zero is eligible for nonnegative
scalars; negative, non-finite and missing values are separate exclusions.
Observation numeric summaries require a positive local Unit identity, preserve
negative numeric values, and never pool units. Allowed groups with no eligible
values have `n="0"` and NULL statistics. Age is descriptive year difference under
the frozen 0–130 policy, not inferred birthday or incidence.

## Actual schema capabilities and failure behavior

Actual columns determine support, independently of the declared CDM version.
Required missing/inaccessible/mistyped inputs fail and roll back generation; an
accessible empty table is distinct. For conditional fields:

- Procedure end precision is unsupported if either end column is absent. Available
  end-date integrity flags still run; absent fields are never queried.
- Device unit distribution is unsupported unless all three unit fields exist.
  Quantity still runs; it uses a typed schema-absent unit only when
  `unit_concept_id` is absent, otherwise retaining that column's NULL/zero/ID tag.
- Specimen visit-link presence is unsupported unless both link columns exist.
- Observation source/date representation bits independently use `X` for absent
  columns; supported combinations, including zero cells, remain explicit.
- Admission/discharge aliases are resolved from actual columns. Missing both or
  conflicting populated aliases fails instead of choosing silently.
- Missing/denied/duplicate-key CARE_SITE affects only place-of-service. Its rows
  have NULL values and unsupported/unavailable states; the other three marginals
  retain counts. A unique missing/null care link is the raw NULL concept tag.

The batch uses narrow private stages, merged-interval indexes and exact aggregate
stages. It avoids event × observation joins, person × concept expansion and
per-concept source queries. Calendar bucketing maps dates directly instead of
joining every event to every period. Denominator targets are joined into the
aggregate stream rather than fetched in per-cell queries; report stages have
metric indexes for repeated metric extraction. Stage byte limits are checked after stages;
they do not cap allocation/sort spill. Timeout, budget, schema failures and
cancellation roll back the entire new release. Source changes require a new batch
and release; existing saved results do not change. This is not a durable checkpoint
or verified source-reuse implementation. No large-CDM speedup is claimed.

## Verify

Install the current checkout, configure the marked fixture database and run:

```sh
proof_root="$(mktemp -d)"
python3 tools/test_domain_baseline.py \
  --config tools/tracer_fixture_config.R --output-dir "$proof_root/domain"
```

The test creates disposable synthetic physical schema variants for declared CDM
5.3/5.4/5.5, plus empty-domain and empty-source cases and an additional unobserved
5.5 case. An independent Python
set/Decimal/integer-rank oracle checks every domain/density output, cell states
and reasons, unavailable CARE_SITE marginals and all 19 population outputs,
including retained clipped scopes. Existing/in-checkout evidence paths are
rejected without overwriting their contents. Installed R
checks restricted saved reading, catalogue pagination, exact date/concept selection,
source-denied fresh-process readback, conditional capabilities, atomic failures,
backfill immutability and rejection by the full-profile gate. Routine CI uses the [compact calendar](ci.md) with the same report/edge coverage;
the wider fixture remains available locally or by manual dispatch. Synthetic capability
variants are not certification of every real CDM implementation or data scale.

An optional `--legacy` comparison requires installed Achilles 1.7.2 and SqlRender
1.19.0. Seven pinned template hashes in
`tests/fixtures/domain-legacy-lock.json` bind analyses 200/400/500/600/700/800/2100.
Their observed full-scope distinct-person counts are compared with saved domain
counts on the same fixtures, including overlapping observation periods. This
matched subset contains valid linked PERSON members for observed events; legacy
orphan-observation behavior is not a general parity claim. Legacy
record counts, interpolated distributions and all-recorded counts have different
semantics and are not parity targets. Specimen is checked against the independent
oracle; no equivalent legacy report is claimed. This optional comparison adds no
runtime dependency to AchillesNext and is separate from the default CI oracle.

Reader spools store only selected rows and are capped at 64 MiB by default
(`maxSpoolBytes`). Every saved dataset is still validated before emission.
A budget failure emits no rows and removes the temporary spool; operators can
explicitly raise the limit for larger approved local workloads.
