WITH concepts AS (SELECT {{concept_tag}} AS concept_tag FROM {{classified}} GROUP BY concept_id), frequencies AS (
  SELECT concept_id,person_id,COUNT(*) AS n FROM {{classified}} WHERE linked GROUP BY concept_id,person_id
), histogram AS (
  SELECT {{concept_tag}} AS concept_tag,
    n,COUNT(*) AS people FROM frequencies GROUP BY concept_id,n
), people_with_concepts AS (
  SELECT person_id,COUNT(concept_id) AS n FROM frequencies GROUP BY person_id
), per_person AS (
  SELECT COALESCE(f.n,0)::text AS n FROM (SELECT DISTINCT person_id FROM {{person}}) p
  LEFT JOIN people_with_concepts f USING(person_id)
), year_people AS (
  SELECT concept_id,EXTRACT(YEAR FROM event_date)::integer AS year,gender_concept_id AS gender,
    CASE WHEN year_of_birth BETWEEN 1 AND 9999 AND EXTRACT(YEAR FROM event_date)::numeric-year_of_birth::numeric BETWEEN 0 AND 130
      THEN DIV(EXTRACT(YEAR FROM event_date)::numeric-year_of_birth::numeric,10) END AS age,person_id
  FROM {{classified}} WHERE observed
)
SELECT '{{core}}.source_count','counts',jsonb_build_object('concept_tag',{{concept_tag}},'source_concept_tag',source_tag,'source_value_state',source_state),
  jsonb_build_object('record_count',COUNT(*)::text,'person_count',COUNT(DISTINCT person_id) FILTER(WHERE linked)::text)
FROM {{classified}} GROUP BY concept_id,source_tag,source_state
UNION ALL
SELECT '{{core}}.type_count','counts',jsonb_build_object('concept_tag',{{concept_tag}},'type_concept_tag',type_tag),
  jsonb_build_object('record_count',COUNT(*)::text,'person_count',COUNT(DISTINCT person_id) FILTER(WHERE linked)::text)
FROM {{classified}} GROUP BY concept_id,type_tag
UNION ALL
SELECT '{{core}}.observation_qualification_count','counts',jsonb_build_object('concept_tag',{{concept_tag}},'reason',qualification),
  jsonb_build_object('record_count',COUNT(*)::text,'person_count',COUNT(DISTINCT person_id) FILTER(WHERE linked)::text)
FROM {{classified}} GROUP BY concept_id,qualification
UNION ALL
SELECT '{{core}}.frequency_histogram','counts',jsonb_build_object('concept_tag',concept_tag,'event_count',n::text),jsonb_build_object('person_count',people::text)
FROM histogram
UNION ALL
SELECT '{{core}}.frequency_histogram','counts',jsonb_build_object('concept_tag',g.concept_tag,'event_count','0'),
  jsonb_build_object('person_count',((SELECT COUNT(*)::numeric FROM {{person}})-COALESCE(t.people,0))::text)
FROM concepts g LEFT JOIN (SELECT concept_tag,SUM(people) AS people FROM histogram GROUP BY concept_tag) t USING(concept_tag)
UNION ALL
SELECT '{{core}}.distinct_concepts_histogram','counts',jsonb_build_object('concept_count',n),jsonb_build_object('person_count',COUNT(*)::text)
FROM per_person GROUP BY n
UNION ALL
SELECT '{{observed}}.year_gender_age_count','counts',
  jsonb_build_object('concept_tag',CASE WHEN GROUPING(concept_id)=1 THEN jsonb_build_object('kind','all') ELSE {{concept_tag}} END,
    'year',year::text,'gender_concept_id',COALESCE(gender::text,'null'),'year_age_decile',COALESCE(age::text,'unknown')),jsonb_build_object('person_count',COUNT(DISTINCT person_id)::text)
FROM year_people GROUP BY GROUPING SETS((concept_id,year,gender,age),(year,gender,age))
