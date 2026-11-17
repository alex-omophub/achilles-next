# Experimental PostgreSQL aggregate storage

`initializeResultStore()` installs new results and serving schemas atomically,
refusing existing schemas and overlap with declared source schemas. It grants no
serving access and never modifies CDM tables. Use a dedicated installer account.

`inspectResultStore()` provides a read-only version-marker check. The
[refresh contracts](refresh.md) distinguish that precondition from content
validation, write permissions, refresh execution and future store upgrades.

The [source/store boundary guide](source-store-boundaries.md) describes the
implemented transaction topology, internal aggregate interfaces and exact numeric
requirements for future source adapters. Only the PostgreSQL path is implemented.

```r
initializeResultStore(connectionDetails, "achillesnext_results", "achillesnext_serve",
                      sourceSchemas = c("cdm", "vocabulary"))
```

All persistent store tables, their partitions and serving views use the fixed
`achillesnext_` prefix, for example `achillesnext_dataset`,
`achillesnext_aggregate_cell` and `achillesnext_approved_pages`. Schema names are
configurable; the recommended names are `achillesnext_results`,
`achillesnext_serve` and, for future worker staging, `achillesnext_stage`.
The prefix distinguishes these objects from legacy Achilles tables such as
`achilles_results`. The installer creates new schemas; it does not rename existing
experimental stores or legacy Achilles objects.

The core numerical profile defines 142 domain results. These storage APIs do not
compute domain results. The separate [baseline producer](population-baseline.md)
generates 19 population/observation outputs into a building core release. The
[domain producer](domain-baseline.md) accounts for 119 outputs with explicit
conditional support states, saved concept/time selection and paging. The
[measurement baseline](measurement-baseline.md) accounts for 138 outputs; the
[complete candidate generator](core-characterization.md) adds metadata for all
142. Each generator leaves approval and current-pointer promotion separate. The existing synthetic tracer
continues to generate its frozen 15-output format. These are separately versioned
storage/publication APIs for an already populated core-profile release.

Counts and summaries use PostgreSQL NUMERIC and exact strings in R/JSON. A worker
writes its own building release using SELECT-only source privileges and separate
results authority. Dataset/cell/denominator writes lock their parent and increment
its content revision. Sealing makes facts immutable. No per-concept or chart-time
CDM query is exposed. Run-owned source materialization belongs in a separately
owned staging schema; the publisher reads only saved aggregates.

Publishers also need SELECT on their results schema's
`achillesnext_page_object` table, in addition to their publication write privileges.
Finalization streams this publication's stored object hashes to install its files.

## Validate → project → export → select

1. `sealResultRelease(details, "achillesnext_results", releaseId)` checks registered
   profile inventory, versions, populations, grains, required states and row counts.
2. `validateResultRelease(details, "achillesnext_results", releaseId)` streams rows via
   JDBC strings, checks closed row/metadata schemas, canonical keys and exact
   arithmetic, resolves denominators and checks implemented additive reconciliations.
   It issues a receipt bound to the sealed revision and profile, then validates the
   release. A receipt is distinct from institutional disclosure approval.
3. `publishResultRelease()` builds a separate projection, validates the entire
   artifact, obtains explicit approval, saves the same bytes in PostgreSQL and the
   artifact directory, and optionally advances current with compare-and-swap.

```r
policy <- list(id = "institution-approved", revision = "1",
               scope_kind = "restricted",
               allow_metrics = list("core.person.count"))
publication <- publishResultRelease(
  details, "achillesnext_results", releaseId,
  exportDir = "/approved/new-publication", accessScopeId = "internal-research",
  approvalId = "institutional-review-reference", policy = policy,
  institutionalPolicy = function(candidate) {
    # Institution-controlled decision over this exact root hash and policy.
    # Replace with the institution's approval lookup/check.
    stop("Configure institutional approval")
  }, expectedRevision = "0")
```

`maxExportBytes` limits the total serialized new export, defaulting to
`1024^3` (1 GiB). It accepts finite whole bytes from zero through `2^53 - 1`.
As objects are emitted, the writer incrementally charges each immutable object
and `publication.json` once, before opening that individual file. Earlier staged
files may already exist when a later object or pointer exceeds the remaining
budget; confirmed pre-COMMIT cleanup removes this attempt's files. Moving written
objects into the reserved destination, database copies and artifact admissions
do not charge again. This logical
output cap is separate from validation's `maxScratchBytes` and excludes the
terminology INPUT snapshot copy, database storage, filesystem metadata and memory.
It does not reserve disk space or establish a hardware minimum. See
[bounded validation and export](bounded-validation.md) for scopes and errors.

A successful return confirms the database commit and publisher disconnection.
On failure before COMMIT is invoked, the publisher attempts rollback and cleanup.
Confirmed rollback and cleanup preserve prior current and remove only this
attempt's files. Cleanup uncertainty is reported explicitly; owned files may
already have been removed while rollback remains unconfirmed.
Once COMMIT is invoked, a lost acknowledgement is an
unknown outcome: `AchillesPublicationFailure` reports `publication.commit_unknown`
and retains the approved export. The server may already have advanced current.
A confirmed commit followed by disconnect or return interruption also retains the
export, reporting `outcome="committed"` instead of claiming rollback. Inspect the
restricted store using the diagnostic `publication_id`, `release_id` and
`root_sha256`, and inspect the originally requested export directory before manual
recovery. Errors contain no artifact path, SQL or credentials, and trigger no
retry, deletion of retained approved output or automatic pointer repair.

