WITH samples AS ({{samples}}), groups AS (
  SELECT DISTINCT metric_id,dimensions FROM samples
), eligible AS (
  SELECT metric_id,dimensions,value FROM samples WHERE reason='eligible'
), totals AS (
  SELECT metric_id,dimensions,COUNT(*)::numeric AS n,SUM(value) AS total FROM eligible GROUP BY metric_id,dimensions
), frequencies AS (
  SELECT metric_id,dimensions,value,COUNT(*)::numeric AS frequency FROM eligible GROUP BY metric_id,dimensions,value
), ranked AS (
  SELECT *,SUM(frequency) OVER(PARTITION BY metric_id,dimensions ORDER BY value ROWS UNBOUNDED PRECEDING) AS rank FROM frequencies
), summaries AS (
  SELECT g.metric_id,g.dimensions,COALESCE(t.n,0) AS n,t.total,MIN(r.value) AS minimum,MAX(r.value) AS maximum,
    MIN(value) FILTER(WHERE rank>=DIV(t.n+9,10)) AS p10,MIN(value) FILTER(WHERE rank>=DIV(t.n+3,4)) AS p25,
    MIN(value) FILTER(WHERE rank>=DIV(t.n+1,2)) AS p50,MIN(value) FILTER(WHERE rank>=DIV(t.n*3+3,4)) AS p75,MIN(value) FILTER(WHERE rank>=DIV(t.n*9+9,10)) AS p90
  FROM groups g LEFT JOIN totals t USING(metric_id,dimensions) LEFT JOIN ranked r USING(metric_id,dimensions)
  GROUP BY g.metric_id,g.dimensions,t.n,t.total
), categories AS ({{categories}})
SELECT metric_id,'summary'::text AS row_kind,dimensions,jsonb_build_object('n',n::text,'sum',total::text,'mean_numerator',total::text,
  'mean_denominator',CASE WHEN n>0 THEN n::text END,'min',minimum::text,'max',maximum::text,'p10',p10::text,'p25',p25::text,'p50',p50::text,'p75',p75::text,'p90',p90::text) AS values FROM summaries
UNION ALL
SELECT g.metric_id,'eligibility_counts',g.dimensions||jsonb_build_object('eligibility_reason',c.reason),
  jsonb_build_object(c.measure,COUNT(s.reason)::text)
FROM groups g JOIN categories c USING(metric_id) LEFT JOIN samples s ON s.metric_id=g.metric_id AND s.dimensions=g.dimensions AND s.reason=c.reason
GROUP BY g.metric_id,g.dimensions,c.reason,c.measure
