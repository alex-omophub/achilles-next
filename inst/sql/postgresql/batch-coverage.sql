WITH periods AS ({{periods}})
SELECT p.kind,p.start_date::text AS period_start,p.end_date::text AS period_end,
  COUNT(DISTINCT i.person_id)::text AS people,
  COALESCE(SUM(CASE WHEN i.person_id IS NULL THEN 0 WHEN p.kind='full' THEN i.end_date-i.start_date+1
    ELSE LEAST(i.end_date,p.end_date)-GREATEST(i.start_date,p.start_date)+1 END),0)::text AS person_days
FROM periods p LEFT JOIN intervals i ON p.kind='full' OR (i.start_date<=p.end_date AND i.end_date>=p.start_date)
GROUP BY p.kind,p.start_date,p.end_date ORDER BY p.kind,p.start_date
