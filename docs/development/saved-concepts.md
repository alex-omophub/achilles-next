# Saved concepts and approved name search

The experimental [native providers](semantic-results.md) expose exact saved-ID
lookup in both artifact and PostgreSQL modes. Optional artifact format **2.1.0**
adds approved saved names, provenance and a separate prefix-search index. Original
**2.0.0** exports retain their closed unavailable-label behavior. No provider
method queries a live vocabulary or CDM, or downloads the whole catalogue.

## Prepare labels once, then view saved results

Capture is explicit batch work using separate vocabulary-read credentials. The
snapshot contains only local `concept` reference metadata. It is restricted input,
not an approved export: it can contain IDs omitted from an audience's final scope.

```r
# Both identities have state, value, basis, assertion_id and reason_code.
# Supply honest known assertions or explicit unknown states; do not invent a release.
snapshot <- AchillesNext::captureConceptSnapshot(
  vocabularyReadDetails, "vocabulary", restrictedSnapshotFile,
  sourceId = sourceId, releaseId = candidateReleaseId,
  labelSource = labelSourceIdentity, vocabularyRelease = vocabularyIdentity
)

# Explicit store-owner operation, once per existing/new base store.
AchillesNext::enableSavedTerminology(storeOwnerDetails, "results")

published <- AchillesNext::publishResultRelease(
  storeOwnerDetails, "results", candidateReleaseId, approvedExportDirectory,
  audienceId, approvalId, policy, institutionalPolicy,
  savedTerminology = snapshot
)
# Omit savedTerminology to continue publishing original 2.0.0 artifacts.
```

Capture uses a read-only repeatable-read transaction, bounded JDBC fetches and
bounded canonical JSONL records. Duplicate IDs fail; NULL/ASCII-space-only names
are explicitly unavailable. Display labels are preserved, limited to 1,024 UTF-8
bytes without control characters. Domain/vocabulary IDs are nullable, at most
128 UTF-8 bytes. The output file must be new; failed/cancelled capture removes its
owned temporary output. The default capture statement timeout is 900 seconds and
can be set explicitly. R/JDBC cancellation is cooperative.

The snapshot's exact source/release IDs and SHA-256 are checked during publication.
Publication parses a hash-verified private copy with 8 KiB line bounds and checks
ordered, unique exact IDs. PostgreSQL temporary tables sort and join saved labels
to retained non-suppressed concept IDs with bounded insert buffers; no source
connection or live vocabulary query is involved. Unrelated or scope-omitted names
never reach approved pages. Missing snapshot IDs and missing names stay distinct.

Source/release binding does **not** prove capture occurred with the aggregate
snapshot. Metadata declares `within_capture = single_repeatable_read` and
`with_aggregate_release = not_asserted`. Known label-source/vocabulary identities
are operator assertions with evidence; unknown states are retained. When both a
saved source passport and terminology assert known vocabulary releases, their
values must agree. A conflicting known release fails publication/admission.
Names never rewrite concept IDs or numerical definitions.

The approval candidate includes the new contract version and saved-terminology
metadata; the exact root hash covers the index, labels, provenance and policy.
Native admission validates complete ID/name equivalence and retained scope before
institutional approval. Existing atomic publication/failure-preservation rules
apply. A failed capture, bad hash/context, denied policy, cancellation or failed
publication cannot replace the previous publication. Refresh orchestration does
not automatically capture/attach labels; configure this explicit publication path.

## Enablement and compatibility

`enableSavedTerminology()` requires store-owner privileges and a recognized base
store `2.0.0`. It locks before reading store state and uses read-committed
transactions so concurrent first calls yield one installation and one no-op.
It verifies the exact installed publication guard and its enabled, unconditional,
row-level BEFORE INSERT/UPDATE trigger binding while holding a publication-table
lock against trigger DDL. It adds `saved-terminology/1.0.0` capability and allows
physical roots `2.0.0`/`2.1.0`.
Repeated enablement is a no-op only when marker and definition agree; modified
functions/markers are refused without repair. The base storage version stays
`2.0.0`; `inspectResultStore()` still describes that base compatibility only.

Enablement leaves existing exports, releases and current pointers unchanged.
Publication creates a new approved export/release projection; it can advance the
current pointer through compare-and-swap when `expectedRevision` is supplied.
Old exports remain readable unchanged; publishing with names requires new
approval. Older consumers reject unsupported `2.1.0`; this is not an in-place
artifact upgrade. All pages in a publication must share its version/context.

## Exact ID lookup

```r
page <- provider$lookupConcepts(c("123", "9007199254740993"), limit = 1L)
nextPage <- provider$lookupConcepts(
  c("123", "9007199254740993"), limit = 1L, cursor = page$cursor
)
```

`lookupConcepts(conceptIds, limit = 25L, cursor = NULL, maxBytes = 1048576L,
cancel = function() FALSE)` accepts 1–100 unique canonical signed integer strings,
with at most 512 digits excluding the minus sign. Numeric vectors, leading zeros,
`-0`, plus signs, whitespace and NULL/all/schema-absence tags are rejected.
Zero, negative and very large IDs retain exact values and sort in signed numeric
order. Reordering the same request set is equivalent; changing its members, limits
or byte budget invalidates the continuation. Each ID routes to an exact index range.

