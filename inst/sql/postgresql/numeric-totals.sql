, frequency_totals AS (
  SELECT measurement_concept_id,unit_concept_id,raw_operator_tag,SUM(frequency) AS n,SUM(value*frequency) AS total
  FROM frequency_inputs GROUP BY measurement_concept_id,unit_concept_id,raw_operator_tag
)
