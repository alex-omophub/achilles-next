-- Read-only reference for the HANDWRITTEN tiny fixture pack, not production SQL.
-- Literal/identifier tokens are replaced only by tools/check_analysis_scope.py.
-- Day expansion and built-in percentile_disc are independent future-operator oracles.
WITH params AS (
  SELECT {{start_date}}::date AS start_date, {{end_date}}::date AS end_date
), selected AS (
  SELECT jsonb_array_elements_text({{concept_ids}}::jsonb)::integer AS concept_id
), months AS (
  SELECT d::date AS month FROM params,
    LATERAL generate_series(date_trunc('month',start_date::timestamp),date_trunc('month',end_date::timestamp),interval '1 month') d
), observed AS (
  SELECT DISTINCT op.person_id, d::date AS day
  FROM {{schema}}.observation_period op JOIN {{schema}}.person p USING (person_id), params,
    LATERAL generate_series(greatest(op.observation_period_start_date,start_date)::timestamp,
                           least(op.observation_period_end_date,end_date)::timestamp,interval '1 day') d
), eligible AS (
  SELECT m.* FROM {{schema}}.measurement m JOIN {{schema}}.person p USING (person_id), params
  WHERE m.measurement_concept_id IN (SELECT concept_id FROM selected)
    AND m.measurement_date BETWEEN start_date AND end_date
    AND EXISTS (SELECT 1 FROM observed d WHERE d.person_id=m.person_id AND d.day=m.measurement_date)
), classified AS (
  SELECT m.*, CASE
    WHEN value_as_number IS NULL THEN 'missing_numeric'
    WHEN value_as_number::text IN ('NaN','Infinity','-Infinity') THEN 'non_finite_numeric'
    WHEN operator_concept_id IS NOT NULL AND operator_concept_id<>0 THEN 'explicit_operator'
    WHEN unit_concept_id IS NULL THEN 'missing_unit'
    WHEN unit_concept_id=0 THEN 'unmapped_unit'
    WHEN NOT EXISTS (SELECT 1 FROM {{schema}}.concept c WHERE c.concept_id=m.unit_concept_id AND c.concept_id>0 AND c.domain_id='Unit') THEN 'unknown_or_invalid_unit'
    ELSE 'eligible' END AS eligibility,
    (CASE WHEN value_as_number IS NULL THEN '0' ELSE '1' END ||
     CASE WHEN value_as_concept_id IS NULL OR value_as_concept_id=0 THEN '0' ELSE '1' END ||
     CASE WHEN value_source_value IS NULL OR btrim(value_source_value,' ')= '' THEN '0' ELSE '1' END) AS representation,
    CASE WHEN unit_concept_id IS NULL THEN 'null' WHEN unit_concept_id=0 THEN 'zero' ELSE 'id:'||unit_concept_id::text END AS unit_tag,
    CASE WHEN operator_concept_id IS NULL THEN 'null' WHEN operator_concept_id=0 THEN 'zero' ELSE 'id:'||operator_concept_id::text END AS operator_tag
  FROM eligible m
), primary_rows AS (
  SELECT * FROM classified WHERE measurement_concept_id=900000001
), primary_values AS (
  SELECT value_as_number AS value FROM primary_rows
  WHERE eligibility='eligible' AND unit_concept_id=900000101 AND operator_concept_id=0
), stats AS (
  SELECT count(*)::text AS n, sum(value)::text AS sum, min(value)::text AS min, max(value)::text AS max,
    sum(value)::text AS mean_numerator, CASE WHEN count(*)>0 THEN count(*)::text END AS mean_denominator,
    percentile_disc(0.1) WITHIN GROUP (ORDER BY value)::text AS p10,
    percentile_disc(0.25) WITHIN GROUP (ORDER BY value)::text AS p25,
    percentile_disc(0.5) WITHIN GROUP (ORDER BY value)::text AS p50,
    percentile_disc(0.75) WITHIN GROUP (ORDER BY value)::text AS p75,
    percentile_disc(0.9) WITHIN GROUP (ORDER BY value)::text AS p90
  FROM primary_values
)
SELECT jsonb_build_object(
  'person_count',(SELECT count(DISTINCT person_id)::text FROM {{schema}}.person),
  'observed_people',(SELECT count(DISTINCT person_id)::text FROM observed),
  'person_days',(SELECT count(*)::text FROM observed),
  'observed_people_by_month',(SELECT jsonb_object_agg(month::text,n) FROM (
    SELECT m.month,count(DISTINCT d.person_id)::text AS n FROM months m
    LEFT JOIN observed d ON date_trunc('month',d.day::timestamp)::date=m.month GROUP BY m.month) x),
  'records_by_concept',(SELECT jsonb_object_agg(concept_id::text,n) FROM (
    SELECT s.concept_id,count(e.person_id)::text AS n FROM selected s LEFT JOIN eligible e ON e.measurement_concept_id=s.concept_id GROUP BY s.concept_id) x),
  'people_by_concept',(SELECT jsonb_object_agg(concept_id::text,n) FROM (
    SELECT s.concept_id,count(DISTINCT e.person_id)::text AS n FROM selected s LEFT JOIN eligible e ON e.measurement_concept_id=s.concept_id GROUP BY s.concept_id) x),
  'primary_eligibility_nonzero',COALESCE((SELECT jsonb_object_agg(eligibility,n) FROM (SELECT eligibility,count(*)::text AS n FROM primary_rows GROUP BY eligibility) x),'{}'::jsonb),
  'primary_representation_nonzero',COALESCE((SELECT jsonb_object_agg(representation,n) FROM (SELECT representation,count(*)::text AS n FROM primary_rows GROUP BY representation) x),'{}'::jsonb),
  'primary_unit_nonzero',COALESCE((SELECT jsonb_object_agg(unit_tag,n) FROM (SELECT unit_tag,count(*)::text AS n FROM primary_rows GROUP BY unit_tag) x),'{}'::jsonb),
  'primary_operator_nonzero',COALESCE((SELECT jsonb_object_agg(operator_tag,n) FROM (SELECT operator_tag,count(*)::text AS n FROM primary_rows GROUP BY operator_tag) x),'{}'::jsonb),
  'primary_numeric_sorted',COALESCE((SELECT jsonb_agg(value::text ORDER BY value) FROM primary_values),'[]'::jsonb),
  'primary_numeric_summary',(SELECT to_jsonb(stats) FROM stats WHERE EXISTS (
    SELECT 1 FROM primary_rows WHERE unit_concept_id=900000101 AND operator_concept_id=0)),
  'legacy_overlap_join_primary_records',(SELECT count(*)::text FROM {{schema}}.measurement m
    JOIN {{schema}}.observation_period op ON op.person_id=m.person_id AND m.measurement_date BETWEEN op.observation_period_start_date AND op.observation_period_end_date, params
    WHERE m.measurement_concept_id=900000001 AND m.measurement_concept_id IN (SELECT concept_id FROM selected)
      AND m.measurement_date BETWEEN start_date AND end_date)
);
