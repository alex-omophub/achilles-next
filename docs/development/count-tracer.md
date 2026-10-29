# PostgreSQL-to-React count tracer

This development slice computes `person.count` from marked synthetic PostgreSQL fixtures. Its R package is **AchillesNext**, in the **achilles-next** repository. It is an independent development project; upstream OHDSI Achilles references retain their original name.

The tracer implements the count and a source/passport seed. All 15 frozen output partitions are declared, with the other 13 explicitly `unsupported`. The manifest is `partial`, cannot become the current complete bundle, and applies no disclosure policy. The [installed local viewer](../viewing/local-viewer.md) opens these results without a frontend build. There is no production analysis runner, complete alpha report, safe-publication/recovery implementation or institutional result service yet. React displays the exact count as a string; a chart library is unnecessary for this single value. Recharts remains the planned report chart library.

## Developer setup

Use the [PostgreSQL fixture guide](../../tests/fixtures/postgresql/README.md) to prepare the isolated local sandbox. Existing fixtures do not need a reset. The tracer accepts only the marked `achilles_next_fixtures` database and marked `cdm_tiny_*_53/54/55` schemas. It refuses other sources before reading PERSON. CDM version recognition here is not full clinical support.

Requirements: R 4.2+, DatabaseConnector 6.3.2+, jsonlite, digest, httpuv, Java and a PostgreSQL JDBC driver. Contributor building/testing uses Node 22.12+ and npm; the tested reference tuple is in [runtime-lock.json](../../tests/tracer/runtime-lock.json). This is a synthetic test tuple, not a production driver recommendation. [DatabaseConnector's connection documentation](https://ohdsi.github.io/DatabaseConnector/articles/Connecting.html) describes driver and connection configuration.

```sh
npm ci --prefix packages/contracts --ignore-scripts --no-audit --no-fund
npm ci --prefix packages/tracer --ignore-scripts --no-audit --no-fund
```

The supplied [fixture configuration](../../tools/tracer_fixture_config.R) reads the generated private fixture credentials without embedding or printing them. Set `ACHILLES_NEXT_FIXTURE_STATE` if your fixture state is outside the default `.local/postgresql`. Set `DATABASECONNECTOR_JAR_FOLDER` to your installed driver directory. Configuration files are trusted local R code; never put passwords or copied local configurations into Git or generated bundles.

From the repository root, this command installs the R package into a temporary library, computes the count, validates the complete file set, builds React and starts the loopback developer server:

```sh
python3 tools/run_count_tracer.py \
  --config tools/tracer_fixture_config.R \
  --output .local/count-bundle \
  --serve
```

The output parent must already exist and the bundle directory must be new. Existing files, directories and symbolic links are refused. Open the printed local URL and choose `count-bundle` using **Choose bundle folder**. Only the declared aggregate files are read into browser memory; they are not uploaded to the developer server. The file provider verifies hashes, source/run/request identity, frozen schemas and the count-tracer semantics before rendering. A failed load clears the previous result and shows an error, never zero. Choose another bundle to replace the source. For automatic Generation → View after installation, use `AchillesNext::viewResults(".local/count-bundle")`; the developer server and folder picker are unnecessary.

To call the R API directly:

```r
library(AchillesNext)
environment <- new.env()
sys.source("tools/tracer_fixture_config.R", environment)
do.call(generateCountTracer, c(environment$config,
                              list(outputDir = ".local/another-count-bundle")))
```

The function checks unique, non-null person IDs inside a read-only repeatable-read transaction. SQL returns counts as text, including values beyond JavaScript's safe integer range. Null/duplicate IDs or inaccessible PERSON abort generation without producing a numeric success. An accessible empty PERSON produces exact `"0"` with `empty_source`. Snapshot/data/vocabulary/schema identities not established by this slice stay unknown; run-time consistency does not establish durable identity for reuse. No raw person IDs, connection details or credentials are written to the bundle.

## Reusable view and provider

[CountView](../../packages/tracer/src/CountView.tsx) takes a verified count result, with no router, login or file-picker ownership. The installed shell automatically opens the R-selected bundle; the standalone development shell supplies folder selection. [The local-file provider](../../packages/tracer/src/file-provider.ts) implements the [ResultProvider contract](../contracts/v1.md), returns immutable byte copies, checks context/manifest identity and cancellation, and reads only declared selected files. It supports the partial count tracer only; its schema/semantic checks are not a general full-profile viewer validator. Inputs are limited to 10 MiB per file and 64 MiB per declared bundle.

The common framework-neutral mount/update/destroy API, multi-instance DOM isolation, real host identity lifecycle and ATLAS3 integration are later work. Local file selection grants no institutional authorization and makes no disclosure approval assertion.

## Verification

```sh
R CMD INSTALL --library=.local/R-library .
R_LIBS=.local/R-library Rscript tests/tracer/postgresql.R \
  tools/tracer_fixture_config.R .local/tracer-integration
```

Create `.local/R-library` first. The integration artifact parent must be new. This command reads tiny A/B for 5.3/5.4/5.5, expects independent counts 4/2, tests exact JDBC text, and creates/removes one test-owned marked schema for empty, duplicate/null and denied-access cases. Canonical tiny fixtures, GiBleed, SynPUF and existing results are untouched.

```sh
for bundle in .local/tracer-integration/*; do
  node packages/contracts/tools/validate.mjs "$bundle"
done
TRACER_TEST_BUNDLES="$PWD/.local/tracer-integration" npm run check --prefix packages/tracer
npm run check --prefix packages/contracts
```

React/provider tests verify actual generated source/version counts, exact large strings, empty versus unavailable states, tampering, missing files, false complete pointers, source substitution and cancellation. Without `TRACER_TEST_BUNDLES`, real-R provider tests are explicitly skipped. Set `ACHILLES_NEXT_VIEWER_TEST_LIBRARY` as well to run the installed-viewer HTTP boundary tests described in the local-viewer guide. The [CI workflow](../../.github/workflows/count-tracer.yml) provisions the pinned server/client in an ephemeral job and runs this real-query path; adding the workflow does not itself establish a successful remote CI run.
