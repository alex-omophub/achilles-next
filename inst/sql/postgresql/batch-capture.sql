-- Diagnostic primitives, not a complete profile output. Each period performs
-- its own COUNT(DISTINCT); month/year people cannot be added to get the window.
WITH periods AS (
  {{periods}}
), expanded AS (
  SELECT c.*,p.kind,p.start_date,p.end_date FROM classified c JOIN periods p
    ON p.kind='full' OR c.event_date BETWEEN p.start_date AND p.end_date
)
SELECT concept_id::text AS concept_id,kind,start_date::text AS period_start,end_date::text AS period_end,
  COUNT(*)::text AS records,COUNT(DISTINCT person_id) FILTER(WHERE linked_person)::text AS people,
  COUNT(*) FILTER(WHERE observed AND (kind<>'full' OR event_date BETWEEN DATE '{{start}}' AND DATE '{{end}}'))::text AS observed_records,
  COUNT(DISTINCT person_id) FILTER(WHERE observed AND (kind<>'full' OR event_date BETWEEN DATE '{{start}}' AND DATE '{{end}}'))::text AS observed_people
FROM expanded GROUP BY concept_id,kind,start_date,end_date ORDER BY concept_id NULLS FIRST,kind,start_date
