-- Independent in-memory edge oracle. No table writes or production operator.
WITH rows AS (
  SELECT * FROM jsonb_to_recordset({{rows}}::jsonb)
    AS r(id integer,value_as_number numeric,unit_concept_id integer,operator_concept_id integer)
), classified AS (
  SELECT *, CASE
    WHEN value_as_number IS NULL THEN 'missing_numeric'
    WHEN value_as_number::text IN ('NaN','Infinity','-Infinity') THEN 'non_finite_numeric'
    WHEN operator_concept_id IS NOT NULL AND operator_concept_id<>0 THEN 'explicit_operator'
    WHEN unit_concept_id IS NULL THEN 'missing_unit'
    WHEN unit_concept_id=0 THEN 'unmapped_unit'
    WHEN unit_concept_id NOT IN (900000101,900000102) THEN 'unknown_or_invalid_unit'
    ELSE 'eligible' END AS eligibility
  FROM rows
), strata AS (
  SELECT unit_concept_id,operator_concept_id,count(*)::text AS n,sum(value_as_number)::text AS sum,
    jsonb_agg(value_as_number::text ORDER BY value_as_number) AS sorted_values,
    percentile_disc(0.5) WITHIN GROUP (ORDER BY value_as_number)::text AS p50
  FROM classified WHERE eligibility='eligible' GROUP BY unit_concept_id,operator_concept_id
)
SELECT jsonb_build_object(
  'eligibility_by_record',(SELECT jsonb_object_agg(id::text,eligibility) FROM classified),
  'strata',(SELECT jsonb_object_agg('id:'||unit_concept_id::text||'|'||CASE WHEN operator_concept_id IS NULL THEN 'null' ELSE 'zero' END,
    jsonb_build_object('n',n,'sum',sum,'sorted_values',sorted_values,'p50',p50)) FROM strata)
);
