, selected AS (SELECT concept_id FROM (VALUES {{concepts}}) s(concept_id)),
eligible_measurements AS (
  SELECT m.person_id,m.measurement_concept_id,m.measurement_date,m.value_as_number,
    m.value_as_concept_id,m.value_source_value,m.unit_concept_id,m.operator_concept_id
  FROM "{{schema}}".measurement m, params
  WHERE m.measurement_concept_id IN (SELECT concept_id FROM selected)
    AND m.measurement_date BETWEEN window_start AND window_end
    AND {{membership}}
), term_ids AS (
  SELECT concept_id FROM selected
  UNION SELECT unit_concept_id FROM eligible_measurements
  UNION SELECT operator_concept_id FROM eligible_measurements
  UNION SELECT value_as_concept_id FROM eligible_measurements
), local_concepts AS (
  SELECT DISTINCT c.concept_id, c.concept_name, c.domain_id
  FROM "{{schema}}".concept c JOIN term_ids t ON t.concept_id=c.concept_id
  WHERE c.concept_id BETWEEN 0 AND 2147483647
), classified AS MATERIALIZED (
  SELECT m.*,
    m.value_as_number IS NOT NULL AS numeric_present,
    m.value_as_concept_id IS NOT NULL AND m.value_as_concept_id<>0 AS coded_present,
    m.value_source_value IS NOT NULL AND btrim(m.value_source_value,' ')<>'' AS source_text_present,
    CASE WHEN m.unit_concept_id IS NULL THEN 'null' WHEN m.unit_concept_id=0 THEN 'zero'
      ELSE 'id:'||m.unit_concept_id::text END AS raw_unit_tag,
    CASE WHEN m.operator_concept_id IS NULL THEN 'null' WHEN m.operator_concept_id=0 THEN 'zero'
      ELSE 'id:'||m.operator_concept_id::text END AS raw_operator_tag,
    EXISTS (SELECT 1 FROM local_concepts c WHERE c.concept_id=m.unit_concept_id
      AND c.concept_id>0 AND c.domain_id='Unit' AND btrim(c.concept_name,E' \t\r\n')<>'') AS known_unit,
    CASE
      WHEN m.value_as_number IS NULL THEN 'missing_numeric'
      WHEN m.value_as_number::text IN ('NaN','Infinity','-Infinity') THEN 'non_finite_numeric'
      WHEN m.operator_concept_id IS NOT NULL AND m.operator_concept_id<>0 THEN 'explicit_operator'
      WHEN m.unit_concept_id IS NULL THEN 'missing_unit'
      WHEN m.unit_concept_id=0 THEN 'unmapped_unit'
      WHEN NOT EXISTS (SELECT 1 FROM local_concepts c WHERE c.concept_id=m.unit_concept_id
        AND c.concept_id>0 AND c.domain_id='Unit') THEN 'unknown_or_invalid_unit'
      ELSE 'eligible' END AS eligibility_reason
  FROM eligible_measurements m
)
