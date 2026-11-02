-- Only aggregate counts cross the source boundary. Identifiers remain SQL-local.
WITH people AS MATERIALIZED (
  SELECT person_id,gender_concept_id FROM {{cdm_schema}}.person
), reports AS (
  SELECT 'example.person.count' AS metric_id,'{}'::jsonb AS dimensions,count(*)::text AS n
  FROM people
  UNION ALL
  SELECT 'example.person.gender_count',
    jsonb_build_object('gender_concept_id',COALESCE(gender_concept_id::text,'null')),count(*)::text
  FROM people GROUP BY gender_concept_id
)
SELECT jsonb_build_object('metric_id',metric_id,'dimensions',dimensions,
  'row_kind','counts','values',jsonb_build_object('person_count',n))::text FROM reports
