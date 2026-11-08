# Internal bounded saved-result transports

The installed R package has internal artifact and PostgreSQL adapters plus a
shared verified page traversal engine. These are foundations for semantic result
access, not exported R functions, a browser transport, a public provider protocol
or a complete report/discovery UI. They query approved precomputed results only.
The [native semantic provider](semantic-results.md) adds metric discovery,
typed saved-row selection and denominator/eligibility fetching over these internals.
[Saved concept lookup and optional approved-name search](saved-concepts.md) reuse
these adapters. Artifact `2.1.0` adds the saved-label/index extension; original `2.0.0`
remains supported with unavailable names. The earlier v1 tracer is unchanged.

## Authority and pins

The host supplies a closed context: `contract_version`, `publication_id`,
`release_id`, `source_id`, `profile_id`, `profile_revision`, `profile_sha256`,
`access_scope_id`, exact `root` descriptor, `authorization_epoch` and `instance_id`.
The descriptor contains `sha256`, `bytes`, `kind` and `rows` as defined by v2.
No password, SQL, database schema or source connection is serialized in context.
Registered definitions are checked against the installed package.

A mandatory trusted `authorize(context)` callback returns exactly `TRUE` only
when the host has admitted the complete immutable release, approved the requested
scope/root, and still authorizes this instance/epoch. The callback is called
before and after reads, on cache hits and before returning a completed operation.
It must consult institution-owned authority; implementing it as an unconditional
approval of arbitrary caller-supplied roots defeats that boundary. A root's
`ready` flag, local hash, publication.json or individually valid page cannot
establish full numerical/disclosure admission. See [validator ownership](validator-boundary.md).

The artifact adapter reads only `objects/<validated-sha256>.json` under the trusted
export directory. It does not enumerate the directory, reread a mutable current
pointer, or infer trust from publication.json. Files must be ordinary bounded
files with canonical resolved paths; symlinked files are rejected. File permissions
and immutable-export management remain host responsibilities. Hash verification
rejects changed bytes; this is not an OS-level hostile-filesystem sandbox.

The database adapter receives serving-principal connection details separately and
uses `readResultObject()` on `achillesnext_approved_pages`. It never resolves
current, reads unrestricted aggregates, joins the CDM or has a source connection
parameter. The supplied principal should have only the approved serving views.
Database raw caching is disabled: every fetch checks the view's enabled audience
grant. A static host callback cannot make a revoked database grant readable.
Independently exported artifacts remain subject to their own institutional file
policy and cannot be recalled by revoking the database view.

## Verification and traversal

`.v2_descriptor_check()`, `.v2_safe_file()` and `.v2_verified_bytes()` are shared
with native full-artifact/database validation. They enforce descriptor kinds and
caps, exact length/hash, strict UTF-8/JSON, canonical bytes and object identity.
Descriptor counts have a 512-digit control limit; analytical strings are not
converted to floating point. `.saved_page()` additionally checks all eight wire
context fields, closed root/index/page fields, installed metric/version/definition,
row identity and native exact mathematical predicates, ordering, row count,
index fanout/sums/ranges and the currently approved terminology fields.
Cross-page completeness, denominator/partition reconciliation, admission and
institutional approval still belong to the full release operation.

The internal `.saved_reader()` exposes root reads, bounded partition scans,
inspection counters and idempotent close. Scans traverse only root-reachable
metric catalogue, concept catalogue, data or terminology branches. They verify
ancestor/child ranges, expected branch kind and selected-path duplicate/depth
guards before returning complete partitions. A zero-row branch's index is read
and verified before returning an empty traversal. Missing or corrupt pages fail;
an empty traversal never manufactures a zero-valued analytical result.

Catalogue entries omitted by the root's effective disclosure policy must be
`suppressed` with `rows: "0"` before the reader returns them. Computed entries
and suppressed entries with nonzero row counts fail even if individually typed
correctly. Policy failures clear the cache and invalidate cursors like other errors.

