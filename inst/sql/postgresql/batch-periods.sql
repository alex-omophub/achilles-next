SELECT 'full'::text AS kind,NULL::date AS start_date,NULL::date AS end_date
UNION ALL SELECT 'window',DATE '{{start}}',DATE '{{end}}'
UNION ALL SELECT 'month',GREATEST(d::date,DATE '{{start}}'),LEAST((d+INTERVAL '1 month - 1 day')::date,DATE '{{end}}')
  FROM generate_series(date_trunc('month',DATE '{{start}}'),date_trunc('month',DATE '{{end}}'),INTERVAL '1 month') d
UNION ALL SELECT 'year',GREATEST(d::date,DATE '{{start}}'),LEAST((d+INTERVAL '1 year - 1 day')::date,DATE '{{end}}')
  FROM generate_series(date_trunc('year',DATE '{{start}}'),date_trunc('year',DATE '{{end}}'),INTERVAL '1 year') d
