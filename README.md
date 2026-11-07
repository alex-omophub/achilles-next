# AchillesNext

The [synthetic PostgreSQL-to-React count tracer](docs/development/count-tracer.md)
provides an R entry point, a validated partial aggregate bundle and an exact-count
React view. The [observation tracer](docs/development/observation-tracer.md) adds observed people, monthly people and unique person-days with a Recharts view. The [measurement reference report](docs/development/measurement-reference.md) adds counts, representations, raw units/operators and exact distributions with local terminology. An [optional weighted strategy](docs/development/weighted-quantiles.md) computes the same exact quantiles using cumulative frequencies; the reference remains the default. These are development slices, not a complete alpha report.

After installing the R package, open an existing supported result bundle with
`AchillesNext::viewResults("path/to/bundle")`. The installed [local viewer](docs/viewing/local-viewer.md)
opens automatically with prebuilt React assets; viewing needs no Node, npm or Shiny.

Open-source OMOP data characterization and exploration with reproducible aggregate results and an embeddable analytical UI.

**R package name:** `AchillesNext` · **Repository:** `achilles-next` · **License:** Apache-2.0

The [internal saved-result transports](docs/development/saved-transports.md)
provide verified artifact/database page traversal with bounded resources,
context-bound cursors and cooperative cancellation. The experimental
[native semantic providers](docs/development/semantic-results.md) add approved
metric discovery and exact saved-row selection with denominator/eligibility
evidence. Production UI remains separate work.
Exact [saved-concept lookup](docs/development/saved-concepts.md) preserves IDs and
explicit missing-name states. Opt-in artifact format 2.1.0 adds approved saved names
and bounded prefix search; original 2.0.0 exports retain unavailable names.

## Development status

AchillesNext is in early development. The R package installs from source and
computes synthetic PostgreSQL person/observation counts and a bounded measurement
reference report, with an installed local React viewer. A separate PostgreSQL
batch generator now produces complete restricted core candidates with saved metadata.
Checked full-refresh execution is available; production host integration remains under development.
See the count-tracer guide for the
tested fixture scope, installation and limitations.

## Intended capabilities

- Generate descriptive summaries of an OMOP CDM within the institution.
- Preserve metric definitions, populations, units, availability states and provenance alongside aggregate results.
- Open generated results through a prebuilt viewer.
- Reuse analytical views within other applications, including ATLAS3.

## Development

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution and Git workflow. Source code, tests and documentation explaining package behavior belong in this repository.

The [PostgreSQL fixture environment](tests/fixtures/postgresql/README.md) provides reproducible synthetic CDM 5.3/5.4/5.5 sources, optional pinned GiBleed 5.3/5.5 datasets, and separate empty schemas for later SynPUF loading. This is developer test infrastructure; the R package and analysis engine are still under development.

The [alpha measurement profile](docs/analysis/alpha-profile.md) specifies 15 bounded outputs with explicit observation, representation and exact-distribution semantics. Its manifests and read-only fixture references can be checked now; the production analysis engine is not implemented yet.

The [v1 result/provider/embed contracts](docs/contracts/v1.md) add versioned schemas, a complete synthetic bundle, TypeScript interfaces and executable conformance checks for Generation → View and host embedding.

The [synthetic PostgreSQL reference benchmark](docs/benchmark/reference.md) checks pinned legacy counts/distributions against an independent oracle and captures separate execution/export timings on fixture and deterministic cardinality workloads.

The contributor [saved-representation experiment](docs/benchmark/saved-representation.md)
compares tree and flat-index routing over identical precomputed pages. The
[validator boundary](docs/development/validator-boundary.md) describes complete
admission, bounded verified reads and independent numerical checks.