| Entry state | Meaning |
|---|---|
| `available` | Present in this approved saved catalogue; no promise of a particular metric's data |
| `not_saved`, `concept.not_saved` | Absent from this saved catalogue; no claim about its existence in a live vocabulary or CDM |

Top-level `available` means the lookup page succeeded, independently of each
entry's state. Labels remain NULL/unavailable in `2.0.0`. In `2.1.0`, entries
preserve label/domain/vocabulary metadata and `label_reason_code`:
`terminology.missing_label` for a snapshot row without a name, or
`terminology.id_not_in_snapshot` for a retained ID absent from the snapshot.
A missing ID is never converted into concept zero or a count of zero.

## Name search and matching

```r
page <- provider$searchConcepts("Diab", limit = 20L)
# Inspect state/searched before rendering results.
```

`searchConcepts(query, limit = 25L, cursor = NULL, maxBytes = 1048576L,
cancel = function() FALSE)` accepts a nonblank valid UTF-8 query of at most 256
bytes without control characters. Physical `2.1.0` uses **ascii-fold-prefix-v1**:

- Trim leading/trailing ASCII spaces (U+0020) and fold ASCII A–Z to a–z.
- Preserve all other Unicode scalars. There is no Unicode case folding, canonical
  normalization, transliteration, stemming, substring/fuzzy or synonym matching.
- Match the start of a normalized saved display name. `%`, `_`, quotes and other
  characters are literal text; they never enter SQL.
- Sort by normalized UTF-8 bytes, then exact signed concept ID. Duplicate display
  names retain separate IDs. Preserve original display names in responses.

Thus `DIAB` and ` diab ` are equivalent prefixes. `é` and `É`, and composed and
combining-accent spellings, remain different. These are declared matching limits,
not international case-insensitive search. Responses include original `query`,
`normalized_query`, matching version, pinned context and terminology provenance.

An available search has `searched = TRUE`, including a completed empty result.
Only available labels enter the index; missing labels remain discoverable by ID.
Each returned name is checked against its exact saved ID entry under the same
operation budget. In original `2.0.0`, search reads only the approved pinned root
and returns `unavailable`, reason `terminology.name_index_not_saved`,
`searched = FALSE`, no concepts/cursor and no generation. Its `complete` flag
completes the availability response, not an empty name search. A non-NULL search
cursor is invalid on that format. No live fallback or ID-as-name search is used.

## Bounds and provenance

Lookup and search return at most 100 entries, default 25, and obey the complete
response budget: default 1 MiB, hard 8 MiB, including context, metadata, counters
and continuation. Count/byte pagination resumes after the last returned requested
ID or normalized-name/ID key. Cursors bind normalized request, matching version,
limits, full publication/context/epoch/instance and reader generation. No numeric
offsets, current-pointer following or whole-name-map allocation is used.

A single entry/envelope/continuation that cannot fit raises `resource_limit`.
Catalogue, name-index and ID verification reads share the same default
64-object/8 MiB/8,192-leaf-row operation budget. Large/scattered requests can exhaust
it even before the response limit; exhaustion is not reported as absence or
partial success. Explicit read-budget overrides retain the existing hard ceilings.

File caching remains bounded and checks host authority on reuse. Database caching
stays disabled; each fetch rechecks the approved serving view. Cancellation,
revocation, context isolation and idempotent close apply to both methods. Already
exported approved files remain independently governed by institution permissions.
The dataset source_id is distinct from label provenance and vocabulary identity;
metadata does not overwrite separate source-passport evidence or prove reusable
source consistency.

## Physical and validation boundary

The [2.1 terminology schema](../../inst/contracts/v2.1/terminology.schema.json)
provides an integrity-locked independent structural oracle. Root `saved_terminology`
holds extension/matching version, source/vocabulary identities, snapshot hash and
capture consistency. Both concept/name leaves use the same closed six-field
entry. Concepts sort by existing signed-ID codec; only available entries appear
in the name branch. Name keys are `T:` + lowercase hex(normalized UTF-8) + `!` +
signed-ID codec. The terminator sorts before hex digits, so exact names precede
longer names sharing their prefix. Selective readers permit 4,096-byte keys for
`2.1.0`; original `2.0.0` keeps its 2,048-byte ceiling. The new name-tree writer
uses a fanout of 32 so long valid Unicode names fit existing 256 KiB index bounds.
All previous page/row/read limits remain; numerical row semantics are unchanged.

Complete native admission disk-spools retained IDs, concept entries and indexed
names; it rejects extra hidden IDs, missing metadata, duplicate name-index IDs,
missing available names, mixed versions and index/ID mismatches. Native R owns
byte bounds, matching/order, numerical rules and scope/index closure. The Ajv
corpus checks common structural vectors independently; it does not certify native
mathematics, authorization, index completeness or transport behavior. Node is a
contributor/CI oracle, not an end-user runtime dependency.

Run `tests/tracer/saved-labels.R` and the existing marked PostgreSQL publication
suite for compatibility, signed/large IDs, long Unicode names, duplicate names,
row/byte continuations, snapshots, explicit extension rollback/idempotence,
both-mode exact bytes, audience scope, revocation and previous-publication safety.
Million-entry search, >64 MiB inventory, process memory and production UI remain
separate qualification work.