`publication_changed` is TRUE for a confirmed committed publication, FALSE before
COMMIT and NULL when commit is unknown. `current_changed` is FALSE if no promotion
was requested; otherwise it follows that known/unknown transaction outcome.
`rollback_state` and `disconnect_state` distinguish acknowledged cleanup from an
unconfirmed attempt. A rollback acknowledgement after uncertain COMMIT does not
prove that the earlier commit was undone. File/connection cleanup uncertainty is
reported as `publication.cleanup_failed` unless COMMIT is unknown: then
`publication.commit_unknown` takes precedence and the cleanup states still report
unconfirmed actions. Cleanup on process termination or power loss is not guaranteed. These outcomes do not change approved bytes, policies or
compare-and-swap behavior.

There is no default institutional policy. The explicit allowlist retains whole
registered outputs, physically omitting other data and terminology. Omitted
outputs remain explicit suppressed catalogue entries; outputs depending on an
omitted denominator are omitted too. A smaller projection omits the original
whole-source output-status ledger and uses its own catalogue. This API does not
implement automatic small-cell suppression or claim an allowlist alone prevents
statistical disclosure. Approval covers the entire candidate, including source
identity, retained metadata and overlapping analyses.

The callback receives policy, opaque identities and the exact root descriptor;
it receives no database credentials or patient records. It must return TRUE.
Keep approval outside source-generation code. All errors exposed by publication
are fixed diagnostics without source SQL, paths or clinical values.

`expectedRevision = NULL` prepares an approved publication without selecting it.
An exact revision string selects current as the final short database operation.
One competing writer wins; a stale writer fails without replacing current.
`promoteResultPublication()` can select an already ready publication later;
replaying selection of the already current publication is idempotent.

## Pages and read access

A v2 artifact contains `publication.json` and `objects/<sha256>.json`. Each object
is canonical compact UTF-8 JSON plus one LF, with full publication/source/profile/
audience context. The root contains bounded catalogue, concept, data and terminology
references. Index nodes have at most 128 children and eight levels; data/catalogue
pages have at most 2,048 rows. Limits are 256 KiB for root/index, 1 MiB for catalogues,
4 MiB for data and 64 KiB per row. Producers split pages rather than truncate values.
The root also binds the observed schema hash and declared CDM version so a saved
source passport can be checked against its publication context.
Counts, decimals and IDs remain strings; summaries retain exact `(sum,n)` means.
An unavailable/unsupported optional CARE_SITE marginal has NULL values and a
reason; it is never encoded as a zero or as a failed required domain output.
The initial aggregate writer/exporter accepts the registered ALL route (`A`);
interactive selectors use the resulting immutable page indexes. Signed concept
IDs use the shared numeric key codec rather than decimal lexical ordering.
Saved concept labels are explicitly unavailable in this initial exporter; it does
not fetch vocabulary labels at publication time.

`validateResultArtifact(path)` streams reachable objects, rejects malformed,
noncanonical, tampered, extra or symlinked files, and verifies row coverage,
context, references and applicable reconciliations. Disk spooling bounds validator
memory; temporary space scales with aggregate size. No Node process is used.

Grant a dedicated gateway principal USAGE on the serving schema and SELECT only
on `achillesnext_approved_pages`/`achillesnext_approved_current`, plus an enabled
`achillesnext_audience_grant` for that principal and scope. Give it no CDM,
staging or base-results access. Views check
invoking CURRENT_USER. A trusted host authorizes each user/request and supplies a
pinned publication, source, root hash and scope; client context is not a grant.

`readResultObject()` reads one saved approved page through that view and returns
its exact raw bytes. Child descriptors must come from verified root/index pages.
It never follows current mid-view or queries aggregate/source tables. Revocation
prevents later database reads; independently exported files remain under the
institution's file-access policy. The existing React tracer is still the legacy
format viewer; these APIs do not silently relabel a v2 artifact as that format.

## Verification and limits

Contributor checks use the installed R package:

```sh
Rscript tests/tracer/native-validation.R .
Rscript tests/tracer/result-wire.R /tmp/result-v2-corpus.json
node packages/contracts/tools/validate-v2-corpus.mjs /tmp/result-v2-corpus.json
Rscript tests/tracer/result-store.R tools/tracer_fixture_config.R
python3 tools/test_result_serving.py --state .local/postgresql \
  --config tools/tracer_fixture_config.R --output-dir /tmp/new-result-export
```

The last command requires local fixture-administrator access, creates a temporary
unprivileged reader, verifies source/base-table denial and revocation, and removes
it. It refuses an unmarked database. The test inventory is explicitly synthetic
and mostly policy-suppressed; it is not a proof of implemented domain computation.
The legacy publication test also runs with a deliberately unusable Node executable.

Per-row revision guards and export throughput remain unqualified. No large-source
performance, additional-engine compatibility or general-purpose clinical validation
is claimed. Trusted operators control base writes and receipts; manually inserting
approval/validation rows bypasses the R pipeline. A crash before database commit
can leave an approved but unreferenced export, which is never selected automatically.
Finalization atomically reserves a new destination directory, moves its admitted
objects with bounded traversal, then installs `publication.json` last. A destination
created by another writer is refused and kept intact. The destination is not an
admittable artifact during installation. Trusted local same-filesystem file moves
are assumed; no power-loss or network-filesystem atomicity guarantee is made. Stale destination locks need operator inspection.
