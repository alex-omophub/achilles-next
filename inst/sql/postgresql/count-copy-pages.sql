WITH input AS (__INPUT__),
frames AS (
    SELECT ord, n, octet_length(doc) AS size,
           CASE WHEN __SOURCE__ AND doc IS NULL AND n IN (-1,-2,-3) THEN n
                WHEN (doc IS NOT NULL AND octet_length(doc) BETWEEN 1 AND 65536
                      AND key IS NOT NULL AND key ~ '^[0-9a-f]{64}$'
                      AND n BETWEEN 1 AND __MAX_ROW__) IS TRUE THEN 0
                ELSE -4 END AS status,
           int2send(4::smallint) || int4send(octet_length('__MID__')) || convert_to('__MID__','UTF8') ||
           int4send(64) || convert_to(key,'UTF8') ||
           int4send(octet_length(doc)) || doc || int4send(4) || int4send(n::integer) AS native_row
    FROM input
), blocks AS (
    SELECT *, row_number() OVER (ORDER BY ord) AS pos,
           sum(4+coalesce(octet_length(native_row),0)) OVER (ORDER BY ord ROWS UNBOUNDED PRECEDING) AS running_size
    FROM frames
), pages AS (
    SELECT min(ord) AS first_ordinal, count(*)::integer AS row_count,
           sum(n)::bigint AS original_bytes, sum(size)::integer AS frame_bytes,
           (array_agg(status ORDER BY ord) FILTER (WHERE status<>0))[1] AS first_error,
           string_agg(CASE WHEN status=0 THEN int4send(size) END,''::bytea ORDER BY ord) AS lengths,
           string_agg(CASE WHEN status=0 THEN native_row END,''::bytea ORDER BY ord) AS records
    FROM blocks
    -- 458490 leaves space for the largest final row, the metric and the
    -- envelope. A second limit enforces the configured callback row bound.
    GROUP BY (pos-1)/__PAGE_ROWS__, floor((running_size-1)/458490)
)
SELECT CASE WHEN first_error IS NOT NULL THEN int4send(first_error::integer)
            WHEN row_count BETWEEN 1 AND __PAGE_ROWS__ AND 16+octet_length(lengths)+octet_length(records)<=524282
            THEN int4send(row_count)||int8send(original_bytes)||int4send(frame_bytes)||lengths||records
            ELSE int4send(-4) END AS page
FROM pages ORDER BY first_ordinal
