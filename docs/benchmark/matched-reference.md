# Full-profile matched reference on small fixtures

This opt-in contributor tool compares the complete frozen core characterization
profile: **138 independently calculated numerical outputs and four operational
metadata outputs**. Both paths persist candidates, seal and natively validate
them, and publish/export full and projected scopes using the installed package.
It is a correctness proof on small synthetic data. It does not qualify scale,
resource budgets, comparative throughput or a production deployment. This run
selects artifact format 2.0.0; optional saved-label/index format 2.1.0 costs and
qualification remain separate.

## Run

Set up the [marked PostgreSQL fixtures](../../tests/fixtures/postgresql/README.md)
and install the current checkout/configure R and JDBC as described in
[conformance](../development/conformance.md). Run from the checkout using a new
output directory whose parent exists:

```sh
python3 tools/test_matched_reference.py --state .local/postgresql \
  --config tools/tracer_fixture_config.R --output-dir .local/matched-reference
# Add --full-matrix for populated generated and adversarial CDM 5.3/5.4/5.5,
# plus an empty CDM 5.5 source. Default: generated, adversarial and empty CDM 5.5.
```

`--admin-host`, `--admin-user` and `--port` configure the fixture-only disposable
serving-role harness. Admin access is used only to create/drop that restricted
role in the already marked fixture database. Source loading and result-store
operations use the fixture owner; generation uses the SELECT-only fixture runner.
No large-tier controls, dependency installation or new CI job are introduced.
Routine Python discovery adds short offline comparator regression tests. The
command accepts only its bundled/generated fixtures, not an institutional CDM
schema. Additional source layouts and capability states need explicit fixtures
before this tool can establish evidence for them.

The source loader creates only new marked `cdm_synthetic_*` schemas. Generated
sources use the [bounded CSV generator](synthetic-cdm.md); adversarial sources
use the existing bundled exact-value/domain fixtures, including null/orphan
persons, duplicates, absent optional columns, legacy aliases, non-finite numbers,
large integers and precise decimal strings. All source identities, compiler SQL
and frozen profile hashes are retained beside the resulting proof. Existing
schemas and output directories are refused. Canonical tiny/GiBleed/SynPUF data
are not reset.

## Independent analysis and shared boundaries

[matched_reference_sql.py](../../tools/matched_reference_sql.py) compiles one
unfused SQL statement per numerical output. Each statement reads source relations;
there are no shared classified source stages across outputs. It does not import
or render production classification/report SQL. Observation intervals use
PostgreSQL `range_agg`/multirange union (PostgreSQL 14 or newer), independently of
the producer's ordered islands. Exact summaries sort individual eligible rows and
use integer nearest-rank indices; repeated values retain their physical frequency.
No floating-point cast, interpolation or distinct-value quantile is used. This
separate compiler is broader than `numericStrategy="reference"`, which switches
only the existing measurement rank kernel while retaining shared production
classification/report logic.

Numeric-summary eligibility counts are local to the allowed summary strata:
known units, and NULL/zero operators for measurement. Unit/operator exclusions
therefore have zero counts within those strata; full-source exclusions are
reported by each domain's `numeric_eligibility_count`. Range-boundary summaries
have a separate frozen rule retaining excluded-unit eligibility-only rows. That
exception does not apply to numeric summaries.

The reference and optimized paths deliberately share the exact row codec,
denominator binding, bounded aggregate writer/store, capability preflight and
provenance serialization, native validation, policy/projection, publication/export
and serving API. These shared boundaries are outside the independent numerical
claim. Physical capabilities and the passport/output ledger are additionally
checked against independent fixture expectations. Existing adversarial Python
oracles check all 138 numerical outputs; generated CSV oracles supply additional
selected checks. These in-memory Python oracles are restricted to small fixtures.

The reference stages only aggregate outputs before persistence. Source queries
are executed independently for each output. Per-statement timeouts, aggregate
row limits, preview source-count limits and a 64 MiB aggregate-stage budget apply.
These are correctness/development bounds, not measured process/database memory
or disk qualification at a representative tier.

## Matched snapshot

A raw-JDBC coordinator holds a PostgreSQL repeatable-read transaction open and
exports its snapshot. Both generation transactions import it as their first
statement and record the same `pg_current_snapshot()` witness. A committed PERSON
insert after capture is deliberately visible to a fresh transaction and absent
from both candidates; it is removed before source revocation/publication.

The optimized adapter runs the installed public/internal generator function
bodies unchanged in a contributor environment whose sole transaction override
imports that snapshot. It changes no namespace binding, analytical helper or
installed runtime file. Before/after implementation identity checks bind installed
R/SQL/definitions to the checkout. The coordinator uses raw JDBC because
DatabaseConnector query helpers can manage transaction state and close the export.

## Complete comparison and output scopes

The comparator requires all 142 dataset/row inventories and compares exact strings,
row keys, states, reasons, support/completeness metadata and denominator references.
No numerical metric or unsupported/empty output is dropped to achieve parity.
Only explicitly factual metadata differs: passport generation timestamps and
execution timing topology/durations/row count. Every timing row is validated before
normalization; missing phases, duplicate operations and fabricated resource
telemetry fail. A different analysis/query topology is recorded, not equated.

Both paths use the same source ID, profile, codec, policies and output scopes:

- Full: all 142 metrics in a restricted publication.
- Projected: PERSON total and gender counts, with all omitted metrics explicitly
  suppressed in the catalogue and their rows/labels absent.

Candidate parity and independent expectations are checked before publication, so
mathematical mismatches fail before export work. Tool source pins are checked
again before any success receipt.

Both candidates are sealed and natively validated after producer source access is
revoked. An explicit synthetic approval callback publishes each scope. The second
path uses compare-and-swap against the first publication revision. Every exported
object's digest/context and every projected row/catalogue/concept/terminology entry
are traversed and checked against the candidate. Root plus one data object per
export are additionally read byte-for-byte through a role without source or
aggregate-store access. The publisher already performs complete native artifact admission; the harness
avoids redundant admissions merely to locate those serving samples. This is a
sampled serving check alongside complete export
parity, not a complete serving transport or UI benchmark.

`results.json` retains snapshots, imported witnesses, native-validation evidence,
publication identities and separate generation/post-generation timings. Timings
include both paths' persistence and complete validation/projection/publication/
export work; fixture preparation, SQL compilation and independent comparisons are
outside those phase measurements. They are diagnostic phase measurements, with
uncontrolled caches and no paired performance qualification or speedup claim.
`oracle.json` is written only after all comparisons and source cleanup succeed.
`fixture-state.json` records disposable store names and original TEMP permission
for failure recovery. Ordinary cleanup attempts exporter, stores and temporary
privilege restoration independently; Python attempts every source cleanup. Process
termination can still require manual recovery from these records. No automatic
reset, cloud allocation, server configuration change or S1/S2 execution occurs.

The optional [resource/phase harness](resource-telemetry.md) enables additional
observer wrappers around unchanged function bodies on a smaller fixture. The
ordinary comparator keeps its transaction-only adapter and numerical behavior.
