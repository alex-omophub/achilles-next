# Bounded synthetic CDM previews

The contributor generator writes invented OMOP source tables as deterministic CSV
files using the repository's pinned PostgreSQL CDM 5.3, 5.4 or 5.5 DDL. It needs
only Python's standard library. It is a small correctness/development fixture,
not a clinical dataset, full CDM conformance test or representative-scale workload.

## Generate and verify files

Run from the package checkout. The output directory must be new and its parent
must exist. No database connection is made by these commands.

```sh
mkdir -p .local
python3 tools/generate_synthetic_cdm.py build --output-dir .local/cdm-preview \
  --cdm-version 5.5 --people 20 --events 1000 --seed 2026110801
python3 tools/generate_synthetic_cdm.py verify --output-dir .local/cdm-preview
```

Hard limits are **1,000 people, 10,000 combined clinical events and 32 MiB of CSV
bytes**, with bounded histogram and manifest sizes. Events require people; an
empty source uses zero for both. Invalid controls and larger tiers are refused
before output creation. No flag overrides these limits or launches S1/S2 work.
Failed or cancelled builds remove only the new directory they created. Existing
output is never reset or overwritten. Verification takes its parameters from the
manifest and rejects parameter overrides, extra files, symlinks, rehashed data
changes and input/DDL drift.

`manifest.json` is written only after every CSV completes. It pins the generator,
[recipe](../../tests/fixtures/synthetic-cdm/recipe.json), selected DDL, unapplied
primary-key DDL, fixture lock and frozen analysis profile. Each table has a CSV
hash/byte count, physical row count, ordered columns, row byte-width extrema,
NULL counts, named marginal histograms and a declared joint-histogram projection.
Row widths describe encoded CSV bytes, not PostgreSQL heap/index/WAL sizes or a
calibrated storage projection. Those require separate database measurements.
Verification replays the bounded recipe and checks exact manifest/file bytes.
This is reproducible synthetic source identity, not institutional approval or a
permission to reuse analytical outputs across changing inputs.

## Data recipe and limits of interpretation

The default 1,000 events are apportioned as follows:

| Domain | Physical rows |
|---|---:|
| Condition |120|
| Drug |180|
| Procedure |80|
| Visit |60|
| Device |20|
| Observation |100|
| Death |1|
| Specimen |19|
| Measurement |420|

Largest-remainder apportionment preserves the requested combined count at smaller
sizes. A fixed SplitMix64 row-index function makes output independent of process
hash randomization, output directory and consumer buffering. There is no
whole-event list or person-by-day matrix in the generator. Statistics use bounded
counters; these bounds are not a measured process-RSS guarantee.

The preview history is January–March 2020, including leap day. People have valid,
overlapping, adjacent, reversed or absent observation periods. Events include
observed and outside-union dates, unknown concept zero, hot concept/person
schedules, 16 known units, missing/zero/unrecognized units, NULL/zero/explicit
measurement operators, exact decimal strings, missing/non-finite numerics and
reference-bound cases. CSV preserves NULL, empty strings, ASCII spaces, tabs,
quotes and backslashes distinctly. Device quantity follows the pinned integer
column type; other numeric columns retain their declared types.

Every 100th clinical row repeats the preceding complete source row, including its
source record ID. The manifest reports `floor(domain_rows / 100)` scheduled
duplicates, with realized small-preview fractions rather than an assumed exact
1% at every size. Unit and concept cardinalities, hot schedules and conditional
distributions are synthetic test choices, not empirical OMOP population models.

Table types and NOT NULL constraints are installed. **Primary and foreign keys
are deliberately not installed**, so repeated IDs and bag duplicates survive.
Reference concepts and vocabulary metadata are invented. This fixture is not a
claim of complete vocabulary/FK/PK or clinical validity. Existing adversarial
fixtures cover nullable required-field defects that locked NOT NULL columns cannot
represent. Scaling, wider history, real vocabulary fanout, calibration and any
large-tier resource authorization remain separate work.

## Optional PostgreSQL and installed-producer proof

After [fixture setup](../../tests/fixtures/postgresql/README.md), install the current
package and configure its R library/JDBC directory as in
[conformance](../development/conformance.md). Then use a new output directory:

```sh
python3 tools/test_synthetic_cdm.py --state .local/postgresql \
  --config tools/tracer_fixture_config.R --output-dir .local/cdm-preview-proof
# Add --full-matrix for populated 5.3/5.4/5.5 plus empty 5.5.
```

The proof refuses any database/owner/marker except the existing synthetic fixture
sandbox. It replays and freezes the input in a private temporary copy, verifies
the DDL pin again, and creates only new `cdm_synthetic_*` schemas. Existing schemas
are refused even if marked; there is no reset path. Frontend COPY loads the exact
bounded files inside one transaction. The fixture runner receives source SELECT
access. Cleanup checks exact ownership/marker and drops only the generated source
schemas; canonical tiny/GiBleed/SynPUF sources are untouched.

The installed generator then creates all **142 core outputs** in a disposable
restricted store. After source access is revoked from the producer principal,
the owner seals and natively validates each release. No approval, publication or
current-pointer promotion is performed. This does not demonstrate a serving/UI
workflow; use the separate publication conformance suite for that boundary.

An independent small oracle reads the CSV files rather than generator functions.
It checks source counts and duplicate bags, PERSON/demographic counts, all nine
domains' full-scope all-recorded/observed capture counts, density, explicit day-set
observation coverage and exact measurement summaries using sorted Decimal values
and integer quantile ranks. These **25 selected metrics** complement complete
native validation; they are not the full 142-output independent execution
comparator required for performance qualification. This oracle is intentionally
in memory and hard-capped to small previews; do not use it for large data.

Routine Python discovery runs `tests/test_synthetic_cdm_generator.py` offline for
determinism, bounds, duplicate/CSV facts, cancellation, checksum/symlink/input-race
rejection and schema safeguards. The PostgreSQL proof is opt-in; this change adds
no CI job, dependency installation or routine full-profile generation.
