# Synthetic measurement reference report

`generateMeasurementReport()` extends the count and observation tracers with the
seven measurement outputs in `alpha-measurement-v1`. It is restricted to the
marked synthetic PostgreSQL fixture database. It accepts CDM 5.3, 5.4 and 5.5
fixture schemas, 1–10 explicit measurement concepts and at most 120 touched
calendar months. It does not imply full clinical support for these CDM versions.

The bundle implements 12 of 15 outputs. `source.capabilities`,
`execution.output_status` and `execution.timing` remain unsupported. Publication
stays `partial`, current-pointer eligibility stays false, disclosure is unapplied
and durable source identity stays unknown. No performance improvement is claimed.

## Generate → validate → view

Install the package and create fixtures using the [fixture instructions](../../tests/fixtures/postgresql/README.md).
Use a trusted local configuration with the arguments documented in
`?generateMeasurementReport`; `tools/tracer_fixture_config.R` reads the synthetic
fixture connection without embedding passwords.

```r
library(AchillesNext)
# Run from the repository root after creating the marked fixtures.
source("tools/tracer_fixture_config.R")  # Trusted local fixture configuration
outputDir <- tempfile("measurement-reference-")  # New path for each run
do.call(generateMeasurementReport, c(config, list(outputDir = outputDir)))
```

Contributor validation requires Node and installed contract dependencies:

```sh
node packages/contracts/tools/validate.mjs /absolute/path/to/measurement-reference
```

Then, with AchillesNext installed:

```r
viewResults(outputDir)
```

The installed viewer needs no Node, npm, Shiny or external terminology service.
It uses the same verified file provider for folder selection and the R loopback
server, including nested base paths. React components accept verified aggregate
props without owning routing, authentication or database access. The future
host mount API remains a separate contract; this report does not certify a new
ATLAS integration.

## Definitions and reference implementation

- Source rows must belong to PERSON and fall inside the selected concept/date
  scope and the person's merged observation union. An `EXISTS` membership check
  avoids multiplying events across duplicate or overlapping observation periods.
  Physical duplicate measurement rows, including repeated IDs, are retained.
- Counts and distinct tested people are dense across selected concepts and the
  window plus every clipped month. Tested-person denominators resolve to observed
  people in the same period. Monthly distinct people are not additive.
- All eight numeric/coded/source-text flag combinations are emitted. Numeric
  presence includes non-finite values. Coded presence includes unknown nonzero
  IDs. Source text trims only U+0020 spaces; a tab is present text. It is not a
  standardized result and is not `measurement_source_value`.
- Unit and operator outputs retain separate NULL, 0 and nonzero raw tags,
  including unknown, negative or wrong-domain units. They are sparse observed
  strata; missing rows are not invented groups.
- Numeric gating uses the frozen first-match reasons: missing numeric, non-finite
  numeric, explicit nonzero operator, missing unit, unmapped unit, unknown/invalid
  unit, eligible. Equality is a nonzero operator and is excluded too.
- Summary groups use a locally named positive Unit-domain concept and raw operator
  NULL or 0, kept separate. Neither operator proves uncensored data. No conversions
  or clinical normal-range classifications are performed.
- The reference SQL groups equal values into restricted frequency inputs for
  exact `SUM(value × frequency)` and n, but independently sorts every eligible
  physical value for quantiles at `ceil(p × n)`. It does not use FLOAT casts or
  interpolation. Frequency inputs stay in the database CTE; no measurement rows,
  patient IDs or frequency table are exported. This is a correctness reference,
  not the optimized cumulative-frequency algorithm. An explicit [weighted strategy](weighted-quantiles.md) is also available without changing the metric definition.
- NUMERIC statistics and counts are strings. The mean is exact sum/n. Observed
  mapped-unit/allowed-operator groups with no eligible values retain n=0 and NULL
  statistics. No observed group means no fabricated summary.

Missing/denied prerequisites produce explicit unavailable/inaccessible states;
invalid source types, selected in-window orphan/null person IDs or conflicting
local terminology or missing labels for summary-eligible Unit-domain concepts produce failed measurement outputs with no numeric rows. The
valid count/observation results remain available. The reference step is atomic
across its seven metrics. It requires exact NUMERIC, integer IDs and DATE types;
FLOAT sources are rejected. PERSON and observation integrity are prerequisites.
The generator uses its own read-only repeatable-read JDBC transaction and no
source writes. Artifacts exceeding 10 MiB per file or 64 MiB total are refused;
narrow the request rather than truncating results.

The optional [weighted strategy](weighted-quantiles.md) reuses the same inputs and output semantics. The reference remains the default.

## Viewer behavior

The report selects only saved concepts and shows activity, representations,
raw units/operators, gating and separate numeric summaries. Recharts renders
monthly counts only when coordinates fit safe integers; exact tables remain
available. Numeric quantile landmarks and rational means stay exact text.

A scope availability form checks a concept, window and joint-filter request.
Ungenerated scope shows **additional computation required**, hides the saved
report for that requested context and offers a reset. No chart click issues a
query or silently substitutes all-source counts. Monthly numeric distributions
and arbitrary joint filters are not available.

Terminology comes only from local CONCEPT rows. Unresolved labels retain an
explicit unknown state. `vocabulary_release` uses `declared:<vocabulary_version>`
only for one nonblank local CDM_SOURCE declaration; absent, denied or ambiguous
metadata stays unknown. This is a declared identifier, not an immutable vocabulary
fingerprint or reusable source snapshot. All identity fields stay consistent
between the manifest, passport and terminology document.

## Reproduce integration checks

The fixtures must already exist; these commands do not reset or load source data.
The R suite creates and removes its own marked disposable schema for edge cases.

```sh
mkdir -p .local/R-library
R CMD INSTALL --library=.local/R-library .
export R_LIBS="$PWD/.local/R-library"
export ACHILLES_NEXT_FIXTURE_STATE="$PWD/.local/postgresql"
# Set DATABASECONNECTOR_JAR_FOLDER to the pinned PostgreSQL JDBC driver directory.
export MEASUREMENT_TEST_BUNDLES="$PWD/.local/measurement-integration"
Rscript --vanilla tests/tracer/measurement.R tools/tracer_fixture_config.R "$MEASUREMENT_TEST_BUNDLES"
for bundle in "$MEASUREMENT_TEST_BUNDLES"/*; do
  node packages/contracts/tools/validate.mjs "$bundle"
done
npm test --prefix packages/tracer
```

Use a new artifact directory for each R run. Count/observation integration inputs
have separate environment variables; enable them only after generating their
bundles. The CI workflow generates all three suites before provider tests.
The suite compares 15 handwritten source/version/window oracles and numeric edge
cases, including values above JavaScript's safe Number range, all representation
flags, raw tags, zero-n groups, observation boundaries and prerequisite failures.
Provider tests also reject rehashed semantic corruption, not only byte tampering.
