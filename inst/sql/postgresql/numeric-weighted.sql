, cumulative_weights AS (
  -- One row per exact distinct value. ROWS is explicit; no self-join, FLOAT
  -- coercion, interpolation or expansion of a value's physical multiplicity.
  SELECT measurement_concept_id,unit_concept_id,raw_operator_tag,value,
    SUM(frequency) OVER (PARTITION BY measurement_concept_id,unit_concept_id,raw_operator_tag
      ORDER BY value ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_n
  FROM frequency_inputs
), summaries AS (
  SELECT jsonb_build_object('measurement_concept_id',g.measurement_concept_id,'unit_concept_id',g.unit_concept_id,
    'raw_operator_tag',g.raw_operator_tag) AS dimensions,
    jsonb_build_object('n',COALESCE(f.n,0)::text,'sum',f.total::text,'mean_numerator',f.total::text,
      'mean_denominator',CASE WHEN f.n>0 THEN f.n::text END,'min',MIN(w.value)::text,'max',MAX(w.value)::text,
      'p10',(MIN(w.value) FILTER (WHERE w.cumulative_n>=DIV(f.n+9,10)))::text,
      'p25',(MIN(w.value) FILTER (WHERE w.cumulative_n>=DIV(f.n+3,4)))::text,
      'p50',(MIN(w.value) FILTER (WHERE w.cumulative_n>=DIV(f.n+1,2)))::text,
      'p75',(MIN(w.value) FILTER (WHERE w.cumulative_n>=DIV(f.n*3+3,4)))::text,
      'p90',(MIN(w.value) FILTER (WHERE w.cumulative_n>=DIV(f.n*9+9,10)))::text) AS values
  FROM summary_groups g LEFT JOIN frequency_totals f USING(measurement_concept_id,unit_concept_id,raw_operator_tag)
  LEFT JOIN cumulative_weights w USING(measurement_concept_id,unit_concept_id,raw_operator_tag)
  GROUP BY g.measurement_concept_id,g.unit_concept_id,g.raw_operator_tag,f.n,f.total
)
