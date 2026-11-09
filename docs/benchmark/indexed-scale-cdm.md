# Indexed synthetic source probes

[scale_cdm.py](../../tools/scale_cdm.py) describes larger deterministic source
workloads and writes bounded CSV slices at arbitrary row offsets. It does not
generate or load a full tier, connect to a database or authorize resource use.
The existing [small preview generator](synthetic-cdm.md) and its limits are
unchanged. These tools create invented test data, not clinical distributions.

## Plan and probe

Run from the checkout root, with a new output location outside the checkout:

```sh
mkdir -p ../indexed-source-probes
python3 tools/scale_cdm.py plan --tier S2 --cdm-version 5.5 \
  --output-file ../indexed-source-probes/plan.json
python3 tools/scale_cdm.py probe --tier S2 --cdm-version 5.5 \
  --table measurement --start 41999990 --rows 10 \
  --output-dir ../indexed-source-probes/measurement-tail
python3 tools/scale_cdm.py verify \
  --output-dir ../indexed-source-probes/measurement-tail
```

The example renders only the final ten physical measurement rows in the logical
S2 table; it does not visit the preceding rows. Offsets are zero-based and the
end is exclusive. `--cdm-version` supports 5.3, 5.4 and 5.5 using the locked
physical DDL. The `plan` and `probe` commands require an explicit `--tier`.
There is no full-tier `build`, database loader or hidden large-row override.

One probe is restricted to 10,000 rows, 8 MiB CSV bytes and a 30-second rendering
deadline checked while emitting rows. It samples a 16 MiB free-space floor before
creation and periodically during writing. This floor is not a storage reservation
or quota. Output paths must be new and outside the checkout. Exceptions and
Ctrl-C retain partial files with `failed.json`; a complete probe has `probe.json`
and one CSV. Forced process termination may leave an incomplete directory without
a failure record. Incomplete directories are refused by `verify`.

The receipt binds the row window, content hash, physical column list through the
DDL pin, measured row widths/null counts and all generator/recipe/profile inputs.
Verification regenerates only that bounded window, compares the canonical
receipt and CSV hash, and refuses drift, unexpected files or symlink payloads.
`kind=indexed_scale_csv_probe` identifies a slice, not a complete CDM manifest.
The existing preview loader cannot import these probe directories.

## Declared workload and additional source work

The [recipe](../../tests/fixtures/synthetic-cdm/scale-recipe.json) defines:

| Logical tier | People | Clinical rows | Standard concepts per domain | Concept-table rows |
|---|---:|---:|---:|---:|
| S1 |100,000|5,000,000|5,000|1,485,017|
| S2 |1,000,000|100,000,000|50,000|14,850,017|

S2 clinical rows are 12M condition, 18M drug, 8M procedure, 6M visit, 2M device,
10M observation, 0.1M death, 1.9M specimen and 42M measurement. The plan also counts
people, observation periods, vocabulary/care-site/source metadata and the complete
declared concept table. S2 has 17,050,021 auxiliary rows beyond its 100M clinical
rows. Vocabulary rows are source work and must enter later capacity projections.
These numbers describe the logical recipe; they are not generated row counts.

Each domain has disjoint standard concept IDs, 32 possible source concepts per
standard concept and 16 shared known unit concepts. Concept rows are indexed too;
even the final source-concept row requires no full vocabulary list in memory.
IDs fit signed 32-bit concept columns. Person/event IDs and dates are independent
of the requested window. Sampling and partitioning do not reseed the stream.

Every 100th physical clinical row repeats the preceding row including its source
ID. The duplicate remains identical when a window starts on that row. The recipe
schedules 80% of base rows onto the first 20% of concepts, with explicit zero-concept
rows; remaining rows use the other concepts. Person assignment concentrates four
of five base rows on the first 20% of people, with the remainder drawn from all
people. Actual marginal frequencies therefore differ from the scheduled branch
fractions, especially after zero/missing states. Observation intervals include
overlap, adjacency, missing periods and invalid ranges. Measurement representation
and missing/operator/non-finite cases retain the existing adversarial row rules.
The history spans 2010–2024. The plan records these schedules explicitly.

## Evidence boundary

Every plan/probe sets `full_tier_generated=false` and `qualifying=false`;
plans also set `execution_enabled=false`. Probe success proves reproducible
bounded source slices. It does not prove full-source referential integrity,
clinical plausibility, end-to-end analytical parity, observed full-tier
histograms, disk amplification or a performance/resource budget. Sample row
widths do not establish a complete generation/publication storage projection.

Full streaming materialization, checkpoint/restart and registered resource/stop
controls are subsequent work. Larger runs still require allocated resources,
scoped observer access, calibrated capacity/headroom and the matched analysis
and publication protocol. No shared-host action follows from producing a plan.
