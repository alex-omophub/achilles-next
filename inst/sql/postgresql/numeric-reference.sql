, ranked_reference AS (
  -- Portable reference: sort every eligible physical value, retaining duplicates.
  SELECT measurement_concept_id,unit_concept_id,raw_operator_tag,value_as_number AS value,
    ROW_NUMBER() OVER (PARTITION BY measurement_concept_id,unit_concept_id,raw_operator_tag ORDER BY value_as_number) AS rank_index
  FROM classified WHERE eligibility_reason='eligible'
), summaries AS (
  SELECT jsonb_build_object('measurement_concept_id',g.measurement_concept_id,'unit_concept_id',g.unit_concept_id,
    'raw_operator_tag',g.raw_operator_tag) AS dimensions,
    jsonb_build_object('n',COALESCE(f.n,0)::text,'sum',f.total::text,'mean_numerator',f.total::text,
      'mean_denominator',CASE WHEN f.n>0 THEN f.n::text END,'min',MIN(r.value)::text,'max',MAX(r.value)::text,
      'p10',(MAX(r.value) FILTER (WHERE r.rank_index=CEIL(f.n/10)))::text,
      'p25',(MAX(r.value) FILTER (WHERE r.rank_index=CEIL(f.n/4)))::text,
      'p50',(MAX(r.value) FILTER (WHERE r.rank_index=CEIL(f.n/2)))::text,
      'p75',(MAX(r.value) FILTER (WHERE r.rank_index=CEIL(f.n*3/4)))::text,
      'p90',(MAX(r.value) FILTER (WHERE r.rank_index=CEIL(f.n*9/10)))::text) AS values
  FROM summary_groups g LEFT JOIN frequency_totals f USING(measurement_concept_id,unit_concept_id,raw_operator_tag)
  LEFT JOIN ranked_reference r USING(measurement_concept_id,unit_concept_id,raw_operator_tag)
  GROUP BY g.measurement_concept_id,g.unit_concept_id,g.raw_operator_tag,f.n,f.total
)
