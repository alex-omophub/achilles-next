, frequency_inputs AS (
  -- Restricted in-database scratch: never a result partition or a person-level export.
  SELECT measurement_concept_id,unit_concept_id,raw_operator_tag,value_as_number AS value,COUNT(*) AS frequency
  FROM classified WHERE eligibility_reason='eligible'
  GROUP BY measurement_concept_id,unit_concept_id,raw_operator_tag,value_as_number
)