Internal range arguments select encoded partition ranges; they are not semantic
OMOP filters or known-ID membership tests. A partition crossing a range boundary
is returned intact for the later semantic layer to inspect. Consumers of the
future public provider should not construct filenames, descriptors or sort keys.

| Resource | Default | Hard ceiling |
|---|---:|---:|
| Distinct objects verified per operation, including raw-cache hits | 64 | 256 |
| Distinct bytes verified per operation, including raw-cache hits | 8 MiB | 16 MiB |
| Distinct leaf rows verified per operation | 8,192 | 32,768 |
| Returned leaf partitions per scan | 1 | 16 |
| Artifact raw-byte cache | 4 MiB | 8 MiB / 64 objects |
| Database raw-byte cache | Disabled | Disabled |
| Index fanout / depth | 128 / 8 | 128 / 8 |
| Cursor bytes | 8,192 | 8,192 |

Root/index objects remain capped at 256 KiB, data pages at 4 MiB and catalogue/
terminology pages at 1 MiB. Leaf pages contain at most 2,048 rows, with a 64 KiB
row/entry cap. Budget exhaustion fails the operation without returning partial
success. Use smaller scans or explicitly raise controls within the hard ceilings.
Raw cache size is not a total R/JVM/process memory budget: decoding and the result
also consume bounded-by-page/row resources. The opt-in
[large-inventory experiment](inventory-proof.md) measures selective reads and
isolation separately. It does not establish representative production-scale
qualification or a whole-process memory guarantee.

The opt-in `2.1.0` name-tree writer uses a fanout of 32 for long Unicode keys, within the
same 128-child reader ceiling and 256 KiB index limit. Its encoded keys allow 4,096 bytes;
original `2.0.0` keeps 2,048 bytes. Label-specific limits and scope/index admission are
documented in the [concept guide](saved-concepts.md).

A bounded operation may reuse already verified decoded pages for multiple exact
lookups under the same budget and live host checks. That operation-local memo is
discarded at return/error; it does not introduce a database cache across calls.

## Cursors, cancellation and cleanup

Opaque base64url/HMAC cursors bind version, complete context hash, normalized
branch/range selection hash, reader generation and the last complete partition's
unique upper key. Each reader uses a private JVM-generated random secret. Limits
and canonical structure are checked; tampered, cross-reader, cross-context,
cross-epoch and cross-selection tokens fail. A cursor is neither authorization
nor evidence of result existence. Traversal never follows current mid-pagination.

Cancellation is a host-supplied boolean predicate, checked before/after transport
work, after page validation and before return. Cancellation, authorization changes
and other failures clear raw caches and invalidate existing cursors. Closed or
superseded work cannot repopulate the cache or return late data. Closing is
idempotent; transports retain no JDBC connection or open file between calls.

R/JDBC execution is synchronous. Cancellation discards late results at these
bounded checkpoints; it does not promise immediate interruption of an in-flight
statement. The existing serving query timeout is 60 seconds. Browser AbortSignal,
HTTP request cancellation and rendered-instance lifecycle are not implemented by
these R internals.

Classified `achillesnext_read_error` conditions carry safe codes: `inaccessible`,
`unavailable`, `integrity_failure`, `resource_limit`, `invalid_request`,
`invalid_cursor`, `aborted`, `superseded` and `closed`. Backend exception text,
credentials, SQL and raw records are not returned through these conditions.

## Contributor verification

```sh
Rscript --vanilla tests/tracer/saved-transport.R
```

The self-contained routing fixtures exercise pagination and adversarial cases;
their host approval is simulated and does not certify a complete publication.
The existing marked-fixture [serving conformance command](conformance.md) also
runs `saved-transport-integration.R` through `result-export.R`: real approved
artifacts and serving-only database reads must return identical pages, all observed
adapter SQL must target the approved view, and grant revocation must deny reads.
The compatibility CI suite runs both paths; it adds no separate workflow/job.
