# PostgreSQL fixture environment

This developer environment provides small, deterministic synthetic OMOP sources and optional public GiBleed sources. It does not run characterization analyses or certify AchillesNext database support.

## Requirements and setup

- A running local PostgreSQL server and an existing administrator role allowed to create a database and login roles.
- PostgreSQL **17.11**, `psql` **17.10**, and Python **3.10 or newer** on `PATH`. The transport is the pinned `psql`/libpq client; no Python or R database driver is installed or used.
- Internet access for the optional first GiBleed download. Tiny fixtures and cached rebuilds work offline.

From the repository root, run:

```sh
python3 tools/postgresql_fixtures.py setup --with-gibleed --check-repeat
```

This creates an isolated database named `achilles_next_fixtures`, loads the sources, checks row counts and independent numerical references, verifies permissions, and rebuilds twice to require identical content IDs. Without `--with-gibleed`, it loads only the six tiny source schemas. It also creates empty SynPUF schemas for later use.

The default administrator connection uses the `/tmp` Unix socket on port 5432 and your current PostgreSQL identity. If needed, append `--host 127.0.0.1 --port 5432 --admin-user YOUR_POSTGRES_ROLE`. Host/port are used when provisioning; later commands use the saved connection services. No existing database or role is taken over unless its fixture ownership marker matches. The script does not change server configuration or authentication rules.

Use the same host/port for repeated `setup` commands with the same state directory. A mismatched saved connection target is rejected.

Credentials, downloaded archives and verification output go into the ignored `.local/postgresql/` directory, with a private directory and credential file permissions. Use `--state-dir /absolute/path/to/local-state` on **every command** to place them elsewhere. Keep the state directory private and outside version control. Never include the `pgpass` file in reports or commits.

If your installed PostgreSQL or client differs from the lock, the command stops before loading data. `--allow-version-mismatch` permits an explicitly unpinned run and records the mismatch; it does not certify that version. Updating the version pins requires rerunning the checks and reviewing the resulting changes.

## Schemas and identities

| Schema | Content | People | Measurements |
|---|---|---:|---:|
| `cdm_tiny_a_53`, `cdm_tiny_a_54`, `cdm_tiny_a_55` | The same edge-case source in each CDM structure | 4 each | 13 each |
| `cdm_tiny_b_53`, `cdm_tiny_b_54`, `cdm_tiny_b_55` | Independent source, overlapping person IDs | 2 each | 2 each |
| `cdm_gibleed_53`, `cdm_gibleed_55` | Optional pinned public GiBleed archives | 2,694 each | 44,053 each |
| `cdm_synpuf_53`, `cdm_synpuf_55` | Empty CDM structures reserved for later loading | Initially 0 | Initially 0 |
| `fixture_results` | Writable scratch results for the runner | — | — |

Source A and B are different populations despite sharing IDs 1 and 2. Sources and CDM versions remain separate schemas. GiBleed is loaded into its native declared versions; no 5.4 GiBleed conversion is performed. Full pinned table/column structures exist even when tables are empty. Schema presence does not mean every clinical module is populated or validated.

- `achilles_next_fixture_owner` owns the sandbox and source schemas and loads fixtures. It is a login role without superuser, database/role creation, replication or RLS bypass privileges.
- `achilles_next_runner` can read source tables and create/write its own result tables in `fixture_results`. It cannot modify source tables or create database-level schemas.
- `PUBLIC` receives no sandbox database or source-schema access. Other databases and roles are untouched.

To open the runner connection using the default state directory:

```sh
PGSERVICEFILE="$PWD/.local/postgresql/pg_service.conf" \
PGPASSFILE="$PWD/.local/postgresql/pgpass" \
psql 'service=achilles_next_runner'
```

Use `service=achilles_next_owner` when you intend to load a source. The names in `pg_service.conf` are connection services; the database roles have the full names listed above.

## Rebuild, verify and load SynPUF later

```sh
# Reset the six tiny schemas and the two GiBleed schemas from the local cache.
python3 tools/postgresql_fixtures.py reset --with-gibleed --check-repeat

# Inspect current fixtures without rebuilding source data.
python3 tools/postgresql_fixtures.py verify --with-gibleed
```

`setup` and `reset` **replace the named generated tiny schemas**, plus GiBleed schemas when `--with-gibleed` is selected. This includes `DROP SCHEMA ... CASCADE`; keep custom objects and dependent views out of generated fixture schemas. Rebuilds use one transaction and a transaction-scoped advisory lock. A failed source load rolls back the source rebuild. Provisioned roles/database may remain after a failed first load, so the command can be retried.

`reset` never touches SynPUF or `fixture_results`. Repeated `setup` preserves existing marked SynPUF schemas. Omitting `--with-gibleed` leaves any existing GiBleed schemas untouched and excludes them from that verification report.

