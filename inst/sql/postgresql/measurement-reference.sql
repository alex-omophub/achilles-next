, periods AS (
  SELECT 'window'::text AS period_kind, window_start AS period_start, window_end AS period_end FROM params
  UNION ALL SELECT 'month', GREATEST(d::date,window_start), LEAST((d+interval '1 month')::date-1,window_end)
  FROM params, LATERAL generate_series(date_trunc('month',window_start::timestamp),
    date_trunc('month',window_end::timestamp),interval '1 month') d
), base AS (
  SELECT s.concept_id, p.*,
    jsonb_build_object('measurement_concept_id',s.concept_id,'period_kind',p.period_kind,
      'period_start',p.period_start::text,'period_end',p.period_end::text) AS dimensions
  FROM selected s CROSS JOIN periods p
), counts AS (
  SELECT b.concept_id,b.period_kind,b.period_start,b.period_end,b.dimensions,
    COUNT(m.person_id) AS records,COUNT(DISTINCT m.person_id) AS people
  FROM base b LEFT JOIN classified m ON m.measurement_concept_id=b.concept_id
    AND m.measurement_date BETWEEN b.period_start AND b.period_end
  GROUP BY b.concept_id,b.period_kind,b.period_start,b.period_end,b.dimensions
), flags AS (
  SELECT n AS numeric_present,c AS coded_present,t AS source_text_present
  FROM (VALUES(false),(true)) x(n) CROSS JOIN (VALUES(false),(true)) y(c) CROSS JOIN (VALUES(false),(true)) z(t)
), representations AS (
  SELECT b.dimensions || jsonb_build_object('numeric_present',f.numeric_present,'coded_present',f.coded_present,
    'source_text_present',f.source_text_present) AS dimensions,COUNT(m.person_id) AS n
  FROM base b CROSS JOIN flags f LEFT JOIN classified m ON m.measurement_concept_id=b.concept_id
    AND m.measurement_date BETWEEN b.period_start AND b.period_end
    AND m.numeric_present=f.numeric_present AND m.coded_present=f.coded_present AND m.source_text_present=f.source_text_present
  GROUP BY b.dimensions,f.numeric_present,f.coded_present,f.source_text_present
), reasons AS (
  SELECT reason FROM (VALUES ('missing_numeric'),('non_finite_numeric'),('explicit_operator'),
    ('missing_unit'),('unmapped_unit'),('unknown_or_invalid_unit'),('eligible')) x(reason)
), eligibility AS (
  SELECT b.dimensions || jsonb_build_object('eligibility_reason',r.reason) AS dimensions,COUNT(m.person_id) AS n
  FROM base b CROSS JOIN reasons r LEFT JOIN classified m ON m.measurement_concept_id=b.concept_id
    AND m.measurement_date BETWEEN b.period_start AND b.period_end AND m.eligibility_reason=r.reason
  GROUP BY b.dimensions,r.reason
), units AS (
  SELECT b.dimensions || jsonb_build_object('raw_unit_tag',m.raw_unit_tag) AS dimensions,COUNT(*) AS n
  FROM base b JOIN classified m ON m.measurement_concept_id=b.concept_id
    AND m.measurement_date BETWEEN b.period_start AND b.period_end GROUP BY b.dimensions,m.raw_unit_tag
), operators AS (
  SELECT b.dimensions || jsonb_build_object('raw_operator_tag',m.raw_operator_tag) AS dimensions,COUNT(*) AS n
  FROM base b JOIN classified m ON m.measurement_concept_id=b.concept_id
    AND m.measurement_date BETWEEN b.period_start AND b.period_end GROUP BY b.dimensions,m.raw_operator_tag
), summary_groups AS (
  SELECT DISTINCT measurement_concept_id,unit_concept_id,raw_operator_tag FROM classified
  WHERE known_unit AND raw_operator_tag IN ('null','zero')
), frequency_inputs AS (
  -- Restricted in-database scratch: never a result partition or a person-level export.
  SELECT measurement_concept_id,unit_concept_id,raw_operator_tag,value_as_number AS value,COUNT(*) AS frequency
  FROM classified WHERE eligibility_reason='eligible'
  GROUP BY measurement_concept_id,unit_concept_id,raw_operator_tag,value_as_number
), frequency_totals AS (
  SELECT measurement_concept_id,unit_concept_id,raw_operator_tag,SUM(frequency) AS n,SUM(value*frequency) AS total
  FROM frequency_inputs GROUP BY measurement_concept_id,unit_concept_id,raw_operator_tag
), ranked_reference AS (
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
), output_rows AS (
  SELECT 'measurement.record_count' AS metric,dimensions,jsonb_build_object('count',records::text) AS values FROM counts
  UNION ALL SELECT 'measurement.person_count',dimensions,jsonb_build_object('count',people::text) FROM counts
  UNION ALL SELECT 'measurement.representation_count',dimensions,jsonb_build_object('count',n::text) FROM representations
  UNION ALL SELECT 'measurement.numeric_eligibility_count',dimensions,jsonb_build_object('count',n::text) FROM eligibility
  UNION ALL SELECT 'measurement.unit_count',dimensions,jsonb_build_object('count',n::text) FROM units
  UNION ALL SELECT 'measurement.operator_count',dimensions,jsonb_build_object('count',n::text) FROM operators
  UNION ALL SELECT 'measurement.numeric_summary',dimensions,values FROM summaries
), metrics AS (
  SELECT metric FROM (VALUES ('measurement.record_count'),('measurement.person_count'),('measurement.representation_count'),
    ('measurement.unit_count'),('measurement.operator_count'),('measurement.numeric_eligibility_count'),('measurement.numeric_summary')) m(metric)
)
SELECT m.metric,COALESCE(jsonb_agg(jsonb_build_object('dimensions',r.dimensions,'values',r.values) ORDER BY r.dimensions::text)
  FILTER (WHERE r.metric IS NOT NULL),'[]'::jsonb)::text AS rows
FROM metrics m LEFT JOIN output_rows r USING(metric) GROUP BY m.metric ORDER BY m.metric
