# Registered analysis contribution example

The installed `reference-person-v1` profile demonstrates a separate analysis
through generation, native validation, institutional approval, export and saved
readback. It contains a total PERSON count and counts by raw gender concept ID.
It does not add outputs to the frozen 142-result core profile or make that
profile complete. The initial extension seam supports exact PERSON count
partitions; other row kinds and populations are rejected.

The contribution consists of four independently reviewed parts:

- `inst/analysis/reference-person-v1.json`: mathematical questions and populations.
- `inst/analysis/reference-person-rows-v1.json` and
  `reference-person-definitions-v1.json`: row shapes and typed denominator rules.
- `inst/sql/postgresql/reference-person-*.sql`: installed source validity and
  aggregate queries. Only aggregate JSON leaves the source query.
- `tests/fixtures/reference-person-v1.json`: independently authored expected
  counts, including NULL, zero, negative and greater-than-2^53 identifiers.

`registered-profiles-v1.json` registers the files, revision, singleton and additive
partition constraints. `registered-profile-lock.json` binds their exact bytes.
Adding an analysis within the supported shape changes its definition, SQL,
fixture and registration; it requires no metric-specific branches in the generic
planner, publisher or reader. Installed files are trusted package code reviewed
before installation. Runtime calls cannot supply definitions, SQL, paths or remote
schemas. Unknown profiles, revisions and hashes fail explicitly.

## Generate, then view saved aggregates

```r
plan <- planAnalysisProfile("reference-person-v1", "cdm", "local-source", "5.5")

# New stores register all installed profiles during initialization. An existing
# store owner can register the installed definition without changing its schema.
registerAnalysisProfile(ownerDetails, "results", "reference-person-v1")
run <- generateAnalysisProfile(
  runnerDetails, "cdm", "local-source", "results", "5.5", "reference-person-v1")

sealResultRelease(ownerDetails, "results", run$release_id)
validateResultRelease(ownerDetails, "results", run$release_id)
policy <- list(id="local-policy", revision="1", scope_kind="restricted",
  allow_metrics=list("example.person.count", "example.person.gender_count"))
approved <- publishResultRelease(ownerDetails, "results", run$release_id,
  "/new/export", "local-audience", "local-review-record", policy,
  institutionalPolicy=function(candidate) approveLocally(candidate))
validateResultArtifact(approved$export_dir)
```

`ownerDetails`, `runnerDetails` and `approveLocally()` are institution-supplied;
the example does not grant permissions or supply an approval policy. The generator
requires SELECT on the declared source columns, INSERT on its result tables and
UPDATE on dataset row counts and run/release state. Registration requires INSERT
on the profile registry. It executes a bounded aggregate stream in a repeatable-read
transaction, checks unique/non-null PERSON membership and accepts exact integer
source columns. `maxRows` bounds transferred aggregate rows; it is not a limit on
the source database's scan or sort. Per-statement timeouts are explicit.

Publication reads saved aggregates only. Existing `readResultObject()` accepts
the complete pinned source/publication/scope/root context through an approved
serving role and validates the registered profile identity. Generation is always
an explicit batch action. Browsing never runs a CDM query. NULL strata remain
report rows and do not become fabricated concept-catalogue entries.

This is a native R/PostgreSQL contribution example, not a browser plugin loader,
new engine certification or general dashboard extension API. The current React
viewer does not render arbitrary registered profiles. Public semantic providers
and report mappings remain separate work.

## Verify from a checkout

After installing the package:

```sh
Rscript --vanilla tests/tracer/registered-profile-offline.R
python3 tools/test_result_serving.py --test-script registered-profile \
  --state /private/marked-fixture-state --config tools/tracer_fixture_config.R \
  --output-dir /new/private/reference-proof
```

The integration harness refuses an unmarked database. It uses disposable schemas
and a temporary serving-only role, compares independently specified numbers,
rejects invalid membership/types, verifies rollback and partition corruption,
tests disclosure dependency closure and empty source, drops the source table and
reads the original approved counts in a fresh serving-only process. It cleans up
its schemas and role. Credentials and generated evidence stay outside Git.
