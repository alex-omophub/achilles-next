.observation_cte <- function(schema, window) {
  # Also validate internal callers: these tokens are SQL literals/identifiers.
  if (!.string(schema) || !grepl("^cdm_tiny_[a-z0-9_]+_(53|54|55)$", schema) ||
      !all(vapply(window[c("start", "end")], function(x) .string(x) && grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x), TRUE)))
    stop("Invalid observation SQL inputs", call. = FALSE)
  path <- system.file("sql/postgresql/observed-intervals.sql", package = "AchillesNext", mustWork = TRUE)
  sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
  for (key in c("schema", "start", "end")) sql <- gsub(paste0("{{", key, "}}"),
    if (key == "schema") schema else window[[key]], sql, fixed = TRUE)
  sql
}
.observation_membership <- function(alias = "m") {
  if (!.string(alias) || !grepl("^[a-z][a-z0-9_]*$", alias)) stop("Invalid SQL alias", call. = FALSE)
  paste0("EXISTS (SELECT 1 FROM observed_intervals oi WHERE oi.person_id = ", alias,
    ".person_id AND ", alias, ".measurement_date BETWEEN oi.start_date AND oi.end_date)")
}
.observation_compute <- function(query, execute, schema, window) {
  # Savepoints keep an optional observation query failure from aborting the
  # transaction that already established the all-source PERSON count.
  execute("SAVEPOINT observation_step")
  on.exit(execute("RELEASE SAVEPOINT observation_step"), add = TRUE)
  outcome <- tryCatch({
    columns <- query(paste0("SELECT a.attname AS column_name, CASE WHEN has_column_privilege(c.oid,a.attname,'SELECT') THEN 'true' ELSE 'false' END AS readable ",
      "FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid ",
      "WHERE n.nspname='", schema, "' AND c.relname='observation_period' AND a.attnum>0 AND NOT a.attisdropped ",
      "AND a.attname IN ('person_id','observation_period_start_date','observation_period_end_date')"))
    if (nrow(columns) != 3L) return(list(state = "unavailable", reason = "Required observation_period table or columns are missing"))
    if (!all(columns$READABLE %in% "true")) return(list(state = "inaccessible", reason = "Required observation_period columns cannot be read"))
    invalid <- query(paste0('SELECT COUNT(*)::text AS invalid FROM "', schema, '".observation_period o WHERE ',
      'o.person_id IS NULL OR NOT EXISTS (SELECT 1 FROM "', schema, '".person p WHERE p.person_id=o.person_id) OR ',
      "o.observation_period_start_date IS NULL OR o.observation_period_end_date IS NULL OR ",
      "o.observation_period_end_date < o.observation_period_start_date OR ",
      "o.observation_period_start_date NOT BETWEEN DATE '0001-01-01' AND DATE '9999-12-31' OR ",
      "o.observation_period_end_date NOT BETWEEN DATE '0001-01-01' AND DATE '9999-12-31'"))
    if (!identical(invalid$INVALID, "0")) return(list(state = "failed", reason = "Observation integrity failed: null, reversed, out-of-range or orphan intervals"))
    sql <- paste0(.observation_cte(schema, window), ", months AS (\n",
      "SELECT d::date AS month FROM params, LATERAL generate_series(date_trunc('month',window_start::timestamp),",
      "date_trunc('month',window_end::timestamp),interval '1 month') d)\n",
      "SELECT 'people' AS metric, '' AS month, COUNT(DISTINCT person_id)::text AS count FROM observed_intervals\n",
      "UNION ALL SELECT 'days', '', COALESCE(SUM((end_date-start_date+1)::numeric),0)::text FROM observed_intervals\n",
      "UNION ALL SELECT 'month', m.month::text, COUNT(DISTINCT oi.person_id)::text FROM months m\n",
      "LEFT JOIN observed_intervals oi ON oi.start_date <= (m.month+interval '1 month')::date-1 AND oi.end_date >= m.month\n",
      "GROUP BY m.month ORDER BY metric, month")
    rows <- query(sql)
    if (!is.character(rows$COUNT) || anyNA(rows$COUNT) || !all(grepl("^(0|[1-9][0-9]*)$", rows$COUNT)))
      stop("Invalid exact observation result", call. = FALSE)
    list(state = "computed", rows = rows)
  }, error = function(e) {
    execute("ROLLBACK TO SAVEPOINT observation_step")
    list(state = "failed", reason = "Observation query failed; verify required columns, DATE types and access")
  })
  outcome
}

#' Generate an observation-opportunity development bundle
#' @export
generateObservationTracer <- function(connectionDetails, cdmSchema, sourceId, outputDir,
                                      request, declaredCdmVersion) {
  .generate_tracer(connectionDetails, cdmSchema, sourceId, outputDir, request, declaredCdmVersion, observation = TRUE)
}
