WITH concepts AS (SELECT DISTINCT concept_tag FROM {{classified}}), capture_concepts AS (
  SELECT concept_tag FROM concepts UNION ALL SELECT jsonb_build_object('kind','all')
), scopes AS (
  SELECT period_kind,period_start,period_end FROM {{periods}}
  UNION ALL SELECT 'undated',NULL::date,NULL::date
), expanded AS (
  SELECT c.*,'full_scope'::text AS period_kind,NULL::date AS period_start,NULL::date AS period_end FROM {{classified}} c
  UNION ALL SELECT c.*,'undated',NULL::date,NULL::date FROM {{classified}} c WHERE c.event_date IS NULL
  UNION ALL SELECT c.*,'calendar_month',date_trunc('month',event_date)::date,(date_trunc('month',event_date)+INTERVAL '1 month - 1 day')::date FROM {{classified}} c WHERE valid_date
  UNION ALL SELECT c.*,'calendar_year',date_trunc('year',event_date)::date,(date_trunc('year',event_date)+INTERVAL '1 year - 1 day')::date FROM {{classified}} c WHERE valid_date
), capture AS (
  SELECT CASE WHEN GROUPING(concept_tag)=1 THEN jsonb_build_object('kind','all') ELSE concept_tag END AS concept_tag,period_kind,period_start,period_end,COUNT(*)::text AS records,
    COUNT(DISTINCT person_id) FILTER(WHERE linked)::text AS people,
    COUNT(*) FILTER(WHERE observed)::text AS observed_records,COUNT(DISTINCT person_id) FILTER(WHERE observed)::text AS observed_people
  FROM expanded GROUP BY GROUPING SETS((concept_tag,period_kind,period_start,period_end),(period_kind,period_start,period_end))
), frequencies AS (
  SELECT concept_tag,person_id,COUNT(*)::numeric AS n FROM {{classified}} WHERE linked GROUP BY concept_tag,person_id
), per_person AS (
  SELECT p.person_id,COUNT(DISTINCT c.concept_id) FILTER(WHERE c.concept_id IS NOT NULL)::text AS n
  FROM {{person}} p LEFT JOIN {{classified}} c USING(person_id) GROUP BY p.person_id
), year_people AS (
  SELECT concept_tag,EXTRACT(YEAR FROM event_date)::integer::text AS year,
    COALESCE(gender_concept_id::text,'null') AS gender,
    CASE WHEN year_of_birth BETWEEN 1 AND 9999 AND EXTRACT(YEAR FROM event_date)::numeric-year_of_birth::numeric BETWEEN 0 AND 130
      THEN DIV(EXTRACT(YEAR FROM event_date)::numeric-year_of_birth::numeric,10)::text ELSE 'unknown' END AS age,person_id
  FROM {{classified}} WHERE observed
)
SELECT '{{core}}.capture_count'::text AS metric_id,'counts'::text AS row_kind,
  jsonb_build_object('concept_tag',g.concept_tag,'period_kind',p.period_kind,'period_start',COALESCE(p.period_start::text,'null'),'period_end',COALESCE(p.period_end::text,'null')) AS dimensions,
  jsonb_build_object('record_count',COALESCE(c.records,'0'),'person_count',COALESCE(c.people,'0')) AS values
FROM capture_concepts g CROSS JOIN scopes p LEFT JOIN capture c ON c.concept_tag=g.concept_tag AND c.period_kind=p.period_kind
  AND c.period_start IS NOT DISTINCT FROM p.period_start AND c.period_end IS NOT DISTINCT FROM p.period_end
UNION ALL
SELECT '{{observed}}.capture_count','counts',
  jsonb_build_object('concept_tag',g.concept_tag,'period_kind',p.period_kind,'period_start',COALESCE(p.period_start::text,'null'),'period_end',COALESCE(p.period_end::text,'null')),
  jsonb_build_object('record_count',COALESCE(c.observed_records,'0'),'person_count',COALESCE(c.observed_people,'0'))
FROM capture_concepts g CROSS JOIN {{periods}} p LEFT JOIN capture c ON c.concept_tag=g.concept_tag AND c.period_kind=p.period_kind
  AND c.period_start IS NOT DISTINCT FROM p.period_start AND c.period_end IS NOT DISTINCT FROM p.period_end
UNION ALL
SELECT '{{core}}.source_count','counts',jsonb_build_object('concept_tag',concept_tag,'source_concept_tag',source_tag,'source_value_state',source_state),
  jsonb_build_object('record_count',COUNT(*)::text,'person_count',COUNT(DISTINCT person_id) FILTER(WHERE linked)::text)
FROM {{classified}} GROUP BY concept_tag,source_tag,source_state
UNION ALL
SELECT '{{core}}.type_count','counts',jsonb_build_object('concept_tag',concept_tag,'type_concept_tag',type_tag),
  jsonb_build_object('record_count',COUNT(*)::text,'person_count',COUNT(DISTINCT person_id) FILTER(WHERE linked)::text)
FROM {{classified}} GROUP BY concept_tag,type_tag
UNION ALL
SELECT '{{core}}.observation_qualification_count','counts',jsonb_build_object('concept_tag',concept_tag,'reason',qualification),
  jsonb_build_object('record_count',COUNT(*)::text,'person_count',COUNT(DISTINCT person_id) FILTER(WHERE linked)::text)
FROM {{classified}} GROUP BY concept_tag,qualification
UNION ALL
SELECT '{{core}}.frequency_histogram','counts',jsonb_build_object('concept_tag',concept_tag,'event_count',n::text),jsonb_build_object('person_count',COUNT(*)::text)
FROM frequencies GROUP BY concept_tag,n
UNION ALL
SELECT '{{core}}.frequency_histogram','counts',jsonb_build_object('concept_tag',g.concept_tag,'event_count','0'),
  jsonb_build_object('person_count',((SELECT COUNT(*)::numeric FROM {{person}})-COUNT(f.person_id))::text)
FROM concepts g LEFT JOIN frequencies f USING(concept_tag) GROUP BY g.concept_tag
UNION ALL
SELECT '{{core}}.distinct_concepts_histogram','counts',jsonb_build_object('concept_count',n),jsonb_build_object('person_count',COUNT(*)::text)
FROM per_person GROUP BY n
UNION ALL
SELECT '{{observed}}.year_gender_age_count','counts',
  jsonb_build_object('concept_tag',CASE WHEN GROUPING(concept_tag)=1 THEN jsonb_build_object('kind','all') ELSE concept_tag END,
    'year',year,'gender_concept_id',gender,'year_age_decile',age),jsonb_build_object('person_count',COUNT(DISTINCT person_id)::text)
FROM year_people GROUP BY GROUPING SETS((concept_tag,year,gender,age),(year,gender,age))
