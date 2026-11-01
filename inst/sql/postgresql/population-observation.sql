WITH coverage AS (
  SELECT p.period_kind,p.period_start,p.period_end,p.full_calendar_period,
    COUNT(DISTINCT i.person_id)::text AS n,
    COALESCE(SUM(CASE WHEN i.person_id IS NULL THEN 0 ELSE (LEAST(i.end_date,p.period_end)-GREATEST(i.start_date,p.period_start)+1)::numeric END),0)::text AS days,
    COUNT(DISTINCT i.person_id) FILTER(WHERE i.start_date<=p.period_start AND i.end_date>=p.period_end)::text AS continuous
  FROM {{periods}} p LEFT JOIN {{intervals}} i ON i.start_date<=p.period_end AND i.end_date>=p.period_start
  GROUP BY p.period_kind,p.period_start,p.period_end,p.full_calendar_period
), year_people AS (
  SELECT jsonb_build_object('year',EXTRACT(YEAR FROM y.period_start)::integer::text,'gender_concept_id',COALESCE(p.gender_concept_id::text,'null'),
    'year_age_decile',CASE WHEN p.year_of_birth BETWEEN 1 AND 9999 AND EXTRACT(YEAR FROM y.period_start)::numeric-p.year_of_birth::numeric BETWEEN 0 AND 130
      THEN ((EXTRACT(YEAR FROM y.period_start)::integer-p.year_of_birth)/10)::text ELSE 'unknown' END) AS dimensions
  FROM {{periods}} y CROSS JOIN {{person}} p WHERE y.period_kind='calendar_year' AND
    EXISTS(SELECT 1 FROM {{intervals}} i WHERE i.person_id=p.person_id AND i.start_date<=y.period_end AND i.end_date>=y.period_start)
), samples AS (
  SELECT 'core.observation_period.first_age_summary'::text AS metric_id,
    jsonb_build_object('gender_concept_id',COALESCE(gender_concept_id::text,'null')) AS dimensions,
    first_age::numeric AS value,age_reason AS reason FROM {{people}} WHERE first_start IS NOT NULL
  UNION ALL
  SELECT 'core.observation_period.first_interval_days_summary',
    jsonb_build_object('gender_concept_id',COALESCE(gender_concept_id::text,'null'),'first_year_age_decile',first_decile),
    (first_end-first_start+1)::numeric,'eligible' FROM {{people}} WHERE first_start IS NOT NULL
), summary_groups AS (
  SELECT metric_id,dimensions,COUNT(value)::numeric AS n,SUM(value) AS total FROM samples GROUP BY metric_id,dimensions
), ranked AS (
  SELECT metric_id,dimensions,value,ROW_NUMBER() OVER(PARTITION BY metric_id,dimensions ORDER BY value) AS rank
  FROM samples WHERE reason='eligible'
), summaries AS (
  SELECT g.metric_id,g.dimensions,g.n,g.total,MIN(r.value) AS minimum,MAX(r.value) AS maximum,
    MAX(value) FILTER(WHERE rank=DIV(n+9,10)) AS p10,MAX(value) FILTER(WHERE rank=DIV(n+3,4)) AS p25,
    MAX(value) FILTER(WHERE rank=DIV(n+1,2)) AS p50,MAX(value) FILTER(WHERE rank=DIV(n*3+3,4)) AS p75,
    MAX(value) FILTER(WHERE rank=DIV(n*9+9,10)) AS p90
  FROM summary_groups g LEFT JOIN ranked r USING(metric_id,dimensions) GROUP BY g.metric_id,g.dimensions,g.n,g.total
), eligibility AS (
  SELECT g.metric_id,g.dimensions,r.reason,COUNT(s.reason)::text AS n FROM summary_groups g
  CROSS JOIN (VALUES('event_date_missing_or_invalid'),('birth_year_missing_or_invalid'),('year_age_outside_0_130'),('eligible')) r(reason)
  LEFT JOIN samples s ON s.metric_id=g.metric_id AND s.dimensions=g.dimensions AND s.reason=r.reason
  WHERE g.metric_id='core.observation_period.first_age_summary' OR r.reason='eligible'
  GROUP BY g.metric_id,g.dimensions,r.reason
)
SELECT 'core.observation_period.coverage_count'::text AS metric_id,'counts'::text AS row_kind,
  jsonb_build_object('period_kind',period_kind,'period_start',COALESCE(period_start::text,'null'),'period_end',COALESCE(period_end::text,'null')) AS dimensions,
  jsonb_build_object('person_count',n,'person_days',days) AS values FROM coverage
