-- All-recorded numeric scope. In particular, do not filter by observed/window.
WITH classified_numeric AS (
  SELECT *,CASE
    WHEN value_as_number IS NULL THEN 'missing_numeric'
    WHEN value_as_number::text IN ('NaN','Infinity','-Infinity') THEN 'non_finite_numeric'
    WHEN unit_concept_id IS NULL THEN 'missing_unit'
    WHEN unit_concept_id=0 THEN 'unmapped_unit'
    WHEN NOT known_unit THEN 'unknown_or_invalid_unit'
    WHEN operator_concept_id IS NOT NULL AND operator_concept_id<>0 THEN 'explicit_operator'
    ELSE 'eligible' END AS reason FROM classified
), groups AS (
  SELECT DISTINCT concept_id,unit_concept_id,operator_concept_id FROM classified_numeric
  WHERE known_unit AND (operator_concept_id IS NULL OR operator_concept_id=0)
), eligible AS (
  SELECT * FROM classified_numeric WHERE reason='eligible'
), {{ranks}}
SELECT g.concept_id::text AS concept_id,g.unit_concept_id::text AS unit_concept_id,
  g.operator_concept_id::text AS operator_concept_id,COALESCE(MAX(n),0)::text AS n,
  SUM({{sum_value}})::text AS total,MIN(value)::text AS minimum,MAX(value)::text AS maximum,
  (MIN(value) FILTER(WHERE {{rank}}>=DIV(n+9,10)))::text AS p10,
  (MIN(value) FILTER(WHERE {{rank}}>=DIV(n+3,4)))::text AS p25,
  (MIN(value) FILTER(WHERE {{rank}}>=DIV(n+1,2)))::text AS p50,
  (MIN(value) FILTER(WHERE {{rank}}>=DIV(n*3+3,4)))::text AS p75,
  (MIN(value) FILTER(WHERE {{rank}}>=DIV(n*9+9,10)))::text AS p90
FROM groups g LEFT JOIN ranked r ON r.concept_id IS NOT DISTINCT FROM g.concept_id
  AND r.unit_concept_id=g.unit_concept_id AND r.operator_concept_id IS NOT DISTINCT FROM g.operator_concept_id
GROUP BY g.concept_id,g.unit_concept_id,g.operator_concept_id ORDER BY g.concept_id NULLS FIRST,g.unit_concept_id,g.operator_concept_id NULLS FIRST
