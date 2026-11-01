WITH bounds AS (SELECT {{start}}::date AS lo,{{end}}::date AS hi)
SELECT 'full_scope'::text AS period_kind,lo AS period_start,hi AS period_end,FALSE AS full_calendar_period FROM bounds
UNION ALL
SELECT 'calendar_month',GREATEST(d::date,lo),LEAST((d+INTERVAL '1 month - 1 day')::date,hi),
  lo<=d::date AND hi>=(d+INTERVAL '1 month - 1 day')::date
FROM bounds CROSS JOIN LATERAL generate_series(date_trunc('month',lo),date_trunc('month',hi),INTERVAL '1 month') d
UNION ALL
SELECT 'calendar_year',GREATEST(d::date,lo),LEAST((d+INTERVAL '1 year - 1 day')::date,hi),
  lo<=d::date AND hi>=(d+INTERVAL '1 year - 1 day')::date
FROM bounds CROSS JOIN LATERAL generate_series(date_trunc('year',lo),date_trunc('year',hi),INTERVAL '1 year') d
