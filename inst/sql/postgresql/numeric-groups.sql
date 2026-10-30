, summary_groups AS (
  SELECT DISTINCT measurement_concept_id,unit_concept_id,raw_operator_tag FROM classified
  WHERE known_unit AND raw_operator_tag IN ('null','zero')
)
