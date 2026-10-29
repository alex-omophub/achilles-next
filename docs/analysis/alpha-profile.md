# Alpha measurement profile

[alpha-measurement-v1.json](../../inst/analysis/alpha-measurement-v1.json), revision `1.0.0`, specifies a finite PostgreSQL profile over canonical CDM 5.3/5.4/5.5 fixtures. The frozen manifest specifies the complete analytical behavior. The partial [count](../development/count-tracer.md) and [observation](../development/observation-tracer.md) development tracers implement five outputs on marked synthetic fixtures and have an installed local viewer. The complete analysis engine and embed runtime remain under development; implementation-status fields in this frozen semantic specification are historical, not a runtime capability report.

## Request boundary

Select exactly one configured source, **1–10 unique measurement concept IDs**, an explicit inclusive date window spanning at most **120 touched calendar months**, and a versioned disclosure policy. There is no implicit descendant expansion. Concept 0 is included only when selected. Unknown nonzero measurement concepts remain under their recorded IDs.

Only restricted institutional output is specified. [valid-request.json](../../tests/fixtures/analysis/valid-request.json) is a synthetic example. Source/policy IDs are references, not authorization: a future executor must resolve the actual source and approved policy. The synthetic policy cannot authorize live data. Credentials are outside the request.

Every complete alpha run requests these **15 outputs**, each with metric version `1.0.0`:

| ID | Grain and meaning |
|---|---|
| `source.passport` | Source/snapshot/data release, declared CDM and observed schema evidence, vocabulary, profile/metric and run identities |
| `source.capabilities` | One row per declared table/column probe, with presence, accessibility and reasons |
| `person.count` | Distinct all-source people, independent of the measurement window |
| `observation.person_count` | Distinct people with at least one observed day in the window |
| `observation.monthly_person_count` | Distinct observed people in each clipped calendar month |
| `observation.person_days` | Unique observed person-days in the window |
| `measurement.record_count` | Eligible physical rows per selected concept, over the window and each month |
| `measurement.person_count` | Distinct tested people per concept/period, with matching observed-person denominator |
| `measurement.representation_count` | Eight numeric/coded/source-result-text presence combinations per concept/period |
| `measurement.unit_count` | Counts by exact raw unit: NULL, 0 or nonzero ID |
| `measurement.operator_count` | Counts by exact raw operator: NULL, 0 or nonzero ID |
| `measurement.numeric_eligibility_count` | Inclusion/exclusion reasons reconciling to record counts |
| `measurement.numeric_summary` | Exact window-level summaries per concept, known unit and raw operator |
| `execution.output_status` | Availability and reason for every requested output |
| `execution.timing` | Measured phase durations and unavailable telemetry |

The manifest defines fields, grain, population/window, dimensions, dependencies, denominator, units/operators, zero/NULL/suppression behavior and precision for each output. A partial development run must not be labelled a complete alpha profile. Physical strategy changes preserve metric versions only when semantics remain equivalent.

## Observation and event membership

Use `measurement_date` and Gregorian DATE boundaries, with inclusive window/observation endpoints. Do not derive dates from datetimes or apply timezone conversions. Merge overlapping and adjacent intervals **within each person**, then clip to the window/month; retain partial edge months.

People belong to the selected PERSON source. Null/duplicate person IDs, malformed/orphan observation periods, or selected in-window orphan measurement rows fail dependent outputs with reasons. Missing/inaccessible prerequisites do not silently become fewer events or zero counts.

A measurement row is eligible when its concept/date is selected and its date belongs to at least one valid observation period for its person. Membership counts a source row once despite overlapping periods. Physical duplicates, including repeated measurement IDs, remain separate recorded rows. Distinct people are deduplicated independently.

In the small Source A fixture, the primary concept has **8 eligible records**; joining raw observation periods produces **11 rows**. The numeric group excludes an explicit-comparator record and retains **6 numeric records**. These quantities must remain distinguishable.

Monthly people are not additive across months or concepts. Tested-person fractions use the **same-period observed-person denominator**. The all-source `person.count` is context, not a substitute denominator. Descriptive counts do not establish population prevalence or joint cohort eligibility.

## Representation and numeric eligibility

The representation flags are orthogonal:

- Numeric present: `value_as_number IS NOT NULL`, including non-finite values later excluded from summaries.
- Coded present: `value_as_concept_id` is neither NULL nor 0, including unmapped nonzero values.
- Source text present: `value_source_value` is nonempty after trimming U+0020 spaces. This is distinct from `measurement_source_value` and standardized results.

Units/operators use raw tags `null`, `zero` or `id:<integer>`. Numeric summaries require a positive unit ID resolving uniquely to a local `Unit`-domain concept. They perform no unit conversion or inference.

Summaries accept **NULL or 0 operators**, keeping those strata separate and labelled **“no explicit comparator.”** This does not prove a result is uncensored. Every nonzero operator, including explicit equality codes, is excluded from this numeric profile and remains visible in counts. Broader rules need a reviewed profile revision.

Eligibility is first-match, so each record gets exactly one reason:

