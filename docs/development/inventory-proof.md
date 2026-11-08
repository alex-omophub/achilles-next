# Saved inventory, cancellation and isolation experiment

This opt-in contributor experiment builds deterministic physical `2.1.0` saved
results with one million retained concept IDs and saved names, plus matching
PERSON counts and gender partitions. They are artificial inventory identities,
not a clinical population or real vocabulary. The generated inventory exceeds
64 MiB. It exercises saved-result admission and reading, not CDM generation,
the representative-scale batch gate, browser heap or another database engine.
The default workload uses 512-row leaves, short ASCII labels and trees with at
most 128 children. These choices are recorded in its fixture manifest; they do
not exercise every maximum-size row/page permitted by the physical contract.

The fixture has the full 142-entry catalogue with two retained metrics and explicit
suppression for the others. Every saved ID occurs in a retained aggregate row;
every available label has an identical ID/name-index entry. Full native admission
checks scope, row identity, counts, exact references and partition reconciliation
before a reader can use the fixture. No predicate or approval step is skipped to
make the stress run faster.

All capture/provenance fields in this constructed fixture are synthetic
placeholders, not evidence of a vocabulary capture or database snapshot. In
particular, `snapshot_sha256` is a deterministic digest of the canonical entries,
not the digest of a `captureConceptSnapshot()` file. No capture file is created.
Actual capture-file provenance is tested by the separate saved-label integration
suite; this experiment tests the saved inventory and read boundary.

## Run the artifact experiment

Install the current package and configure the already required R/JVM dependencies
as described in [conformance](conformance.md). Run from the repository root:

```sh
python3 tools/benchmark/inventory.py all \
  --output-dir /path/to/new/inventory-run --entries 1000000 --samples 20
```

Output must be new. `build`, `admit` and `read` can also run separately against
the same directory. Admission writes `admission.json` only after complete native
validation. Read mode checks the receipt's exact fixture/root binding. To repeat
reads in a fresh process, supply a new `--run-id`; existing results are refused.
Each worker runs frozen copies of its protocol sources, so later checkout edits
cannot alter a running experiment. Per-worker metric sidecars are retained even
when the worker fails; a failed controller is never reported as a successful run.
The small CI smoke uses 96 entries and six unique IDs: first, midpoint and last,
plus three deterministic IDs selected by `--samples 3`. The million-entry run is
deliberately excluded from routine CI; it needs time and local disk for artifacts
and temporary native validation data. No new dependency install or job is needed.

The current measurement controller uses Unix `wait4`. Unsupported platforms fail
before fixture generation for measured runs; standalone `build` does not require
process telemetry. It reports worker lifetime peak RSS (including the in-process
JVM), CPU and elapsed time. R GC region usage
is reported separately. Build time/bytes are recorded, but RSS measurements cover
the R admission/read workers, not the Python controller. These measurements exclude database memory and OS page
cache. A fresh worker is not an OS-cold read: OS cache is explicitly uncontrolled.
Numbers from a shared developer machine do not establish production latency or
memory budgets. Each read result records exact response hashes, serialized bytes,
distinct verified object/byte/row counts and cache occupancy.

## Optional PostgreSQL transport mirror

After the artifact read proof passes, the existing marked synthetic fixture
database can host a disposable mirror of those admitted pages:

```sh
python3 tools/benchmark/inventory_database.py \
  --state /path/to/synthetic-fixture-state \
  --fixture /path/to/inventory-run \
  --output-dir /path/to/new/database-run --samples 20
```

The fixture setup requires the same local administrative access used by the
[synthetic serving harness](conformance.md). `--admin-host`, `--admin-user` and
`--port` select that connection. Both the admin target and the service-resolved
owner are guarded before mutation; the owner must be the fixture owner in the
marked fixture database and match the admin server's startup/port identity.
The JDBC reader uses the selected TCP admin host; socket paths default to
`127.0.0.1`, with `--reader-host` available for an explicit TCP mapping.
Reader hosts containing whitespace are rejected rather than trimmed.
It refuses an unmarked database. A temporary
NOSUPERUSER role gets only serving-schema/view access; explicit privilege checks
deny CDM and mirror-store schema access. Schemas and role are removed in `finally`.
No passwords are serialized in read results or command arguments.

This is a **transport-only mirror**, using the shipped `achillesnext_approved_pages`
view definition and admitted immutable page bytes. Its small relational control
fixture represents that approval. It is not a generated typed store, a new
publication API, or evidence that million-row generation/publication has passed.
The regular synthetic publication suite tests that separate boundary. COPY uses
one page at a time; reader telemetry comes from a separate fresh R process and
does not include mirror bootstrap.

Artifact/database semantic response hashes must match for the same sample order;
opaque cursor values and diagnostic budgets are excluded from that comparison.
Every submitted provider page SELECT is checked against the approved view. No
provider source connection, CDM statement, current lookup or restricted-fact query
is allowed. Live database grant revocation must deny reads even with a static
host authorizer; restoration must make the pinned publication readable again.

## Executable boundaries

The shared proof covers count/byte continuations inside a physical page, exact
missing-ID states, unavailable matches, operation-budget failure, cross-method/
selection/instance/epoch cursors, wire context mismatches, cached authorization
revocation, pre-cancellation, post-fetch cancellation, candidate-loop cancellation,
late corrupted bytes and close/epoch changes during a fetch. Failure clears raw
cache and invalidates that reader's cursors. Another instance must retain its
own valid continuation. Artifact reads ignore a changed `publication.json` and
use the admitted host pin. Full admission, directory enumeration and database
connections are explicitly forbidden during artifact interactions.

Cancellation remains cooperative. It discards late data at checked boundaries;
it does not promise immediate interruption of synchronous JDBC or file parsing.
The [existing verified read budgets](saved-transports.md) are unchanged: default
64 objects / 8 MiB / 8,192 leaf rows per operation and a 4 MiB artifact raw cache;
database caching remains disabled. These limits do not bound whole-process RSS.
The generated label order follows numeric ID order. Scattered ID sets are tested
separately: an oversized request must fail without partial success, while smaller
cursor pages remain bounded. Arbitrarily scattered name-to-ID order, long-label
workloads and institutional latency are not performance-qualified by this fixture.
Shared budgets can reject a request even when its result-count limit is valid;
use smaller pages rather than interpreting that rejection as an absent concept.

## Native validation scratch

Native full admission now spools row and concept witnesses into two disk maps,
each with one value stream and a fixed-width hash index. The index grows at
most half occupancy and rehashes one slot at a time. Exact keys, duplicate checks,
reference lookups, label equality, retained-ID/name markers and the second pass
are preserved. No million-row/name map is loaded into R. Rehashing checks the
existing cancellation predicate every 1,024 slots; temporary connections/files
are closed and removed on failure. Page-inventory and record-partition
witnesses remain separate. This changes scratch implementation, not wire/storage
contracts, numerical definitions, institution policy or admission ownership.

Canonical serialization has a byte-preserving fast path for plain printable
ASCII strings without double quotes, slashes, backslashes or control characters.
jsonlite still handles escapes, Unicode,
classes and other scalars. A frozen pre-optimization oracle checks exact byte and
rejection parity, including controls, closing tags, UTF-8 and large-ID strings.
