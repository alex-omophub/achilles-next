# Third-party material

## OHDSI Achilles definition references

The alpha specification and compatibility metadata refer to [OHDSI/Achilles v1.7.2](https://github.com/OHDSI/Achilles/tree/86741da9c8ad74a5be7785d7b9da24aacfa4c09e) and [development 1.8.0](https://github.com/OHDSI/Achilles/tree/2ee9d46cb4effc952f78a67f52da95627c9e7a01). Attribution: OHDSI Achilles contributors; upstream declares Apache License 2.0. The separate commit/registry/template pins preserve the definition references. Legacy SQL implementation is not vendored here; fixture reference queries and request validation are AchillesNext test/tooling code. These references do not imply executed numerical parity or official endorsement.

## OHDSI CommonDataModel

The PostgreSQL DDL and primary-key scripts in `tests/fixtures/postgresql/ddl/` are copied from [OHDSI/CommonDataModel](https://github.com/OHDSI/CommonDataModel/tree/f6d2738a40af64a8c0dddf23d56680ac29edb52f/inst/ddl), revision `f6d2738a40af64a8c0dddf23d56680ac29edb52f`, for CDM 5.3, 5.4 and 5.5. Attribution: OHDSI CommonDataModel contributors. Its [package metadata](https://github.com/OHDSI/CommonDataModel/blob/f6d2738a40af64a8c0dddf23d56680ac29edb52f/DESCRIPTION) declares Apache License 2.0; that license is included in this repository's [LICENSE](LICENSE).

Scripts retain their upstream content, with terminal whitespace normalized. At runtime, the fixture loader substitutes the schema token. Primary keys are intentionally not applied to GiBleed 5.3; foreign-key scripts are not included or applied. The loader and handwritten tiny fixture data are AchillesNext code and test material.

## OHDSI EunomiaDatasets / GiBleed

The optional loader downloads the unchanged `GiBleed_5.3.zip` and `GiBleed_5.5.zip` archives from [OHDSI/EunomiaDatasets](https://github.com/OHDSI/EunomiaDatasets/tree/3d349dcdd79cc346b8e36eb837e49feffe7f7497/datasets/GiBleed), revision `3d349dcdd79cc346b8e36eb837e49feffe7f7497`. Attribution: OHDSI EunomiaDatasets contributors. Its [LICENSE](https://github.com/OHDSI/EunomiaDatasets/blob/3d349dcdd79cc346b8e36eb837e49feffe7f7497/LICENSE) is Apache License 2.0.

Downloaded archives and data are not vendored in this repository. Their hashes and expected row counts are pinned in the fixture lock file. The source metadata identifies these as synthetic Synthea-derived data; its upstream references are retained in the loaded `cdm_source` tables. Empty cells are loaded as SQL NULL, and two empty legacy 5.3 extension tables absent from the pinned canonical DDL are skipped explicitly. Records, numeric values and IDs are otherwise preserved, including duplicate IDs in the 5.3 archive.
