# Saved concept lookup and name-search availability

The experimental [native providers](semantic-results.md) expose exact saved-ID
lookup in artifact and PostgreSQL modes. All reads use approved immutable pages.
The existing physical contract `2.0.0` saves IDs with `label = NULL` and
`label_state = "unavailable"`; it contains no approved names or name-search index.
The provider reports this limitation explicitly. It never queries a live CDM or
vocabulary, interprets an ID as a name, or searches an entire catalogue as a fallback.

```r
concepts <- provider$lookupConcepts(c("123", "9007199254740993"), limit = 1L)
nextConcepts <- provider$lookupConcepts(
  c("123", "9007199254740993"), limit = 1L, cursor = concepts$cursor
)
names <- provider$searchConcepts("Diabetes")
# names$state == "unavailable"; names$searched == FALSE
```

## Exact IDs and pagination

`lookupConcepts(conceptIds, limit = 25L, cursor = NULL, maxBytes = 1048576L,
cancel = function() FALSE)` accepts an R character vector of 1–100 unique canonical
signed integer strings. Each ID has at most 512 digits, excluding the minus sign.
Zero, negative and arbitrarily precise large IDs remain exact. Leading zeros,
`-0`, plus signs, whitespace, NULL/all/schema-absence tags and numeric vectors
are rejected. IDs are sorted in signed numeric order without floating-point
conversion. Reordering the same request set is equivalent; changing its contents,
limit or byte budget invalidates a continuation.

The returned `concepts` preserve `concept_tag`, `label` and `label_state`, plus:

| Entry state | Meaning |
|---|---|
| `available` | ID is present in the approved saved concept catalogue; its label remains unavailable |
| `not_saved`, reason `concept.not_saved` | ID is absent from that saved catalogue; no claim about its existence in a live vocabulary or the source CDM |

The response's `state = "available"` means the requested lookup page succeeded;
individual entries can be `not_saved`. This never establishes that an ID has data
in a particular metric. Select that metric's saved rows separately. No missing
ID is converted into concept zero, an unknown-concept label or a count of zero.

The limit is 1–100 entries per page. Each requested ID routes to an exact saved
index range. Entries, pinned context, terminology availability, continuation and
read counters all fit the complete response byte budget: default 1 MiB, hard
8 MiB. Pagination resumes after the last returned **requested** ID, including
missing IDs. An indivisible entry/envelope/continuation that cannot fit raises
`resource_limit`. All IDs share one operation budget; a widely scattered request
can exhaust it. No partial success or false absence is returned in that case.

## Explicit name-search absence

`searchConcepts(query, limit = 25L, cursor = NULL, maxBytes = 1048576L,
cancel = function() FALSE)` currently returns:

```json
{
  "state": "unavailable",
  "reason_code": "terminology.name_index_not_saved",
  "searched": false,
  "concepts": [],
  "complete": true,
  "cursor": null,
  "generation_requested": false
}
```

The actual response also includes pinned context, terminology availability, the
unchanged query and read counters. `complete` describes this availability response;
it does **not** mean a name search completed with zero matches. Consumers must
check `state`/`searched` before rendering search results. No valid continuation
exists; every non-NULL search cursor is rejected. Limit is validated at 1–100
for a consistent bounded request surface, but no matching is performed.

Queries must be nonblank valid UTF-8 strings of at most 256 bytes without control
characters. They retain their exact bytes: no case folding, trimming, stemming,
transliteration, fuzzy matching or wildcard interpretation is implied. Query
text never enters SQL. Available name search requires a separately versioned,
approved saved-label/index format with defined matching and migration behavior.
Adding names to original v2 pages is rejected by native admission and the reader.

Both methods return `terminology` with explicit unavailable `label_source` and
`vocabulary_release` states and reasons. These mean the **terminology contract**
does not supply those identities. They do not overwrite any separately saved
source-passport evidence. The dataset's pinned `source_id` stays in `context`;
it is not evidence of a particular vocabulary release or label provenance.

Name availability checks read only the approved pinned root, so live database
grant revocation still takes effect. They do not traverse concept, metric or data
pages. File reads can reuse the bounded verified raw cache while checking host
authority. Both methods use the same context/epoch isolation, cancellation,
cache invalidation, lifecycle and source-denied adapters as saved-row selection.

## Contributor checks

Run `Rscript --vanilla tests/tracer/saved-concepts.R` after installing the package.
It fully admits independent fixtures before denying every database connection,
then tests signed/large IDs, count/byte continuations, absent labels, old empty
concept trees, wrong cursors, budgets, cancellation and late close. A multi-level
301-added-ID fixture verifies selective lookup without a whole-catalogue scan.
An unversioned rehashed name fails admission and selective reading. The existing
marked PostgreSQL publication suite checks real artifact/database lookup parity,
unavailable-name behavior, serving-view-only SQL and live grant revocation.

This establishes bounded exact lookup and truthful search availability. Saved
labels/name matching, million-entry search and production UI remain unimplemented.
