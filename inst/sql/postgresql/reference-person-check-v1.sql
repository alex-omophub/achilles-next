-- PERSON membership requires non-null, unique IDs; NULL gender remains a stratum.
SELECT jsonb_build_object('valid',count(*)=count(person_id) AND count(*)=count(DISTINCT person_id),
  'source_count',count(*)::text)::text
FROM {{cdm_schema}}.person
