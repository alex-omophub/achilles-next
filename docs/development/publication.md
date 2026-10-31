# Approved synthetic result publication

Run APIs now produce all 15 frozen alpha outputs, including observed capability
probes and execution status/timing. Successful computation is separate from
approval: staging remains `partial` and cannot be current. The direct count,
observation and measurement development generators retain their partial contract
1.0 behavior. Only the persisted run path can publish a complete result.

## Generate → approve → view

Use the marked fixture setup, trusted configuration and installed R package from
[execution](execution-ledger.md). Publication and current resolution require
Node.js 22.12 or newer. They use a bundled precompiled validator and need no npm,
network, schema compilation or external service at runtime. Viewing a release
uses the installed React/Recharts assets and requires neither Node nor Shiny.

```r
library(AchillesNext)
source("tools/tracer_fixture_config.R") # Contributor example; trusted local config.
runDir <- tempfile("measurement-run-")
planMeasurementRun(runDir, config$cdmSchema, config$sourceId, config$request,
                   config$declaredCdmVersion)
r <- executeMeasurementRun(runDir, config$connectionDetails)
stopifnot(r$state$status == "succeeded")

# Record an actual local review reference; publication is never automatic.
store <- file.path(tempdir(), "restricted-releases")
publishMeasurementRun(runDir, store, approvalId = "fixture-review-001")
release <- currentMeasurementBundle(store)
viewResults(release)
```

`current.json` pins the immutable release path and manifest SHA-256. A viewer
opens that release as one byte snapshot; it does not mix results if another run
becomes current. Complete bundles must contain all 15 requested partitions in a
successful or explicitly policy-suppressed state. Failure, missing requested
outputs, malformed numeric text, unsafe JSON numeric counts, wrong denominators,
extra files, symlinked files and changed checksums are rejected before a pointer
switch. The execution ledger pins its validated staging manifest hash too.

## Output scopes and the policy hook

Restricted publication retains validated fixture aggregates and local terminology.
An approval reference explicitly records that this restricted use was reviewed;
it does not grant permission to distribute those files.

The `synthetic-aggregates-v1` distributable projection permits only:

- The exact all-source person count, preserving a known zero/empty-source state.
- A fixed synthetic passport (`fixture:synthetic`) without source labels, release
  identifiers or vocabulary text.
- Output-state metadata showing which requested metrics were suppressed.

Every observation/measurement output, capability and timing partition is wholly
suppressed: its rows are NULL, not hidden behind the UI. Detailed counts,
denominators, numeric distributions, dimensions and terminology labels are absent
from those files. Suppressing all these partitions also prevents reconstruction
through overlapping monthly, unit, operator or representation totals. No patient
records, frequency tables, plan, ledger, credentials or configuration are copied.
The request's bounded dates and explicit concept IDs remain declared scope
metadata. This is a deliberately conservative policy for marked synthetic fixtures,
not a k-anonymity threshold or a claim of universal anonymization.

```r
shareStore <- file.path(tempdir(), "distributable-releases")
# This hook example intentionally denies publication until configured.
shareRelease <- publishMeasurementRun(
  runDir, shareStore, approvalId = "synthetic-review-001",
  outputScope = "distributable",
  institutionalPolicy = function(candidate) {
    # Replace this with a trusted approval check bound to the projected manifest
    # and candidate$content_sha256. The example denies until configured.
    FALSE
  }
)
# After a configured check approves, open the returned shareRelease.
```

The hook receives the projected manifest (including final partition hashes) and
a SHA-256 of its complete candidate content. It can deny publication, never
add fields or relax the built-in projection. The caller remains responsible for
an actual approval decision and an approval reference without secrets or personal
information. Neither callbacks nor credentials are serialized. Institutional data
execution and broader disclosure policies remain unsupported.

Use a separate store for each scope. New stores must be empty, and an existing
store rejects a mismatched scope or unrelated root files. Share only the returned
release directory after checking its manifest, not run storage or a parent folder.
The projection changes the recorded request scope, source alias, request hash and
bundle ID; it never re-labels restricted bytes as distributable.

## Failure and consistency guarantees

The publisher reserves `.publication-lock`, writes a private `.candidate-*` folder,
validates its full inventory/schema/semantics/hashes, renames it into
`releases/bundle-…`, then atomically replaces `current.json` through a temporary
file in the same store. The old pointer is never removed first, and prior release
directories remain intact. Concurrent publishers fail closed on the lock; different
run directories cannot share staging. Candidate-write, validation, release-rename
and pointer-switch failures cannot replace the last complete release.

A process crash after release rename but before pointer switch may leave an
unreferenced complete release. Hard termination can leave a candidate and lock;
there is no automatic lock takeover or garbage collection. Existing release IDs
are refused rather than overwritten. Guarantees cover process interruption on a
trusted local filesystem, not power loss, hostile edits or network filesystem
semantics. Release immutability is enforced by API behavior; owners can manually
edit local files, and subsequent current resolution rejects changed bytes.

The source snapshot remains unknown, with an explicit reproducibility limitation.
Complete publication describes requested-output completeness and approval, not
reusable input identity. No cross-run reuse is enabled. [Execution recovery](recovery.md) creates a new
recomputed attempt and requires a separate publication approval.

## Telemetry and contributor checks

Capability rows reflect catalog presence and column/schema SELECT access in the
same read-only session as computation; optional missing CDM fields do not block
supported metrics. A capability is a structural/access probe, not a claim about
clinical coverage or data quality. Compute timing is the measured physical operation
duration. Metrics sharing an operation repeat that duration; do not sum those rows
as independent work. Unmeasured materialize/validate/export phases and metadata
self-timing carry NULL with a reason, never a fabricated zero. Detailed query hashes
and unavailable PostgreSQL warehouse query identifiers remain in the private run
ledger, outside published bundles.

```sh
Rscript --vanilla tests/tracer/run-ledger-offline.R
Rscript --vanilla tests/tracer/run-ledger.R tools/tracer_fixture_config.R /path/to/new-ledger-tests
Rscript --vanilla tests/tracer/publication.R tools/tracer_fixture_config.R /path/to/new-publication-tests
PUBLICATION_TEST_BUNDLES=/path/to/new-publication-tests npm test --prefix packages/tracer
```

The live publication test covers CDM 5.3/5.5, reference/weighted computation,
empty source/population, real zero, suppression readback, denied/erroring policy
hooks, scope separation, exact-value corruption, extra files, failed analyses and
failed release/pointer renames. It screens serialized artifacts against the actual
fixture credentials without printing them. Tests use only disposable marked
synthetic schemas. The same existing CI job runs the checks; no duplicate workflow
or separate R installation is introduced.
