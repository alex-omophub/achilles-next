# Synthetic saved-result walkthrough

This runnable contributor walkthrough exercises the native R providers used by
later views. It is an automated, maintainer-oriented API dry run with invented
data, zero human participants and no human completion-time measurement. It does
not establish clinical interpretation, production UI/ATLAS behavior or
representative-scale performance.

## Run from a checkout

Install the current R package as described in [conformance](conformance.md#match-the-implementation).
Run from the repository root; no PostgreSQL server, vocabulary connection, Node
runtime or private files are needed for this walkthrough.

```sh
export R_LIBS="$PWD/.local/R-library"
mkdir -p .local
# The output child must be new; existing directories are refused.
Rscript --vanilla tests/tracer/saved-walkthrough.R .local/saved-walkthrough
```

Without an output argument the same checks use temporary storage and remove it
on exit. With an argument, successful execution retains:

- `labelled/` and `legacy/`: small synthetic artifacts in formats 2.1.0 and 2.0.0.
- `report-filter-matrix.json`: all 142 installed report capabilities, including
  fixed populations, per-row-kind joint dimensions, concept/time/unit/operator
  support, period bounds and summary rules, with this fixture's saved states.
- `walkthrough.json`: ordered tasks, semantic requests, actual typed responses,
  interpretations, contexts, implementation hashes and connection-attempt count.
  Reader-local cursor tokens are redacted; continuation availability is retained.

The script checks installed implementation identity and completely admits both
artifacts before opening readers. Its exact-context authorization callback is
only synthetic host scaffolding. Production hosts must obtain approval and
authorization from their own institutional records; copying an artifact's context
is not approval. Constructed label provenance is synthetic fixture metadata, not
evidence of a vocabulary snapshot capture or shared aggregate/vocabulary snapshot.

After admission, the driver stubs `DatabaseConnector::connect` to reject and count
attempts. This is an API-level sentinel, not a process-wide network sandbox.
The driver uses the public semantic methods; it does not compute aggregates, join source
tables, reinterpret marginal reports or submit jobs. Catalogue discovery uses
bounded 25-entry pages. The complete matrix is a deliberate contributor export
assembled across those pages, not a download required for each interaction.
The fixture retains selected reports and suppresses the rest; a structurally
supported report does not promise saved rows for every stratum.
Joint dimension names describe selection shape, not every permitted value. The
installed dimension schemas and row-kind rules remain authoritative: for example,
numeric summaries require positive unit IDs and measurement numeric summaries
permit only NULL or zero raw operators. See [selection rules](saved-selection.md).

## Tasks and expected interpretation

| Task | Expected observation | Interpretation |
|---|---|---|
| Owner discovers reports and population | 142 capability entries; PERSON count 10 | Catalogue scope and capability are distinct; this is not an observed-only population |
| Researcher searches ` DEMO CONDITION ` | Saved name resolves to exact ID `123` | Declared ASCII case/space prefix matching, without a vocabulary fallback |
| Lookup exact IDs | Missing names, absent IDs and ID `9007199254740993` remain distinct | Keep IDs as strings; never substitute concept zero or a zero count |
| Select full-source condition capture, then January and February | Full scope 4 records/3 people; each month 2 records/2 people | Monthly distinct people are not additive; every result is already saved |
| Change to an absent March or an arbitrary date window | `not_saved` versus `additional_batch_job_required` | A missing row is not a measured zero; an unsaved window needs explicit operator work |
| Switch population or request condition by gender | `additional_batch_job_required`, generation requested FALSE | Choose another saved metric when available; do not derive joint strata from marginals |
| Select measurement units/operators | Saved unit strata stay separate; NULL operator differs from ID zero | Keep exact units and operators; no pooling or conversion |
| Inspect a saved summary | p50 `2.5`, exact mean pair `20.5/6`, matching eligibility evidence | No percentile recomputation, averaging of percentiles or float substitution |
| Ask for monthly percentiles | `additional_batch_job_required` | A full-scope summary cannot become a monthly one interactively |
| Inspect empty, omitted and unavailable results | Computed zero, empty population/source, suppressed output, missing row and schema absence | Preserve each state and its reason instead of displaying a common zero |
| Open original 2.0.0 terminology | `unavailable`, searched FALSE | A completed availability response is not an empty completed name search |
| Continue and change a selection | Same-request continuation succeeds; changed-filter cursor fails | Start a new selection after changing arguments or reader context |
| Cancel, exceed a response budget, lose authority or close | Classified errors, no successful page | Stop the interaction; no hidden generation or source query |

For an interactive inspection of this **generated fixture only**, open a new R
session from the checkout after the successful command above:

```r
run <- jsonlite::fromJSON(".local/saved-walkthrough/walkthrough.json", simplifyVector = FALSE)
trustedFixtureContext <- run$admitted_context
provider <- AchillesNext::openArtifactResultProvider(
  ".local/saved-walkthrough/labelled", trustedFixtureContext,
  function(context) identical(context, trustedFixtureContext)
)
provider$searchConcepts("Demo condition")
provider$selectSavedRows("core.condition.capture_count", filters = list(
  concept_tag = list(kind = "id", value = "123"),
  period_kind = "calendar_month", period_start = "2020-01-01", period_end = "2020-01-31"
))
provider$close()
```

Use [semantic results](semantic-results.md), [saved concepts](saved-concepts.md)
and [selection rules](saved-selection.md) for the complete method contracts.
The same semantics run through approved database serving credentials in the
existing [publication conformance suite](conformance.md), which separately checks
file/database parity, source/store access denial and live grant revocation.
This walkthrough itself exercises artifact mode only.

## Validation and qualification boundary

Full native admission owns inventory, reference/partition and numerical closure;
lazy reads own pinned context, bounded reachability/bytes and relevant evidence.
The independent structural and numerical oracles remain separate. See the
[validator boundary](validator-boundary.md). The walkthrough's fixed expected
values test interpretation; they do not replace those independent oracles.

The complete generated core profile, optional name/index extension and
[large-inventory experiment](inventory-proof.md) have separate conformance checks.
This tiny fixture does not measure million-patient generation, process-memory
ceilings, institutional latency or browser lifecycle. Production qualification
must declare its workload, environment, comparator and budgets before evaluation.
