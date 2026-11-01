WITH distinct_intervals AS (
  SELECT DISTINCT person_id,start_date,end_date FROM {{raw}} WHERE reason='valid'
), ordered AS (
  SELECT *,MAX(end_date) OVER(PARTITION BY person_id ORDER BY start_date,end_date ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS previous_end
  FROM distinct_intervals
), islands AS (
  SELECT *,SUM(CASE WHEN previous_end IS NULL OR start_date-previous_end>1 THEN 1 ELSE 0 END)
    OVER(PARTITION BY person_id ORDER BY start_date,end_date ROWS UNBOUNDED PRECEDING) AS island FROM ordered
)
SELECT person_id,MIN(start_date) AS start_date,MAX(end_date) AS end_date FROM islands GROUP BY person_id,island
