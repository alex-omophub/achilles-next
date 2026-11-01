WITH groups AS (
  SELECT year_of_birth,gender_concept_id,race_concept_id,ethnicity_concept_id,
    GROUPING(year_of_birth,gender_concept_id,race_concept_id,ethnicity_concept_id) AS g,COUNT(*)::text AS n
  FROM {{person}}
  GROUP BY GROUPING SETS ((),(gender_concept_id),(year_of_birth),(race_concept_id),
    (ethnicity_concept_id),(year_of_birth,gender_concept_id),(race_concept_id,ethnicity_concept_id))
)
SELECT 'core.person.'||CASE g WHEN 15 THEN 'count' WHEN 11 THEN 'gender_count' WHEN 7 THEN 'birth_year_count'
  WHEN 13 THEN 'race_count' WHEN 14 THEN 'ethnicity_count' WHEN 3 THEN 'birth_year_gender_count' WHEN 12 THEN 'race_ethnicity_count' END AS metric_id,
  'counts'::text AS row_kind,
  CASE g WHEN 15 THEN '{}'::jsonb
    WHEN 11 THEN jsonb_build_object('gender_concept_id',COALESCE(gender_concept_id::text,'null'))
    WHEN 7 THEN jsonb_build_object('year_of_birth',COALESCE(year_of_birth::text,'null'))
    WHEN 13 THEN jsonb_build_object('race_concept_id',COALESCE(race_concept_id::text,'null'))
    WHEN 14 THEN jsonb_build_object('ethnicity_concept_id',COALESCE(ethnicity_concept_id::text,'null'))
    WHEN 3 THEN jsonb_build_object('year_of_birth',COALESCE(year_of_birth::text,'null'),'gender_concept_id',COALESCE(gender_concept_id::text,'null'))
    WHEN 12 THEN jsonb_build_object('race_concept_id',COALESCE(race_concept_id::text,'null'),'ethnicity_concept_id',COALESCE(ethnicity_concept_id::text,'null')) END AS dimensions,
  jsonb_build_object('person_count',n) AS values
FROM groups
