# Semantic access to approved saved results

`openArtifactResultProvider()` and `openDatabaseResultProvider()` expose the same
experimental native R interface over admitted, approved v2 results. Both provide
`listMetrics()`, `selectSavedRows()`, `lookupConcepts()`, `searchConcepts()`,
`inspect()` and idempotent `close()` methods.
Consumers select metric IDs and typed dimensions; they do not construct filenames,
page descriptors, encoded index keys or SQL. Database reads use only the approved
serving view; artifact reads need no database credentials or connection.

This is a native provider foundation for later standalone/embedded views. It does
not add a browser/HTTP transport, a whole-domain viewer or
representative-scale qualification. Existing v1 tracers/viewer remain separate.

## Host setup and authority

The host supplies the complete trusted context and mandatory approval/authorization
callback documented in the [transport guide](saved-transports.md#authority-and-pins).
The complete release must have passed admission and institutional policy before
that callback approves it. A hash, self-declared ready flag or arbitrary artifact
is not an approval credential. Constructors do not auto-admit publication.json.

```r
# trustedContext and institutionalAuthorizer come from host-owned approval records.
provider <- AchillesNext::openArtifactResultProvider(
  bundleDir = approvedDirectory,
  context = trustedContext,
  authorize = institutionalAuthorizer
)

metrics <- provider$listMetrics(limit = 10L)
summary <- provider$selectSavedRows(
  "core.measurement.numeric_summary",
  filters = list(
    concept_tag = list(kind = "id", value = "123"),
    unit_concept_tag = list(kind = "id", value = "456"),
    raw_operator_tag = list(kind = "null")
  )
)
provider$close()
```

For database mode, use `openDatabaseResultProvider(servingConnectionDetails,
servingSchema, trustedContext, institutionalAuthorizer)`. These are serving-principal
credentials, supplied separately from context; there is no source connection or
restricted-result schema in semantic method requests. The host adopts a new
provider/context for source, publication or access-epoch changes. It never follows
current during pagination. Institution-managed artifact permissions and database
audience grants remain separate; revoking a DB grant cannot recall an exported copy.

## Metric discovery

`listMetrics(limit = 25L, cursor = NULL, maxBytes = 1048576L, cancel = function() FALSE)`
returns approved catalogue entries augmented with definition-driven capabilities:
metric/version, population, grain, supported row kinds, jointly saved dimensions,
period materializations, unit/operator and summary rules. The catalogue's state,
reason and exact row-count string describe this publication's scope. Structural
capability does not promise that a particular stratum exists.

Each response has `state`, `reason_code`, pinned `context`, `metrics`, `cursor`,
`complete`, `generation_requested = FALSE` and read `budget` counters. Limit is at
most 100 entries. Catalogue pagination resumes after the last metric identity,
including when the boundary is inside a physical page. It does not download the
whole catalogue to serve every request.

## Exact saved-row selection

`selectSavedRows(metricId, filters = list(), rowKind = NULL, population = NULL,
maxRows = 100L, maxBytes = 1048576L, cursor = NULL, cancel = function() FALSE)`
checks the installed [saved-filter model](saved-selection.md), then the approved
catalogue and actual saved rows. Default row kind is `summary` when declared by
the metric; otherwise it is the first declared kind. Explicit `eligibility_counts`
requests select eligibility rows. Unknown metrics or malformed selectors fail.

Selectors are up to 16 exact strings or typed tags. NULL, zero, schema absence,
all and signed/large IDs stay distinct. Complete saved periods are equality
filters, not arbitrary date-window computations. A fixed-population switch,
unsaved joint grain or monthly restriction on a whole-scope summary returns an
explicit additional-job state. Nothing submits that job or replaces a publication.

Only rows matching the requested kind and all selectors are returned. Leading
saved dimensions narrow index traversal; remaining selectors are checked within
verified partitions. No units, operators, marginal populations or periods are
pooled. Counts, decimal strings, `(sum,n)` means and saved percentiles are preserved
exactly; the provider performs no analytical reaggregation or percentile arithmetic.

| Response state | Meaning |
|---|---|
| `available` | Verified saved rows, with their original computed/empty/suppressed/unavailable states, values and reasons |
| `not_saved` | Traversal of the bounded requested range completed with no matching saved row; no zero is manufactured |
| `suppressed` | The approved catalogue omits this output; no data rows or dependencies are returned |
| `unsupported` | The approved catalogue marks the output unsupported; reason retained, no zero substituted |
| `additional_batch_job_required` | Population, row kind, joint dimensions or period materialization is not saved; `generation_requested` is FALSE |

Response `dataset` preserves the approved catalogue entry, and `capability` describes
structural support. `selection` records normalized semantic arguments. `rows` contain
the original typed rows; `dependencies` contain metric/version and related verified
rows. No physical page/path/index key is returned. Context is pinned provenance,
including instance/authorization epoch; it contains no credentials or SQL.

### Denominators and summary eligibility

Declared denominator keys are derived from installed analysis bindings, including
exact dimensions and full-scope defaults. Returned reference row identities,
measure values and populations must match the verified target row. Native exact
numerator/denominator checks are reused; dependency chains stay in the same scope.
The provider does not search every row for an opaque hash or consult CDM facts.

Summary rows include matching eligible-count evidence with exactly the same
concept/unit/operator dimensions and included n. An eligible-count selection also
checks its saved summary, preserving suppression where the admitted contract
allows it. Related rows are de-duplicated, checked once and returned separately.
Missing, wrong-identity, suppressed-required or inconsistent evidence fails the
operation; it is not presented as a zero or an estimated ratio.

## Saved concepts and name-search availability

`lookupConcepts(conceptIds, limit = 25L, cursor = NULL, maxBytes = 1048576L,
cancel = function() FALSE)` resolves a bounded set of exact IDs from the approved
saved concept catalogue. `searchConcepts()` reports name-search availability.
See the [concept guide](saved-concepts.md) for states, exact-ID normalization,
pagination, provenance and optional approved saved-name search in artifact format 2.1.0.
Neither method reads a live vocabulary or CDM.

## Budgets, pagination and cancellation

All catalogue, concept, row and dependency reads share **one operation budget**: defaults
64 distinct verified objects, 8 MiB of distinct verified bytes and 8,192 distinct
verified leaf rows, including raw-cache hits.
The [transport ceilings](saved-transports.md#verification-and-traversal) still apply.
A bounded per-operation memo reuses already verified decoded pages; it is discarded
at return/error. Across operations, file raw caching stays bounded and database
raw caching stays disabled. Each physical DB fetch rechecks its serving grant;
host authority/cancellation checks also run on memo and raw-cache reuse.

A selection returns at most 1,000 primary rows; the complete serialized response,
including dependencies, context, cursor and counters, must fit the requested byte
budget (default 1 MiB, hard 8 MiB). Row selection, metric discovery and concept lookup shorten the
page at a byte boundary and return a continuation cursor. The selected rows keep
all required evidence, and evidence belonging only to deferred rows is omitted.
A single result unit plus its required envelope/evidence/continuation that cannot
fit still raises `resource_limit`. The final serialized response is checked exactly.
Dependency expansion remains bounded by the shared read budget and at most 3,000
distinct primary/dependency rows. Raw cache/read
limits do not constitute a whole-process R/JVM memory guarantee.

Opaque HMAC cursors bind method, normalized selection, limits, complete context,
instance, epoch and generation, plus the last unique semantic row/metric key.
Reuse the same method arguments and returned cursor; callers never construct its
contents. Row pagination works inside a partition and verifies all row dependencies
before returning a page. Concept lookup cursors resume after the last requested
ID, including a `not_saved` result. Cursors are not permissions or source-identity evidence.

Sparse non-leading filters can exhaust the read budget before absence or the next
match is established. That raises `resource_limit` without partial success or a
false `not_saved`. Narrow leading selectors or explicitly adjust bounded read
controls; no source query or new batch is invoked automatically.

Cancellation is a boolean predicate checked throughout row/dependency traversal
and before return. It is cooperative under synchronous R/JDBC; immediate in-flight
statement interruption is not claimed. Errors clear raw caches/invalidate cursors;
closed or stale operations cannot return late rows. Call `close()` when finished.

## Verified scope

The runnable [saved-result walkthrough](saved-walkthrough.md) combines owner and
researcher tasks, produces the complete 142-report filter matrix and records
typed outcomes with all database connections denied. It is an automated synthetic
API dry run; participant and production UI evaluation remain separate.

The self-contained contributor fixture passes native full artifact admission,
then disables all database connections while testing saved-ID lookup and 142-metric discovery,
within-page pagination, summaries/eligibility, recursive denominators, typed
states, corruption, budgets, cursor isolation and cancellation. Rehashed negative
fixtures are deliberately not certified publications. Installed count-extension
capabilities are also checked; that is not certification of arbitrary modules.

The existing marked PostgreSQL publication test compares serialized semantic
responses in both modes, using independent cursors and excluding diagnostic
counters. It exercises real approved full catalogue entries, summaries, empty and
unavailable states, dependencies and live grant revocation with source/store
access denied. See [conformance](conformance.md). Opt-in saved-name indexes have their own versioned capture/projection/admission checks.
The [large-inventory experiment](inventory-proof.md) separately exercises bounded
saved access and isolation. Browser/ATLAS lifecycle and representative production
qualification remain later gates.