1. Missing numeric value.
2. Non-finite numeric value (NaN or infinity).
3. Explicit nonzero operator.
4. Missing unit (NULL).
5. Unmapped unit (0).
6. Unknown/invalid unit.
7. Eligible finite numeric value.

A missing numeric value with a missing unit counts under `missing_numeric`; its unit is still visible in the unit output.

## Exact statistics

Summary strata are concept × known unit × exact raw operator over the request window. The denominator is numeric **records**, not people. Retain every repeated value's frequency.

Return `n`, `sum`, `min`, `max`, exact mean numerator/denominator, and discrete `p10`, `p25`, `p50`, `p75`, `p90`. For sorted values `x[1..n]`, percentile `a/b` is **`x[ceil(a*n/b)]`**. Do not interpolate, floor the rank or approximate the quantile.

Counts are exact integer strings. Numeric statistics are exact decimal strings, with rational mean `(sum, n)`. Do not cast to binary FLOAT or silently coerce through JavaScript Number. Source A's `[-5, 1, 1, 1, 2.5, 100]` gives sum `100.5`, mean `100.5/6 = 16.75`, median `1` and p75 `2.5`. The precision case retains `9007199254740993.125` exactly.

Standard deviation, monthly numeric summaries and frequency-table export are outside this profile. Frequency inputs remain restricted scratch. Charts may use labelled approximate coordinates backed by exact table values; those coordinates never replace metric values.

## Empty, unavailable and suppressed results

Concept/period counts and representation/eligibility cells are dense, with known zero cells after successful evaluation. Unit/operator outputs contain observed raw tags only; their absence cannot be interpreted without completion state.

- An accessible empty PERSON source has count 0 and `empty_source` context.
- No observed people/days gives zero counts with `empty_population` context. A fraction with denominator 0 is undefined.
- Observed people without selected events yield legitimate zero event counts.
- An observed known-unit/allowed-operator stratum without numeric values has `n=0`; every statistic, including sum/mean, is NULL. Unobserved strata are not fabricated.
- Unsupported, inaccessible, failed, not-requested or stale outputs retain reasons and no numeric substitute.
- Suppression hides every numeric payload, including counts/extrema, with a policy reason. Institutional thresholds are not invented by this profile.

After prerequisite failures are ruled out, `empty_source` takes precedence when PERSON is empty; `empty_population` describes a metric-specific empty eligible set in an otherwise populated source. Failed, inaccessible or unsupported required computation prevents complete-alpha publication. Verified empty outputs and policy-approved suppression can be complete. Missing optional metadata stays explicitly unknown.

The result/provider contract will define exact wire shapes and publication rules separately. These semantic distinctions must survive it. This profile grants no export authorization or anonymity guarantee.

## CDM and legacy scope

The bounded numerical profile applies to 5.3/5.4/5.5 fixtures. Optional probes expose newer fields/tables; alpha does not analyse episodes, specimens, date-valued observations, mapping provenance or packs. Presence, population, analysis and clinical interpretation are distinct coverage claims.

[legacy-baselines.json](../../inst/analysis/legacy-baselines.json) separately pins published [Achilles v1.7.2](https://github.com/OHDSI/Achilles/tree/86741da9c8ad74a5be7785d7b9da24aacfa4c09e) and audited [development 1.8.0](https://github.com/OHDSI/Achilles/tree/2ee9d46cb4effc952f78a67f52da95627c9e7a01). Both registries have 294 registrations, with 194 defaults. Matching legacy IDs/titles do not establish equivalence:

- Analysis 1 shares the all-source distinct-person definition, subject to integrity prerequisites.
- Analysis 117's fixed sparse calendar becomes an explicit bounded dense calendar.
- Analysis 1801's observation join can multiply events; the new definition uses membership.
- Analysis 1815 casts to FLOAT and does not stratify by operator; new summaries preserve decimals and explicit eligibility.
- Analyses 1811/1819 count numeric **or coded** results despite numeric-focused registry wording.
- Analysis 1821 counts all-source missing numeric values without alpha observation/window rules.

These are definition comparisons, not executed parity claims. Alpha IDs are independent of legacy IDs. Future imports must preserve original definitions/precision and unknown provenance instead of relabelling historical values as native results.

## Validation

```sh
python3 tools/check_analysis_scope.py --request tests/fixtures/analysis/valid-request.json
python3 -m unittest discover -s tests -p 'test_analysis_scope.py' -v
```

The checker validates manifest hashes, semantic completeness/dependencies and request bounds. Extra/joint filters, implicit expansion, unsafe IDs, unbounded windows and unrestricted output are rejected. It does not execute the production profile or authorize a source.

After [fixture setup](../../tests/fixtures/postgresql/README.md), check reference answers:

```sh
python3 tools/check_analysis_scope.py --postgresql-state "$PWD/.local/postgresql"
```

Use your saved state path if different. Five hand-calculated cases run read-only across three CDM variants, plus 16 in-memory numeric edge records, using daily expansion and built-in sorted percentiles. The command does not rebuild fixtures or write database tables. It writes a local report next to the connection state. These are independent reference answers for future operators, not production-engine or full legacy-template certification.
