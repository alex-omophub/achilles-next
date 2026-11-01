WITH valid AS (
  SELECT DISTINCT o.person_id,o.observation_period_start_date AS start_date,
    o.observation_period_end_date AS end_date
  FROM "{{schema}}".observation_period o
  WHERE o.person_id IS NOT NULL AND EXISTS (SELECT 1 FROM "{{schema}}".person p WHERE p.person_id=o.person_id)
    AND o.observation_period_start_date IS NOT NULL AND o.observation_period_end_date IS NOT NULL
    AND o.observation_period_start_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31'
    AND o.observation_period_end_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31'
    AND o.observation_period_start_date<=o.observation_period_end_date
), ordered AS (
  SELECT *,MAX(end_date) OVER (PARTITION BY person_id ORDER BY start_date,end_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS previous_end FROM valid
), islands AS (
  SELECT *,SUM(CASE WHEN previous_end IS NULL OR start_date-previous_end>1 THEN 1 ELSE 0 END)
    OVER (PARTITION BY person_id ORDER BY start_date,end_date ROWS UNBOUNDED PRECEDING) AS island FROM ordered
)
SELECT person_id,MIN(start_date) AS start_date,MAX(end_date) AS end_date FROM islands GROUP BY person_id,island
