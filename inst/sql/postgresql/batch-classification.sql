SELECT e.person_id,e."{{concept}}" AS concept_id,e."{{event_date}}" AS event_date,
  {{numeric_value}} AS value_as_number,{{unit}} AS unit_concept_id,{{operator}} AS operator_concept_id,
  EXISTS (SELECT 1 FROM "{{schema}}".person p WHERE p.person_id=e.person_id) AS linked_person,
  EXISTS (SELECT 1 FROM intervals o WHERE o.person_id=e.person_id AND e."{{event_date}}" BETWEEN o.start_date AND o.end_date) AS observed,
  EXISTS (SELECT 1 FROM "{{schema}}".concept c WHERE c.concept_id={{unit}} AND c.concept_id>0 AND c.domain_id='Unit') AS known_unit
FROM "{{schema}}"."{{table}}" e
