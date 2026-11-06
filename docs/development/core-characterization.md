# Complete restricted core candidates

`generateCharacterizationCandidate()` precomputes the 138 numeric baseline outputs
and four metadata outputs into a new restricted building release. All 142 frozen
outputs are accounted for, including explicit unsupported states for conditional
columns. This entry point uses the same exact numeric operators as
`generateMeasurementBaseline()`; that older entry point still produces its
138-output partial baseline.

```r
candidate <- generateCharacterizationCandidate(
  workerDetails, "cdm", "institution-source", "results", "5.5")
stopifnot(candidate$profile_complete, !candidate$publishable)

# Separate institution-controlled store operations; no automatic approval.
sealResultRelease(storeOperatorDetails, "results", candidate$release_id)
validateResultRelease(storeOperatorDetails, "results", candidate$release_id)
```

The worker needs SELECT-only source privileges, database TEMPORARY and result-store
producer grants. It also needs SELECT on `achillesnext_storage_version`, whose
`2.0.0` marker is checked before generation. Missing or denied required dependencies, unsupported
exact numeric types, cancellation, timeouts and resource-limit failures roll back
the candidate transaction. Absent optional columns can leave schema-conditional outputs explicitly
unsupported instead of failing the candidate. `maxAggregateRows` counts metadata as well as numeric
rows. Stage byte checks happen after allocation; they are not hard memory, spill
or production-scale guarantees.

## Saved metadata

- **Passport:** institution source ID, declared version, observed schema hash,
  frozen profile identity, complete requested coverage and generation timestamps.
  Source and vocabulary release identities remain explicitly unknown. Existing
  `cdm_source` or `vocabulary` labels cannot prove an immutable release. All inputs
  share a repeatable-read transaction; cross-run reuse remains false.
- **Capabilities:** every physical dependency and alias from the frozen manifest,
  plus its declared metadata probes. Catalog evidence records absent and denied
  columns separately, including their physical types and modifiers (such as NUMERIC precision/scale
  and VARCHAR length) where visible. One bounded
  existence read per readable relation distinguishes available from available-empty;
  no additional full-table count or patient values are retrieved. Catalog/probe
  services are available; operator assertions are absent because this API does
  not accept them. Optional descriptive metadata tables are probed without treating
  their contents as verified identities.
- **Output status:** all 142 requested metrics, with their actual state, reason,
  required flag and coverage. Metadata stays computed even for an empty clinical
  source. The generation ledger records integrity as pending; the subsequent native
  validation receipt binds sealed content. The ledger does not embed a circular
  self-hash or retroactively claim to have passed a later operation.
- **Timing:** monotonic wall time for each materialized stage and numeric generation
  through persistence/reconciliation. The latter ends at metadata assembly and
  excludes writing all four metadata outputs and transaction commit. These nested
  intervals must not be summed as independent work. Validation, projection, export
  and publication are unavailable at capture time. CPU, memory, scanned-source-row
  and spill-byte telemetry remains NULL when unmeasured.

The source schema hash includes observed columns/types and read permissions for
probed relations. It identifies schema evidence, not row contents or an immutable
source snapshot. Generation timestamps end at the metadata capture boundary.

## Publication and refresh boundary

A complete candidate remains restricted and unapproved. Sealing and native
validation do not grant audience access or change the current publication. Existing
institution-controlled projection/approval/promotion operations remain separate.
The direct candidate generator does not execute a refresh plan, schedule work,
reuse previous aggregates, migrate stores or expose a production UI. Browsing
continues to consume saved aggregates without source joins. Use the separate [refresh executor](refresh.md) to consume a checked plan.
Controlled overlap/CAS proofs and upgrade/retention procedures are described in
[store operations](store-operations.md); actual migration/deletion and scale
qualification remain separate.

## Contributor checks

After [fixture setup](count-tracer.md#developer-setup) and package installation:

```sh
set -e
Rscript --vanilla tests/tracer/core-metadata-offline.R
python3 tools/test_core_characterization.py --config tools/tracer_fixture_config.R \
  --output-dir "$(mktemp -d)/core"
# Also cover populated 5.4 and 5.5 fixtures:
python3 tools/test_core_characterization.py --config tools/tracer_fixture_config.R \
  --output-dir "$(mktemp -d)/core-matrix" --full-matrix
```

The default local proof covers populated 5.3 aliases and an empty 5.5 source. CI
runs `--full-matrix`, adding populated 5.4 (denied descriptive metadata) and 5.5.
The same harness also verifies that numeric precision/scale and varchar length
changes alter the saved schema fingerprint, while repeated probes remain stable. Independent
Python expectations compare all 138 numeric outputs and all four metadata outputs;
real candidates are sealed and natively validated with source privileges revoked.
A late metadata row-budget failure proves atomic rollback. Tests use disposable
marked synthetic schemas, restore TEMPORARY grants and leave canonical sources
and existing publications untouched.

The [integrated conformance mode](conformance.md#compose-complete-refresh-with-approved-publication)
composes checked full refreshes with real approval, full/reduced projections,
export and exact pinned approved-page reads. It retains the independent numerical
and metadata matrix, using a serving principal with source and aggregate access
denied. The synthetic proof qualifies this local pipeline boundary; it does not
qualify a production viewer, migration/deletion tooling or another engine.
