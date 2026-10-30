-- PostgreSQL interval union, not daily person expansion. Inputs are validated
-- schema/date tokens; only the bounded aggregate outputs leave the database.
WITH params AS (
  SELECT DATE '{{start}}' AS window_start, DATE '{{end}}' AS window_end
), distinct_intervals AS (
  SELECT DISTINCT person_id, observation_period_start_date AS start_date,
    observation_period_end_date AS end_date
  FROM "{{schema}}".observation_period
), ordered AS (
  SELECT *, MAX(end_date) OVER (PARTITION BY person_id ORDER BY start_date, end_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS previous_end
  FROM distinct_intervals
), islands AS (
  SELECT *, SUM(CASE WHEN previous_end IS NULL OR start_date - previous_end > 1
    THEN 1 ELSE 0 END) OVER (PARTITION BY person_id ORDER BY start_date, end_date
    ROWS UNBOUNDED PRECEDING) AS island
  FROM ordered
), merged AS (
  SELECT person_id, MIN(start_date) AS start_date, MAX(end_date) AS end_date
  FROM islands GROUP BY person_id, island
), observed_intervals AS (
  SELECT person_id, GREATEST(start_date, window_start) AS start_date,
    LEAST(end_date, window_end) AS end_date
  FROM merged, params WHERE start_date <= window_end AND end_date >= window_start
)
