# PostgreSQL and saved-result support

AchillesNext runs the `core-characterization-v2` profile on PostgreSQL. The reference suite exercised PostgreSQL 17.11 with tiny, synthetic physical schemas for OMOP CDM 5.3, 5.4 and 5.5. It compared 138 numerical outputs with independent expectations and checked four metadata outputs covering the source passport, physical capabilities, output status and execution timing. Each run validates all 142 dataset entries, including conditional reports whose inputs are unavailable.

## Generation from physical CDM schemas

The table describes the installed fixture columns and grants. In an institution’s CDM, the generator probes the actual schema and permissions.

| Populated fixture | Visit admission and discharge fields used | Observed capabilities and saved results |
|---|---|---|
| 5.3 | `admitting_source_concept_id`, `discharge_to_concept_id` | 139 computed datasets. Device unit, procedure end precision and specimen visit link returned `unsupported` with schema-absence reasons. |
| 5.4 | `admitted_from_concept_id`, `discharged_to_concept_id` | 141 computed datasets. Specimen visit link remained unsupported. The physically present CDM_SOURCE table returned `inaccessible` with `capability.select_denied`. |
| 5.5 | `admitted_from_concept_id`, `discharged_to_concept_id` | All 142 datasets computed. The observation date-value field was available. CDM_SOURCE and VOCABULARY were absent in this fixture, and their releases remained unknown. |

Two additional 5.5 cases cover empty and extended observation. An empty CDM_SOURCE table returned `available_empty`; the 138 numerical datasets retained `empty_source` and the all-person count retained an exact zero. Extending observation beyond the latest recorded event preserved zero-count calendar cells.

For the pinned public GiBleed 5.3 and 5.5 datasets, PostgreSQL 17.11 verification covered import and fixture reference checks only.

## Publication and saved reads

Each populated version passed full and reduced publication checks. The suite compares exported rows with the generated candidate, verifies referenced denominators and reads approved output with source access denied. In the reduced fixture, the disclosure policy and dependency checks leave person count and gender count. The ordinary CI matrix generates all five cases and publishes the first populated case (5.3). Separate runs exercise publication on populated 5.4 and 5.5 inputs.

From the repository root, use an installed checkout, the marked PostgreSQL fixtures and the configured JDBC driver. Run the commands serially. Each command writes to a fresh child directory. The fixture administrator defaults to the local socket on port 5432. [Contributor setup](conformance.md#run-the-contributor-checks)

```sh
set -e
out="$(mktemp -d)"
python3 tools/test_core_characterization.py --full-matrix --with-publication \
  --state .local/postgresql --config tools/tracer_fixture_config.R \
  --output-dir "$out/full-matrix"

for version in 5.4 5.5; do
  python3 tools/test_core_characterization.py --with-publication --publication-version "$version" \
    --state .local/postgresql --config tools/tracer_fixture_config.R \
    --output-dir "$out/publication-$version"
done
```

Public provider tests distinguish a missing saved row (`not_saved`), a suppressed report with no rows, an unavailable value and a recorded zero. A request for an unsaved time grain returns `additional_batch_job_required` without querying the CDM. Wrong-context cursors, inconsistent denominator links and revoked access each fail explicitly. The wire tests preserve the integer string `9007199254740993` and reject unsafe numeric representations. Imported fixture checks reject unsupported document versions and altered artifacts. [Saved provider checks](conformance.md#compatibility-and-safety-matrix)

## Presentation from saved outputs

| Saved format | Verified viewing path |
|---|---|
| v1.0 tracer and v1.1 complete measurement bundles | Installed R `viewResults()` opens supported v1 bundles, including restricted and distributable v1.1 releases. |
| v2.0.0 and v2.1.0 publications | The installed R viewer and installed React workspace read approved results. React and Vue hosts can mount the same workspace, report or chart. |
| Released ATLAS3 v3.0.0 sidebar | Chrome 158 with a same-origin fixture gateway and generated v2.0.0 publications. For all 142 metrics on a 5.3-generated publication, the first displayed page and the dataset and selection states matched standalone. A second 5.4-generated publication exercised source switching. Both used saved results with access to the source database disabled. |

The ATLAS3 trial used synthetic sign-in. Other host releases, institutional identity systems, browser policies and SQL engines require separate verification. [Installed format guide](../viewing/embedded-workspace.md#choose-a-viewer-for-the-saved-result) · [ATLAS3 deployment coverage](../integration/atlas3.md#deployment-coverage)
