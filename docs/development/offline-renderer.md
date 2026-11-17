# Offline full-profile SQL compilation

`renderCharacterizationSql()` compiles the installed core profile into a
PostgreSQL SQL program: 138 numerical outputs and four runtime metadata outputs.
It loads no Java or DatabaseConnector namespace, makes no connection, and reads
no CDM data. PostgreSQL performs the eventual scans, joins, exact statistics,
calendar expansion and transaction-private materializations.

```r
library(AchillesNext)
# Institution-supplied column declaration: table,column,type,readable.
columns <- read.csv("omop-columns.csv", stringsAsFactors = FALSE)
program <- renderCharacterizationSql(
  cdmSchema = "cdm", sourceId = "institution-source",
  declaredCdmVersion = "5.5", sourceColumns = columns
)
length(program$outputs) # 142
jsonlite::write_json(program, "characterization-program.json",
                     auto_unbox = TRUE, pretty = TRUE, null = "null")
```

The declaration uses PostgreSQL base `typname` values, for example `int8`,
`numeric`, `date`, `text`, `varchar` and `timestamp`; `readable` is logical.
Include available optional columns and visit aliases. Extra unreferenced columns
do not affect compilation. Declared version alone cannot establish actual optional
fields or permissions. The compiler rejects missing required inputs, unreadable
required columns and inexact numeric types before producing a program.
The declaration covers referenced base types/readability, not type modifiers,
row counts or a verified source release. Actual schema identity belongs to
runtime observations, including type modifiers.

CDM 5.3/5.4/5.5 declarations are accepted. Optional procedure end, device unit,
observation date/source-value and specimen-link capabilities are resolved from
declared columns. Legacy and canonical visit aliases use the same checked
coalescing rule as the current producer. Other SQL dialects fail explicitly.

## What the program contains

| Field | Purpose |
|---|---|
| `batch`, `declarations`, `program_sha256` | Frozen profile/definition identities and canonical declared input/operator identity. No observed-source or reusable-snapshot claim. |
| `steps` | Ordered session settings, `assert_scalar` checks, temporary table/index creation, statistics and raw-stage cleanup. The source-declaration check precedes source materialization. |
| `inventory_sql`, `inventory_parameters` | Complete 142-output dataset states, reasons, row counts, conditional support and coverage. One runtime JSONB parameter supplies metadata row-count inputs. |
| `outputs` | One query descriptor per metric. Numerical queries return metric ID, row kind, dimensions, exact values, state and reason. Metadata descriptors explicitly require runtime facts. |
| `runtime_parameters` | Required actual observed schema hash, capability observations, generation timestamps and timing observations. These have no offline defaults. |
| `transaction`, `execution` | Repeatable-read, SELECT-only source and temporary-table requirements; not-executed state and unchanged publication. The separate executor enforces execution bounds; compilation does not. |

The full-profile renderer derives population bounds from valid observation intervals
and domain calendar bounds from intervals plus valid event dates, entirely in SQL.
Full-scope physical event counts include undated and unlinked rows. This API
does not accept a clipped calendar window: the frozen complete-core path uses
source-derived full history, matching the public core generator.
Measurement quantiles use exact `weighted` or `reference` SQL. The existing
population/domain/measurement SQL builders are shared with candidate generation.
Fixed-size inventory totals are materialized once; no patient/concept list is
enumerated in the R compiler.

## Execution boundary

This API remains a compiler. The [checked executor](checked-executor.md),
`executeCharacterizationSql()`, executes its current programs through bounded
staging callbacks and supplies actual runtime metadata. Existing
`generateCharacterizationCandidate()` and refresh APIs keep their current
orchestration; they share pure SQL builders but do not accept a compiled program.
Do not flatten the step list into an unchecked script or call it an approved
bundle. Execution and downstream consumption require:

1. Use one owned repeatable-read transaction and a fresh session/prefix. Execute
   every assertion, compare its scalar with `expected`, and roll back on failure.
   Checks cover repeatable-read isolation, PostgreSQL 12+ CTE syntax support,
   declared columns/base types/readability, source write privileges,
   PERSON identity, finite observation endpoints, local concept ambiguity and
   conflicting visit aliases. CARE_SITE ambiguity remains an unavailable state.
2. Enforce query/time, temporary-stage and aggregate row/byte limits, cancellation
   and bounded transfer. Rendering enforces none of those execution budgets.
3. Capture and validate actual runtime facts before binding metadata queries. The
   checked executor performs this binding from observations in its own snapshot.
   Each metadata query has one positional JDBC `?::jsonb` parameter named
   `runtime_facts`; the complete inventory uses the same parameter. Bind values
   through the driver, not textual SQL substitution.
4. Normalize exact numeric strings, build canonical row keys/denominator references,
   persist/validate the complete candidate and obtain explicit output approval
   before projection/export/promotion. Preserve the previous publication on failure.

Runtime facts have fields `observed_schema_sha256`, `capabilities`, `started_at`,
`ended_at` and `timings`. Capabilities map probe IDs to actual state/reason/type
observations. The schema hash is a lowercase SHA-256 string and generation dates
are ISO timestamps. Timings contain operation ID, phase and duration in whole
milliseconds as a canonical nonnegative integer string (or NULL when unavailable).
Elapsed duration is not engine CPU time; physical telemetry remains NULL when
unmeasured. Source/vocabulary releases remain unknown without
verified evidence; output integrity remains pending validation. Driver timestamps
and durations cannot be fabricated during SQL compilation. The four metadata
queries construct their outputs from these execution facts and computed dataset
states, rather than returning fixed example records.

The program yields restricted aggregate intermediates, not canonical 2.x wire
pages, serving grants or an interactive CDM provider. Saved-result viewing still
uses approved precomputed outputs, with zero CDM queries. Source/store separation,
disclosure and publication contracts are unchanged. Rendering is independent of
a local database, Docker or any particular external-engine hardware allocation.

## Validation

The core characterization fixture driver runs a fresh-process offline test and
compares compiled queries with the existing complete producer before denying
source access. Native proofs use prepared metadata parameters, both exact
operators and all 142 outputs; the existing independent numerical oracles and
native saved-result validation still run afterwards. Invalid/stale declarations
fail before materialization in the test driver. This does not certify large-source
performance, other engines, or browser/embedding memory.
Metadata comparisons reuse reference-run observations as identical parameter
inputs; they do not qualify the compiled test run's elapsed timings.
Native validation targets PostgreSQL 17.11; other server versions are not
qualified by these fixtures.
