WITH concepts AS (
  SELECT DISTINCT concept_tag FROM {{classified}}
  UNION ALL SELECT jsonb_build_object('kind','all')
), events AS (
  SELECT concept_id,person_id,linked,observed,{{period_key}} AS period_key
  FROM {{classified}} WHERE {{eligible}}
), capture AS (
  SELECT CASE WHEN GROUPING(concept_id)=1 THEN jsonb_build_object('kind','all')
              WHEN concept_id IS NULL THEN jsonb_build_object('kind','null')
              ELSE jsonb_build_object('kind','id','value',concept_id::text) END AS concept_tag,
    period_key,COUNT(*)::text AS records,COUNT(DISTINCT person_id) FILTER(WHERE linked)::text AS people,
    COUNT(*) FILTER(WHERE observed)::text AS observed_records,COUNT(DISTINCT person_id) FILTER(WHERE observed)::text AS observed_people
  FROM events GROUP BY GROUPING SETS((concept_id,period_key),(period_key))
)
SELECT m.metric_id,'counts'::text AS row_kind,
  jsonb_build_object('concept_tag',g.concept_tag,'period_kind',p.period_kind,'period_start',COALESCE(p.period_start::text,'null'),'period_end',COALESCE(p.period_end::text,'null')) AS dimensions,
  jsonb_build_object('record_count',COALESCE(m.records,'0'),'person_count',COALESCE(m.people,'0')) AS values
FROM concepts g CROSS JOIN ({{scopes}}) p
LEFT JOIN capture c ON c.concept_tag=g.concept_tag AND c.period_key=COALESCE(p.period_start,'-infinity'::date)
CROSS JOIN LATERAL (VALUES
  ('{{core}}.capture_count',c.records,c.people,true),
  ('{{observed}}.capture_count',c.observed_records,c.observed_people,p.period_kind<>'undated')
) m(metric_id,records,people,include_row)
WHERE m.include_row
