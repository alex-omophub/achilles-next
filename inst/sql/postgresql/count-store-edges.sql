WITH children AS (
    SELECT row_key, person_count, dimensions AS d
    FROM __STORE__.achillesnext_aggregate_cell
    WHERE release_id = __RELEASE__ AND metric_id = __METRIC__
), expected AS (
    SELECT row_key, person_count, __TARGET_DIMS__ AS dims, __TARGET_KEY__ AS target_key
    FROM children
    WHERE __WHEN__
)
INSERT INTO __STORE__.achillesnext_denominator_edge
    (release_id, metric_id, row_key, measure_key, target_metric_id, target_row_key, target_measure_key)
SELECT __RELEASE__, __METRIC__, e.row_key, 'person_count', __TARGET__,
       CASE WHEN t.dimensions = e.dims AND t.route_key = 'A' AND t.payload_kind = 'counts'
             AND t.state IN ('computed','empty_source','empty_population')
             AND e.person_count <= t.person_count THEN t.row_key END,
       'person_count'
FROM expected e
LEFT JOIN __STORE__.achillesnext_aggregate_cell t
  ON t.release_id = __RELEASE__ AND t.metric_id = __TARGET__ AND t.row_key = e.target_key
