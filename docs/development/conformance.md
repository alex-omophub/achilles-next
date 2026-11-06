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
Rscript --vanilla tests/tracer/analysis-definitions.R
Rscript --vanilla tests/tracer/source-store-offline.R
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
| `tools/test_core_characterization.py` | Independent complete candidate expectations across numeric and metadata outputs, native source-denied validation and late metadata-budget rollback |
| `tools/test_characterization_refresh.py` | Checked full reruns, changed source/definition inputs, prior approved pointer/page preservation through readiness, precommit, validation and approval failures; serving-only pinned reads |
| `tools/test_refresh_operations.py` | Concurrent real refresh snapshots across committed ETL mutations, precommit backend termination, observed CAS lock contention and pinned reads after promotion |

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
