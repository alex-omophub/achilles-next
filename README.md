# AchillesNext

The [synthetic PostgreSQL-to-React count tracer](docs/development/count-tracer.md)
provides an R entry point, a validated partial aggregate bundle and an exact-count
React view. It is development functionality, not a complete alpha report.

After installing the R package, open an existing count-tracer bundle with
`AchillesNext::viewResults("path/to/bundle")`. The installed [local viewer](docs/viewing/local-viewer.md)
opens automatically with prebuilt React assets; viewing needs no Node, npm or Shiny.

Open-source OMOP data characterization and exploration with reproducible aggregate results and an embeddable analytical UI.

**R package name:** `AchillesNext` · **Repository:** `achilles-next` · **License:** Apache-2.0

## Development status

AchillesNext is in early development. The R package installs from source and
computes a synthetic PostgreSQL person-count tracer, with an installed local
React viewer. The complete analytical profile and production
host integration remain under development. See the count-tracer guide for the
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

The [ATLAS3 integration boundary](docs/integration/atlas3.md) records a native v3.0.0 fixture proof, its lifecycle constraints and the experimental authenticated HTTP result transport. A production viewer/host adapter is still under development.

## Relationship to OHDSI

AchillesNext is an independent successor project. OHDSI Achilles and other ecosystem projects retain their own identities and attribution. Existing functionality is not claimed as implemented or certified here.

## License

See [LICENSE](LICENSE) for the Apache License 2.0. Preserve applicable notices when reusing third-party code.
