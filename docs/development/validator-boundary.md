# Saved-result validation boundaries

AchillesNext separates mathematical definitions, typed result structure,
complete-release validation, institutional approval and verified page transport.
Passing a cheaper layer does not establish the guarantees of the next one.

## Current ownership

| Layer | Current owner | Responsibility |
|---|---|---|
| Definitions and row registry | Locked `inst/analysis` and `inst/contracts/v2` assets; `.v2_assets()` / typed analysis registry | Populations, grains, fields, exact values, row kinds, denominator bindings and integrity of installed definitions |
| Native schema subset | `.nv_schema()`, `.nv_date()`, core metadata/dimension schemas | Closed local references, types, keys, enum/length/pattern/calendar checks; not a general JSON Schema engine |
| Typed row semantics | `.v2_row()`, `.v2_dimensions()`, `.v2_metadata()` | Exact row identity, eligibility/state/payload rules, dimensions, rational means and ordered summary values |
| Exact arithmetic | `.nv_add()`, `.nv_mul()`, `.nv_compare()`, `.nv_unsigned_cmp()` | Integer/decimal strings, bounded exact arithmetic and comparisons; no floating-point substitute for analytical values |
| Complete saved release | `.store_validate()`, `.v2_directory()`, denominator/partition/ledger/capability/passport checks | Full inventory, reference and partition reconciliation, all-concepts totals, summary eligibility pairs, profile/context and approved artifact closure |
| Publication policy | `publishResultRelease()`, institution callback, receipt/content revision, CAS and grants | Explicit retained scope, suppression, immutable approved bytes and audience/current identity |
| Single approved database object | `readResultObject()` and audience-filtered approved views | Bounded saved bytes, hash and supplied source/publication/audience/root context; no CDM queries |
| Selection shape | Internal `.saved_selection()` / per-report capabilities | Exact supported joint grain, period and explicit summary-selector rules, input budgets; not authorization, existence or result validation |
| Semantic result access | Native result providers over the verified reader | Approved catalogue states, exact saved equality matches, declared dependency/eligibility evidence and aggregate operation/response budgets; no reaggregation |
| Saved terminology extension | Locked `inst/contracts/v2.1`, native terminology predicates, snapshot/projection and `.v2_directory()` | Opt-in `2.1.0` provenance, exact captured IDs, matching/order/byte limits, retained-scope and complete name/ID equivalence; per-search name/ID verification under shared budgets |
| Independent contributor checks | Generated row schema/Ajv, native/Node vectors and Python numerical fixtures | Differential structure and independent arithmetic/count/quantile expectations; no end-user Node requirement |

The native row implementation uses `rows.json`, locked dimension/metadata
subschemas and explicit mathematical predicates. It does **not** interpret the
full generated conditional `row.schema.json`. That schema is built by
`tools/build_result_schema.py` for the independent developer Ajv oracle and
contains `allOf`/`if`/`then`/`else`, which the finite `.nv_schema()` engine does not
implement. The difference is intentional ownership, not interchangeable engines.

The optional [saved terminology extension](saved-concepts.md) also has an
independent locked JSON Schema/Ajv oracle and shared structural vectors. Native
terminology predicates own byte limits, matching/order, capture identity and
scope/index closure; `.nv_schema()` does not interpret the full `2.1.0` schema.
Original `2.0.0` unavailable-label rules remain unchanged; both versions require
exact ID tags in concept/terminology catalogues. Special tags remain valid in
their declared data dimensions.

`tools/check_schema_subset.py` now audits the schemas actually consumed by the
native subset and their locks. Unsupported keywords/types/formats, nonlocal or
unknown references, nested `$id` resources, semantic siblings of `$ref`, and schema-valued
`additionalProperties` fail this audit rather than being silently relied upon.
It reports the boundary explicitly and does not validate values or arithmetic.
A future subset extension must update native support, the audit and independent
negative/differential tests together.

## Admission and lazy reads

Complete numerical and publication validation belongs before approval/publication
or at explicit artifact admission. It scans the full release. A verified
individual page does not prove cross-page denominator, partition or completeness
invariants. Repeating that complete scan for every interaction prevents bounded
first-view and selective reads; removing the checks weakens the contract.

The next transport boundary must therefore require an institution/host-trusted
approved root and its full immutable context, backed by the validated release and
policy evidence. Self-declared `publication_state: ready` or a hash supplied by
an untrusted artifact is not that evidence. An unadmitted artifact needs explicit
validation/admission, not an implied claim that viewing one valid page validated
all other reports. The current whole-artifact validator remains available for
that full operation; this document does not add an admission credential/API.

A lazy adapter must verify bounded root-to-page reachability, descriptor/byte
integrity, complete pinned context, row structure/identity and requested semantic
scope; enforce row/byte/cache/depth limits and cancellation; and reject stale or
cross-context responses. It must not resolve current mid-pagination, query CDM or
unrestricted facts, reinterpret unavailable as zero, pool units, combine marginal
populations or manufacture percentiles. The [internal native transports](saved-transports.md)
implement the page/traversal foundation. [Native semantic providers](semantic-results.md)
now consume it; browser adapters remain separate work. Benchmark readers are not
installed providers or authorization boundaries.

## Reuse and generation review

Extracting small native byte/descriptor/context checks for reuse across artifact,
database and future transport code is preferable to embedding a whole-release
scan inside a page getter. Their public names/contracts are not frozen here.
Retain independent full-release tests after any extraction, including malformed
JSON/keys, wrong context, oversized/deep/cyclic/overlapping indexes, missing and
rehashed objects, unsupported grains, scope revocation and late failures.

Finite structural field maps may be generated from the locked row registry and
schemas. Generated code must be deterministic, checksum-bound and differentially
tested. It must not replace the independent numerical oracle with the same
calculation twice. Exact arithmetic, denominator predicates, population/grain
semantics and complete-release reconciliation remain explicit native rules with
handwritten adversarial and independent fixtures. No generic remote schema/plugin
loading or Node subprocess is introduced into installed validation.

The routing experiment preserves original v2 bytes and reuses native full
validation; its Python structural code is intentionally a contributor prototype.
It must not become a third numerical validator or production parser by copying
only its happy path. Its SQLite sidecar is an experimental derived index, with
additional trust, spool cleanup, version/support and dependency costs. Any future
format change requires an explicit version/migration proof; a derived cache can
also be rebuilt without changing the approved analytical payload.
