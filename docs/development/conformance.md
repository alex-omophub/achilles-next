# Contributor conformance checks

Run from the repository root with the installed package and marked synthetic
PostgreSQL fixtures. The [CI guide](ci.md) records pinned dependencies and caches;
the [fixture guide](count-tracer.md#developer-setup) describes local provisioning.
These suites must not target clinical databases or reset an institution's CDM.

## Match the implementation

Install the checkout into a local R library using the existing dependencies.
Configure the pinned JDBC driver directory as described in the fixture guide.
No private planning files are required.

```sh
set -e
mkdir -p .local/R-library
R CMD INSTALL --library=.local/R-library .
export R_LIBS="$PWD/.local/R-library"
export ACHILLES_NEXT_FIXTURE_STATE="$PWD/.local/postgresql"
evidence_dir="$(mktemp -d)"

Rscript --vanilla tests/tracer/implementation-identity.R
Rscript --vanilla tests/tracer/native-validation.R .
python3 tools/check_schema_subset.py
Rscript --vanilla tests/tracer/analysis-definitions.R
Rscript --vanilla tests/tracer/source-store-offline.R
Rscript --vanilla tests/tracer/saved-transport.R
Rscript --vanilla tests/tracer/saved-provider.R
Rscript --vanilla tests/tracer/result-wire.R "$evidence_dir/v2-corpus.json"
node packages/contracts/tools/validate-v2-corpus.mjs "$evidence_dir/v2-corpus.json"
Rscript --vanilla tests/tracer/persistence-offline.R "$evidence_dir/v2-corpus.json"
```

Implementation identity compares actual installed function/SQL/definition content
with the checkout, including after caches warm. Matching version numbers alone
are insufficient. Reinstall after changing R, SQL or registered definitions, and
keep the implementation fixed while a suite runs.

## Compatibility and safety matrix

| Suite | What it checks |
|---|---|
| `tests/tracer/postgresql.R` / `observation.R` | Existing count/observation tracers, physical schema variants, invalid prerequisites and independent expected values |
| `tests/tracer/measurement.R` | Older bounded observed-window measurement profile, explicit unsupported outputs, exact values, eligibility order and resource limits; run both strategies |
| `tools/benchmark/weighted_quantiles.py` | Independent exact quantile vectors and native strategy parity; timing workloads require explicit selection |
| `tests/tracer/run-ledger.R` | Requested work, dependency closure, operation states and persisted execution evidence |
| `tests/tracer/publication.R` / `recovery.R` | Complete older fixture bundles, policy scopes, atomic promotion, cancellation, hard termination, source/definition changes and isolated retries |
| `tools/test_result_serving.py` | Complete synthetic core store fixture validation, projection/export, receipts, publication races and serving-only reads; not complete generation from a CDM |
| `tools/test_result_serving.py --test-script registered-profile` | Registered count profile through generation, persistence, validation, approval and source-denied reads, including rollback and seal/write races |
| `tools/test_population_baseline.py` / `test_domain_baseline.py` | Independent population/eight-domain oracles, schema availability, saved selection and incomplete-publication rejection |
| `tools/test_measurement_baseline.py` | Independent 138-output baseline oracle, measurement representations/ranges, exact strategy parity and source-denied saved selections |
| `tools/test_core_characterization.py` | Independent complete candidate expectations across numeric and metadata outputs, native validation and late metadata-budget rollback; `--with-publication` composes checked refreshes, full/reduced approval, exact export rows and serving-only page reads |
| `tools/test_synthetic_cdm.py` | Opt-in bounded CSV source generation/load over locked physical CDM DDL, selected independent counts/day sets/exact summaries and complete native candidate validation; no large-tier or full execution-comparator claim |
| `tools/test_characterization_refresh.py` | Checked full reruns, changed source/definition inputs, prior approved pointer/page preservation through readiness, precommit, validation and approval failures; serving-only pinned reads |
| `tools/test_refresh_operations.py` | Concurrent real refresh snapshots across committed ETL mutations, precommit backend termination, observed CAS lock contention and pinned reads after promotion |
| `tests/tracer/saved-selection.R` | Internal 142-report filter/grain matrix, bounded exact selectors, unsupported-job states without generation and cancellation; no source/store connection or provider read |
| `tests/tracer/saved-transport.R` | Internal root-reachable bounded scans, exact native pages, cursor/context/cache isolation, budgets and cancellation; routing fixtures simulate host admission |
| `tests/tracer/saved-provider.R` | Public native semantic discovery/selection, shared read/response budgets, summary/denominator evidence, typed missing/suppressed states and cursors; admitted fixture with DB connections disabled |
| `tests/tracer/saved-walkthrough.R` | Automated owner/researcher synthetic API tasks, 142-report filter matrix, exact saved months/units, explicit unavailable/job states and interaction errors; no human acceptance claim |
| `tests/tracer/saved-transport-integration.R` via `result-export.R` | Real approved artifact/database byte parity, serving-only SQL observation and audience-grant revocation |
| `tools/check_schema_subset.py` | Locked core metadata/dimension vocabulary audit for the finite native schema engine; not numerical or publication validation |
| `tools/benchmark/representation.py` | Opt-in local tree/flat routing experiment over identical saved pages; not run by these commands or CI; see the saved-representation guide |

See the [saved-representation experiment](../benchmark/saved-representation.md)
for its inputs, limits and reproducible command, and the
[validator boundary](validator-boundary.md) for admission versus lazy-read duties.
The [internal transport guide](saved-transports.md) records the native adapters,
resource ceilings, authority requirements and synchronous cancellation limits.

Older tracer and complete fixture workflows retain their own populations and wire
versions. Their success does not make the 138-output whole-source core release
complete: that entry point omits four metadata outputs. The separate
[complete candidate generator](core-characterization.md) supplies these outputs
and can be sealed and natively validated. The
[measurement guide](measurement-baseline.md) distinguishes these profiles.

Use a new output child for each compatibility command:

```sh
set -e
Rscript --vanilla tests/tracer/postgresql.R tools/tracer_fixture_config.R "$evidence_dir/count"
Rscript --vanilla tests/tracer/observation.R tools/tracer_fixture_config.R "$evidence_dir/observation"
Rscript --vanilla tests/tracer/measurement.R tools/tracer_fixture_config.R "$evidence_dir/measurement-reference"
ACHILLES_NEXT_TEST_NUMERIC_STRATEGY=weighted Rscript --vanilla tests/tracer/measurement.R tools/tracer_fixture_config.R "$evidence_dir/measurement-weighted"
python3 tools/benchmark/weighted_quantiles.py --config tools/tracer_fixture_config.R --output-dir "$evidence_dir/quantile-parity"
Rscript --vanilla tests/tracer/run-ledger.R tools/tracer_fixture_config.R "$evidence_dir/execution-ledger"
Rscript --vanilla tests/tracer/publication.R tools/tracer_fixture_config.R "$evidence_dir/publication"
Rscript --vanilla tests/tracer/recovery.R tools/tracer_fixture_config.R "$evidence_dir/recovery"
python3 tools/test_result_serving.py --state .local/postgresql --config tools/tracer_fixture_config.R --output-dir "$evidence_dir/core-publication"
python3 tools/test_result_serving.py --test-script registered-profile --state .local/postgresql --config tools/tracer_fixture_config.R --output-dir "$evidence_dir/registered-profile"
```

Run database suites serially: several temporarily grant fixture permissions or
check global cleanup counts. The serving harness creates a disposable reader
role; configure its administrator host/user options for your fixture setup. CI
supplies its synthetic administrator configuration. Keep credentials and raw
error diagnostics in restricted local storage.

Whole-source oracle commands and wider matrices are documented in the
[population](population-baseline.md), [domain](domain-baseline.md) and
[measurement](measurement-baseline.md) guides. Incomplete results fail rather
than being disguised as policy suppression.

## Check the saved views

With contributor npm dependencies installed, validate generated bundles before
enabling their provider/viewer tests:

```sh
set -e
for folder in count observation measurement-reference measurement-weighted; do
  for bundle in "$evidence_dir/$folder"/*; do
    node packages/contracts/tools/validate.mjs "$bundle"
  done
done
npm run check --prefix packages/contracts

export TRACER_TEST_BUNDLES="$evidence_dir/count"
export OBSERVATION_TEST_BUNDLES="$evidence_dir/observation"
export MEASUREMENT_TEST_BUNDLES="$evidence_dir/measurement-reference"
export WEIGHTED_TEST_BUNDLES="$evidence_dir/measurement-weighted"
export PUBLICATION_TEST_BUNDLES="$evidence_dir/publication"
export ACHILLES_NEXT_VIEWER_TEST_LIBRARY="$R_LIBS"
npm test --prefix packages/tracer
unset ACHILLES_NEXT_TEST_STATE
python3 -m unittest discover -s tests -p 'test_*.py'
```

Installed-viewer tests exercise loopback serving, nested base paths, verified saved
bytes and complete-scope bundles with Node/npm disabled inside the R viewer
process. Viewing needs neither Node nor Shiny; Node is a contributor dependency.
These checks do not render the whole-source core baseline in the older viewer.
Four fixture-provisioning/reset tests have a separate `ACHILLES_NEXT_TEST_STATE`
opt-in; the commands above leave it unset and do not reset canonical fixtures.

Build a source tarball and run `R CMD check --no-manual --no-vignettes` on it for
package metadata, syntax and help checks. This does not implicitly connect to
PostgreSQL. Retain exit codes and evidence for exactly the implementation tested.
Reuse recent oracle results only when their code/definition hashes match, and
rerun affected checks after a fix. Synthetic correctness does not establish
production-scale throughput, clinical validity or warehouse support.

## Compose complete refresh with approved publication

The existing complete-core matrix can also exercise the checked refresh executor
and reuse its first generated candidate through the approval/export/read path:

```sh
python3 tools/test_core_characterization.py --full-matrix --with-publication \
  --state .local/postgresql --config tools/tracer_fixture_config.R \
  --output-dir "$evidence_dir/core-publication"
```

Set the serving harness administrator options (`--admin-host`, `--admin-user`)
for your marked fixture environment. Supply a password file through `PGPASSFILE`
when required; there is no password-file CLI option. This mode requires `--state`;
it provisions and removes a disposable reader role. The ordinary command without
`--with-publication` retains its generator-only behavior.

All matrix cases use fresh checked full refreshes. Independent expectations still
check all 138 numerical outputs and four metadata outputs across populated physical
5.3/5.4/5.5 schemas and empty 5.5. Two approvals reuse the first populated
candidate: a full restricted export and a reduced distributable export. The latter
requests a report whose denominator is omitted and source-wide output-status
metadata; dependency closure removes both, leaving only person count and gender
counts. This is a synthetic policy test, not a generally approved disclosure rule.

An independent byte/tree walk compares every exported data row with the checked
generated rows and every catalogue entry with its projected state. Native artifact
validation checks the full directory. Record partitions reconcile per-concept
capture counts; the separate all-concepts capture total is not a partition
bucket. When present with unsuppressed evidence, that total must separately
equal the sum of per-concept record counts; distinct-person counts are not
additive. Rehashed artifacts with an altered partition count or all-concepts
record total must fail reconciliation. The database reader has no source or
aggregate-schema access, reads every approved object with exact export-byte parity,
and rejects source/scope mismatches. Revoking one audience blocks its database
reads while the other audience and existing offline copy remain usable. The
source-wide ledger and generation-time timing remain saved generation metadata;
publication does not rewrite them as measured downstream phases.

This exercises the v2 artifact and approved-page R reader. The v1 React tracer
viewer and experimental HTTP provider remain separate; this proof does not qualify
a whole-source UI, gateway, ATLAS host, warehouse or production-scale workload.

## Optional saved-label/index extension

For a small source-free discovery/filter run, use the
[saved-result walkthrough](saved-walkthrough.md):

```sh
Rscript --vanilla tests/tracer/saved-walkthrough.R "$evidence_dir/saved-walkthrough"
```

The output directory must be new. This writes the full report/filter matrix and
an interpreted API transcript after native admission. It runs once in the existing
compatibility CI suite without new jobs, dependencies or database generation.

The existing marked publication suite additionally captures synthetic local
vocabulary metadata, explicitly enables the store extension and publishes approved
artifact `2.1.0`. It verifies file/database ID and prefix-search parity, duplicate-name
count/byte continuations, exact stored/exported bytes, known/missing provenance,
scope-omitted names, grant revocation and previous-publication preservation on
cancellation, bad hash or denied approval. The store suite separately checks
transactional enablement and refusal to repair customized guards/missing markers.

`Rscript --vanilla tests/tracer/saved-labels.R "$evidence_dir/terminology-corpus.json"`
tests admitted source-denied fixtures, old `2.0.0` compatibility, mixed/corrupt/scope/
index rejection, matching, long Unicode keys/IDs, snapshot and SQL-buffer bounds.
`node packages/contracts/tools/validate-terminology-corpus.mjs "$evidence_dir/terminology-corpus.json"`
checks the shared structural vectors independently using existing contributor
dependencies. Node remains unnecessary for end-user admission/viewing. See the
[concept guide](saved-concepts.md) for format/matching/capture boundaries. These
are bounded synthetic proofs, not million-entry or representative-scale evidence.

## Matched reference comparator

The opt-in [full-profile matched reference comparator](../benchmark/matched-reference.md)
executes independent numerical SQL and the installed optimized generator against
one imported PostgreSQL snapshot, then checks all 142 outputs and complete
full/projected publications/exports on small fixtures. It adds no routine CI job
and does not qualify scale or comparative performance.
