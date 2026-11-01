WITH counts AS (
  SELECT person_id,COUNT(*)::numeric AS interval_count,SUM((end_date-start_date+1)::numeric) AS total_days,
    MIN(start_date) AS first_start FROM {{intervals}} GROUP BY person_id
), people AS (
  SELECT p.*,COALESCE(c.interval_count,0) AS interval_count,COALESCE(c.total_days,0) AS total_days,
    c.first_start,i.end_date AS first_end,
    CASE WHEN c.first_start IS NULL THEN 'event_date_missing_or_invalid'
      WHEN p.year_of_birth IS NULL OR p.year_of_birth<1 OR p.year_of_birth>9999 THEN 'birth_year_missing_or_invalid'
      WHEN EXTRACT(YEAR FROM c.first_start)::integer-p.year_of_birth NOT BETWEEN 0 AND 130 THEN 'year_age_outside_0_130'
      ELSE 'eligible' END AS age_reason
  FROM {{person}} p LEFT JOIN counts c USING(person_id)
    LEFT JOIN {{intervals}} i ON i.person_id=c.person_id AND i.start_date=c.first_start
)
SELECT *,CASE WHEN age_reason='eligible' THEN EXTRACT(YEAR FROM first_start)::integer-year_of_birth END AS first_age,
  CASE WHEN age_reason='eligible' THEN ((EXTRACT(YEAR FROM first_start)::integer-year_of_birth)/10)::text ELSE 'unknown' END AS first_decile
FROM people