UNION ALL
SELECT 'core.observation_period.continuous_person_count','counts',
  jsonb_build_object('period_kind',period_kind,'period_start',COALESCE(period_start::text,'null'),'period_end',COALESCE(period_end::text,'null'),'full_calendar_period',CASE WHEN full_calendar_period THEN 'true' ELSE 'false' END),
  jsonb_build_object('person_count',continuous) FROM coverage
UNION ALL
SELECT 'core.observation_period.year_gender_age_count','counts',
  dimensions,jsonb_build_object('person_count',COUNT(*)::text) FROM year_people GROUP BY dimensions
UNION ALL
SELECT 'core.observation_period.first_age_count','counts',
  jsonb_build_object('gender_concept_id',COALESCE(gender_concept_id::text,'null'),'year_age_or_unknown',COALESCE(first_age::text,'unknown')),
  jsonb_build_object('person_count',COUNT(*)::text) FROM {{people}} WHERE first_start IS NOT NULL GROUP BY gender_concept_id,first_age
UNION ALL
SELECT 'core.observation_period.first_interval_30d_count','counts',jsonb_build_object('floor_days_div_30',DIV((first_end-first_start+1)::numeric,30)::text),
  jsonb_build_object('person_count',COUNT(*)::text) FROM {{people}} WHERE first_start IS NOT NULL GROUP BY DIV((first_end-first_start+1)::numeric,30)
UNION ALL
SELECT 'core.observation_period.person_interval_histogram','counts',jsonb_build_object('interval_count',interval_count::text),
  jsonb_build_object('person_count',COUNT(*)::text) FROM {{people}} GROUP BY interval_count
UNION ALL
SELECT 'core.observation_period.total_days_histogram','counts',jsonb_build_object('floor_days_div_30',DIV(total_days,30)::text),
  jsonb_build_object('person_count',COUNT(*)::text) FROM {{people}} GROUP BY DIV(total_days,30)
UNION ALL
SELECT 'core.observation_period.boundary_month_count','counts',jsonb_build_object('boundary_kind',b.kind,'month',date_trunc('month',b.day)::date::text),
  jsonb_build_object('interval_count',COUNT(*)::text,'person_count',COUNT(DISTINCT i.person_id)::text)
FROM {{intervals}} i CROSS JOIN LATERAL (VALUES('start',i.start_date),('end',i.end_date)) b(kind,day) GROUP BY b.kind,date_trunc('month',b.day)::date
UNION ALL
SELECT 'core.observation_period.type_count','counts',jsonb_build_object('period_type_concept_id',COALESCE(period_type_concept_id::text,'null')),
  jsonb_build_object('record_count',COUNT(*)::text) FROM {{raw}} GROUP BY period_type_concept_id
UNION ALL
SELECT 'core.observation_period.integrity_count','counts',jsonb_build_object('reason',r.reason),jsonb_build_object('record_count',COUNT(o.reason)::text)
FROM (VALUES('null_person'),('orphan_person'),('null_endpoints'),('reversed_interval'),('valid')) r(reason)
LEFT JOIN {{raw}} o USING(reason) GROUP BY r.reason
UNION ALL
SELECT metric_id,'summary',dimensions,jsonb_build_object('n',n::text,'sum',total::text,'mean_numerator',total::text,
  'mean_denominator',CASE WHEN n>0 THEN n::text END,'min',minimum::text,'max',maximum::text,
  'p10',p10::text,'p25',p25::text,'p50',p50::text,'p75',p75::text,'p90',p90::text) FROM summaries
UNION ALL
SELECT metric_id,'eligibility_counts',dimensions||jsonb_build_object('eligibility_reason',reason),jsonb_build_object('person_count',n) FROM eligibility
