WITH frames AS (
    SELECT key, convert_from(doc, 'UTF8')::jsonb AS j
    FROM pg_temp.count_frames
    WHERE mid = __METRIC__
), decoded AS (
    SELECT key, j, j->'dimensions' AS d, j->'values' AS v FROM frames
)
INSERT INTO __STORE__.achillesnext_aggregate_cell
    (release_id, metric_id, row_key, route_key, sort_key, dimensions, state,
     reason_code, payload_kind, record_count, person_count)
SELECT __RELEASE__, __METRIC__,
       CASE WHEN key = j->>'row_key' AND key = __ROW_KEY__
             AND j->>'row_kind' = 'counts' AND j->'denominator_refs' = '[]'::jsonb
             AND j->>'state' IN ('computed','empty_source','empty_population')
            THEN key END,
       'A', __SORT_KEY__, d, j->>'state', j->>'reason_code', 'counts',
       (v->>'record_count')::numeric, (v->>'person_count')::numeric
FROM decoded