To load SynPUF later, use the owner connection and your ETL/import process, targeting the appropriate **existing** `cdm_synpuf_53` or `cdm_synpuf_55` schema. These schemas already contain the canonical tables and primary keys. Load vocabulary and source metadata appropriate to your selected CDM version. Do not put SynPUF into the generated tiny/GiBleed schemas. This tool does not include a SynPUF ETL or convert between CDM versions.

Existing tables are readable by the runner; default privileges also grant runner SELECT on new tables created by the fixture owner in these source schemas. Tables created by a different loader role need explicit read grants. Fixtures and SynPUF have separate source identities and must be selected explicitly by future analyses.

## Independent expectations and edge cases

[tiny.json](tiny.json) is hand-authored fixture data. All nonzero `900000xxx` IDs are deliberately synthetic labels, not a licensed clinical vocabulary or production mappings. Concept 0 means no matching concept. `999999999` deliberately has no vocabulary row. The small vocabulary is local to each source and has fixed validity dates and version `fixture-1`.

[expected.json](expected.json) retains manually calculated counts, sorted values, discrete quantiles and person/event frequencies. The verifier uses simple SQL counts, PostgreSQL's built-in sorted quantiles, and daily expansion of observation periods as references. It does not call a future AchillesNext interval or distribution implementation.

Source A includes:

- Overlapping January 1–10 and January 5–15 observation periods plus the adjacent January 16–20 period. Their raw lengths sum to 26 days; their union is 20 days. Adding a three-day leap-year period and a single-day period gives **30 raw days and 24 unique person-days**.
- Events on observation starts/ends, one before and one after observation; February 29 and December 31 boundaries; a person with no observation or events.
- Logical duplicate events with separate record IDs; unequal frequencies of **7, 4, 2, 0** records per person; numeric ties, negatives, decimals, zero, null numeric values and a coded result.
- Different units, unit 0 and NULL; a separate less-than operator; unknown and unmapped concepts; NULL and empty optional strings.
- A primary numeric group `[-5, 1, 1, 1, 2.5, 100]`: mean **16.75**, discrete median **1**, and discrete 75th percentile **2.5**. Other units, operators and concepts do not enter that group.
- Exact decimal `9007199254740993.125`, above JavaScript's safe integer range, retained as a PostgreSQL NUMERIC value and checked as text.
- Populated episode/event and metadata examples in 5.4/5.5, and date-valued observation, typed measurement link and vocabulary metadata examples in 5.5. Synthetic field/concept labels exercise storage; they do not establish clinical validity.

Source B has two people and two measurements valued 42, independent of Source A. Both version variants and source contexts are included in verification.

## Reproducibility and limitations

[lock.json](lock.json) pins engine/client versions, upstream commits, DDL SHA-256 values, archive SHA-256 values and GiBleed table row counts. DDL and primary-key files in [ddl/](ddl/) come from the pinned OHDSI CommonDataModel revision. Foreign keys are intentionally not installed, allowing incomplete vocabulary and deliberately unknown concepts.

Tiny fixtures, SynPUF structures and GiBleed 5.5 receive the canonical primary keys. **GiBleed 5.3 is loaded without primary-key enforcement**, preserving its original records: it contains 4,384 extra drug-exposure rows, 2,183 measurement rows and 6 observation rows with repeated primary IDs. The loader does not deduplicate or renumber them. The two empty 5.3 CSV extensions `COHORT` and `COHORT_ATTRIBUTE` are absent from the pinned CDM DDL and are explicitly skipped; populated versions would be rejected. Header-only CSVs for canonical tables remain empty tables. This is an import compatibility boundary, not a CDM-conformance claim.

The local `verification.json` records versions, permissions, per-table row counts and hashes, per-source structure/data content IDs and the combined content ID. It fingerprints all columns and rows, sorts row representations using C collation, and preserves duplicate multiplicity. Execution time, local paths and passwords do not enter the content ID. IDs describe loaded source contents and structure, not analysis definitions or future result-bundle contracts. SynPUF contents and writable results are deliberately excluded from fixture fingerprints.

GiBleed has a small supplied vocabulary, not a complete current Athena vocabulary. It is a public synthetic Synthea-derived example, not a representative performance benchmark or a replacement for the exact edge-case pack. No production data is needed.

Run local tooling tests with:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

To include PostgreSQL integration tests after setup:

```sh
ACHILLES_NEXT_TEST_STATE="$PWD/.local/postgresql" \
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

These tests operate only in the marked sandbox. They check protected-schema refusal, transaction rollback, exact CSV/NUMERIC storage, and preservation of SynPUF and result tables during a tiny-fixture reset. Do not run fixture rebuilds or these tests concurrently with analyses.

For upstream attribution, see [THIRD_PARTY_NOTICES.md](../../../THIRD_PARTY_NOTICES.md).
