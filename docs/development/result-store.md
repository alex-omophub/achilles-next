# Experimental PostgreSQL aggregate storage

`initializeResultStore()` installs new results and serving schemas atomically,
refusing existing schemas and overlap with declared source schemas. It grants no
serving access and never modifies CDM tables. Use a dedicated installer account.

```r
initializeResultStore(connectionDetails, "achilles_results", "achilles_serve",
                      sourceSchemas = c("cdm", "vocabulary"))
```

The core numerical profile defines 142 domain results. **Domain generation for
this profile is not implemented by these APIs.** The existing synthetic tracer
continues to generate its frozen 15-output format. These are separately versioned
storage/publication APIs for an already populated core-profile release.

Counts and summaries use PostgreSQL NUMERIC and exact strings in R/JSON. A worker
writes its own building release using SELECT-only source privileges and separate
results authority. Dataset/cell/denominator writes lock their parent and increment
its content revision. Sealing makes facts immutable. No per-concept or chart-time
CDM query is exposed. Run-owned source materialization belongs in a separately
owned staging schema; the publisher reads only saved aggregates.

## Validate → project → export → select

1. `sealResultRelease(details, "achilles_results", releaseId)` checks registered
   profile inventory, versions, populations, grains, required states and row counts.
2. `validateResultRelease(details, "achilles_results", releaseId)` streams rows via
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
  details, "achilles_results", releaseId,
  exportDir = "/approved/new-publication", accessScopeId = "internal-research",
  approvalId = "institutional-review-reference", policy = policy,
  institutionalPolicy = function(candidate) {
    # Institution-controlled decision over this exact root hash and policy.
    # Replace with the institution's approval lookup/check.
    stop("Configure institutional approval")
  }, expectedRevision = "0")
```

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
on `approved_pages`/`approved_current`, plus an enabled `audience_grant` for that
principal and scope. Give it no CDM, staging or base-results access. Views check
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
Trusted local same-filesystem renames are assumed; no power-loss or network-filesystem
atomicity guarantee is made. Stale destination locks need operator inspection.
