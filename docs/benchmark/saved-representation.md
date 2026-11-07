# Contributor saved-representation experiment

This developer harness compares two routing representations over **identical saved
JSON page bytes**. It is not an installed provider, product format, database adapter,
clinical validation service or production performance qualification.

- **Tree:** the existing v2 root/index/page hierarchy, with bounded hash-path reads.
- **Flat:** the same v2 artifact partitions plus a SQLite routing sidecar and pinned
  experimental manifest. SQLite stores opaque range keys and descriptors as TEXT;
  analytical counts, decimals and JSON values remain unchanged in the page files.
  Retaining the original objects permits lossless native validation; this measures
  a flat routing alternative, not a newly optimized analytical encoding.

No format, public API, installation dependency or migration is enabled by running
this experiment. Python's SQLite module is a contributor dependency only. The R
package still performs native numerical validation without Node.

## Run locally

Install the checkout and configure the existing R/JVM environment. Generate
synthetic full/reduced exports with the
[core conformance command](../development/conformance.md#compose-complete-refresh-with-approved-publication),
or supply existing approved synthetic exports. The benchmark never queries an OMOP
source, changes an input artifact, starts a database or dispatches a hosted job.

```sh
python3 tools/benchmark/representation.py \
  --artifact "$core_evidence/publication-full" \
  --artifact "$core_evidence/publication-projected" \
  --catalogues 512,65536,131072 --trials 3 --queries 64 \
  --output-dir "$private_evidence/saved-representation"
```

The output directory must be new and outside the checkout. Data, measurements,
worker configurations, native validation evidence and machine reports remain local.
The CLI caps synthetic catalogue entries at 262,144, sampled partitions at 100,
and paired trials at three. The default routing fixtures exercise singleton,
128-partition and multi-level 256-partition trees with 512 entries per leaf.
They are explicitly **routing-only fixtures**, not approved complete publications
or million-concept/name-search qualification. Their deterministic ASCII fixture
encoding is independently checked for canonical bytes; native tree construction,
range encoding and descriptor hashing use the installed package implementation.

## Comparable work and trust

Each strategy exports the same original page bytes. Payload-inventory hashes,
object counts and byte totals must agree. The complete core copies each pass the
same native `validateResultArtifact()` implementation. Native validation is timed
once per representation; routing fixtures receive byte/context/structural checks
and must not be reported as passing native publication semantics.

Every selected page is bounded, hashed, canonical-JSON checked and matched to all
pinned context fields: source, publication, release, profile ID/revision/hash,
access scope and contract version. The flat manifest has its own trusted pin;
the full sidecar index is hashed and copied in 64 KiB blocks to a private spool
before SQLite opens it read-only. Its maximum is 8 MiB, its cache is 64 KiB and
memory mapping is disabled. Index verification/copy/open/cleanup is measured,
not bypassed to obtain a faster lookup. The private copy prevents later changes
to the supplied index from changing that reader session. This is a benchmark
admission model, not an authentication or institutional approval API.

The tree follows verified range descriptors; the flat route query uses a bounded
BINARY-collated range seek. Both return an exact **partition**, not a semantic row
answer or proof that a concept is present. Filtering, supported-grain decisions,
row/denominator closure, semantic cursors, cancellation and catalogue/name search
remain provider work. Singleton leaves can contain the entire small partition;
a future semantic consumer must inspect its verified contents.

## Measurements

The run records a seeded paired strategy order, input pins, benchmark source
checksums, exact returned-byte parity, export time/CPU/size, native validation
elapsed/CPU, first-view partition reads, repeated lookup latency, verified bytes
and process memory. Worker processes are fresh; session samples reuse one reader.
The initial core view reads the PERSON summary partition plus metric catalogue.
There is no decoded-page cache in either prototype.

Timing sessions have Python memory tracing disabled. Separate reader sessions
measure peak traced Python allocations, which exclude SQLite/JVM/native allocations.
Process and child `ru_maxrss` values are retained in platform-native units, not
normalized, subtracted, added across processes or called a cgroup memory budget.
R native validation and its process startup/identity cost are reported separately.
Keep R session/JVM information with local evidence when comparing runs.

Operating-system caches are uncontrolled; a fresh client is not an OS-cold read.
SQLite internal I/O is not observable in the verified-byte counters. P95 values
summarize the selected small sample, not institutional/WAN latency. No source
workload, UI rendering, browser memory, label search or database-backed serving
performance is measured. Synthetic correctness and local timings cannot close a
representative-scale or operational gate.

See the [validator boundary](../development/validator-boundary.md) for the full
admission-versus-lazy-read responsibilities. Keep numerical semantics and
institutional approval intact when evaluating a faster routing implementation.