The experimental [core batch planner](docs/development/batch-planner.md) enumerates
all 142 frozen core results across 51 dependency nodes, with explicit shared-input
candidates and exact grains. It plans full-history/all-concept work; complete core
generation is available through the [complete candidate generator](docs/development/core-characterization.md); checked full-refresh execution is available. A small synthetic harness compares
reference and transaction-private materialization with independent numerical oracles.

The separate [registered analysis example](docs/development/registered-analyses.md)
demonstrates a two-report contribution through generation, approval and saved
readback. It preserves the core inventory and does not complete core generation.

`generatePopulationObservationBaseline()` computes and persists seven population
and twelve observation-period outputs from PostgreSQL sources. The
[baseline guide](docs/development/population-baseline.md) explains exact semantics,
worker permissions and saved readback without CDM access. Its building release
leaves the other 123 core outputs explicitly ungenerated and cannot be published
as a complete core result.

`generateDomainBaseline()` adds the eight-domain and density baseline: 100 frozen
outputs with the same 19 population dependencies, for 119 of 142 outputs accounted
for. The [domain guide](docs/development/domain-baseline.md) covers batch generation,
exact concept/month/year selection and paged raw concept catalogues without CDM
access. Conditional unsupported fields retain explicit states. These restricted building releases cannot be
published as complete core results or opened in the v1 tracer viewer.

`generateMeasurementBaseline()` adds all nineteen whole-source measurement
outputs, bringing the restricted baseline to 138 of 142 outputs. The
[measurement baseline guide](docs/development/measurement-baseline.md) describes
representations, units/operators, exact numeric and reference-range summaries,
and saved readback. That entry point retains its partial baseline boundary. The separate
[complete candidate generator](docs/development/core-characterization.md) adds the four real metadata outputs and supports sealing/native validation. Full refresh execution is described below; an
[integrated synthetic conformance proof](docs/development/conformance.md#compose-complete-refresh-with-approved-publication)
covers approval, full/reduced export and serving-only page reads. Production
qualification remains in progress. The earlier synthetic measurement tracer and its viewer stay separate.

The [refresh contracts](docs/development/refresh.md) add source-free
`planCharacterizationRefresh()` requests and a read-only `inspectResultStore()`
version probe. `executeCharacterizationRefresh()` recomputes a checked plan into
a fresh complete candidate, retaining the previous publication through failures.
Sealing, validation, institutional approval and CAS promotion remain explicit.
The [operations guide](docs/development/store-operations.md) documents controlled
overlap/CAS proofs, restart boundaries and versioned upgrade/retention procedures.

An [internal saved-selection model](docs/development/saved-selection.md) describes
all 142 report/filter grains and rejects requests that would require unsaved
combinations. Approved lazy transports and concept-name discovery remain under
development; the model reads no source data and submits no generation jobs.

The [ATLAS3 integration boundary](docs/integration/atlas3.md) records a native v3.0.0 fixture proof, its lifecycle constraints and the experimental authenticated HTTP result transport. A production viewer/host adapter is still under development.

## Relationship to OHDSI

AchillesNext is an independent successor project. OHDSI Achilles and other ecosystem projects retain their own identities and attribution. Existing functionality is not claimed as implemented or certified here.

## Durable runs and publication

The optional [durable execution API and CLI](docs/development/execution-ledger.md)
persist a bounded plan, operation states and measured telemetry for synthetic
measurement runs. Inspect records after process exit without reconnecting.

The optional [durable run API](docs/development/execution-ledger.md) now generates
all fifteen alpha outputs for marked synthetic PostgreSQL fixtures.
[Approved publication](docs/development/publication.md) validates immutable
restricted/distributable releases before switching a local current pointer.
[Cancellation and isolated recovery](docs/development/recovery.md) record targeted
PostgreSQL cancellation and linked, idempotent attempts; unknown source identity
forces recomputation. Institutional execution, general anonymization and cross-run reuse remain outside
this implementation.

## License

See [LICENSE](LICENSE) for the Apache License 2.0. Preserve applicable notices when reusing third-party code.
