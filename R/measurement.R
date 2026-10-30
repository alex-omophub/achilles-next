.measurement_ids <- paste0("measurement.", c("record_count", "person_count", "representation_count", "unit_count",
  "operator_count", "numeric_eligibility_count", "numeric_summary"))
.measurement_cte <- function(schema, request) {
  .check_request(request, request$source_id)
  path <- system.file("sql/postgresql/classified-measurements.sql", package = "AchillesNext", mustWork = TRUE)
  sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
  replacements <- list(schema = schema, concepts = paste(vapply(request$measurement_concept_ids,
    function(x) paste0("(", format(x, scientific = FALSE, trim = TRUE), ")"), ""), collapse = ","), membership = .observation_membership())
  for (key in names(replacements)) sql <- gsub(paste0("{{", key, "}}"), replacements[[key]], sql, fixed = TRUE)
  paste0(.observation_cte(schema, request$window), "\n", sql)
}
.numeric_strategy_sql <- function(numericStrategy) {
  if (!.string(numericStrategy) || !numericStrategy %in% c("reference", "weighted"))
    stop("numericStrategy must be reference or weighted", call. = FALSE)
  path <- system.file(paste0("sql/postgresql/numeric-", numericStrategy, ".sql"), package = "AchillesNext", mustWork = TRUE)
  paste(readLines(path, warn = FALSE), collapse = "\n")
}
.numeric_ctes <- function(numericStrategy, materialized = FALSE) {
  strategy <- .numeric_strategy_sql(numericStrategy)
  names <- c("numeric-groups", if (!materialized) "numeric-frequencies", "numeric-totals")
  inputs <- vapply(names, function(name) paste(readLines(system.file(paste0("sql/postgresql/", name, ".sql"),
    package = "AchillesNext", mustWork = TRUE), warn = FALSE), collapse = "\n"), "")
  paste(c(inputs, strategy), collapse = "\n")
}
.measurement_sql <- function(schema, request, numericStrategy = "reference", numericOnly = FALSE) {
  numeric <- .numeric_ctes(numericStrategy)
  if (numericOnly) return(paste(.measurement_cte(schema, request), numeric,
    "SELECT dimensions::text AS dimensions, values::text AS values FROM summaries ORDER BY dimensions::text", sep = "\n"))
  sql <- paste(readLines(system.file("sql/postgresql/measurement-report.sql", package = "AchillesNext", mustWork = TRUE), warn = FALSE), collapse = "\n")
  paste(.measurement_cte(schema, request), gsub("{{numeric_summary}}", numeric, sql, fixed = TRUE), sep = "\n")
}
.measurement_compute <- function(query, execute, schema, request, observed, numericStrategy = "reference") {
  unknown <- .unknown("Local vocabulary release metadata is absent, inaccessible or ambiguous")
  if (observed$state != "computed") return(list(state = observed$state,
    reason = paste0("Observation prerequisite: ", observed$reason), vocabulary = unknown, terms = list()))
  execute("SAVEPOINT measurement_step")
  on.exit(execute("RELEASE SAVEPOINT measurement_step"), add = TRUE)
  outcome <- tryCatch({
    required <- list(measurement = c(person_id = "int8|int4", measurement_concept_id = "int4", measurement_date = "date",
      value_as_number = "numeric", value_as_concept_id = "int4", value_source_value = "varchar|text",
      unit_concept_id = "int4", operator_concept_id = "int4"),
      concept = c(concept_id = "int4", concept_name = "varchar|text", domain_id = "varchar|text"))
    for (table in names(required)) {
      columns <- query(paste0("SELECT a.attname AS name,t.typname AS type,CASE WHEN has_column_privilege(c.oid,a.attname,'SELECT') THEN 'true' ELSE 'false' END AS readable ",
        "FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid JOIN pg_type t ON t.oid=a.atttypid ",
        "WHERE n.nspname='", schema, "' AND c.relname='", table, "' AND a.attnum>0 AND NOT a.attisdropped"))
      wanted <- required[[table]]; at <- match(names(wanted), columns$NAME)
      if (anyNA(at)) return(list(state = "unavailable", reason = paste("Required", table, "table or columns are missing"), vocabulary = unknown, terms = list()))
      if (!all(columns$READABLE[at] == "true")) return(list(state = "inaccessible", reason = paste("Required", table, "columns cannot be read"), vocabulary = unknown, terms = list()))
      if (!all(vapply(seq_along(at), function(i) grepl(paste0("^(", wanted[i], ")$"), columns$TYPE[at[i]]), TRUE)))
        return(list(state = "failed", reason = paste("Unsupported", table, "column types; exact NUMERIC, integer identifiers and DATE are required"), vocabulary = unknown, terms = list()))
    }
    ids <- paste(vapply(request$measurement_concept_ids, function(x) format(x, scientific = FALSE, trim = TRUE), ""), collapse = ",")
    invalid <- query(paste0('SELECT COUNT(*)::text AS invalid FROM "', schema, '".measurement m WHERE m.measurement_concept_id IN (', ids,
      ") AND m.measurement_date BETWEEN DATE '", request$window$start, "' AND DATE '", request$window$end, "' AND (m.person_id IS NULL OR NOT EXISTS (SELECT 1 FROM \"", schema, '\".person p WHERE p.person_id=m.person_id))'))
    if (!identical(invalid$INVALID, "0")) return(list(state = "failed", reason = "Selected in-window measurements have null or orphan person IDs", vocabulary = unknown, terms = list()))
    cte <- .measurement_cte(schema, request)
    conflict <- query(paste0(cte, " SELECT COUNT(*)::text AS invalid FROM (SELECT concept_id FROM local_concepts GROUP BY concept_id HAVING COUNT(*)>1) c"))
    if (!identical(conflict$INVALID, "0")) return(list(state = "failed", reason = "Conflicting local concept labels or domains", vocabulary = unknown, terms = list()))
    # Domain membership defines numeric eligibility. A missing display name is
    # invalid summary metadata, not an unknown-unit observation. Fail this atomic
    # step rather than drop eligible records or fabricate a local unit label.
    unnamed <- query(paste0(cte, " SELECT COUNT(*)::text AS invalid FROM eligible_measurements m JOIN local_concepts c ON c.concept_id=m.unit_concept_id ",
      "WHERE c.concept_id>0 AND c.domain_id='Unit' AND (m.operator_concept_id IS NULL OR m.operator_concept_id=0) ",
      "AND (c.concept_name IS NULL OR btrim(c.concept_name,E' \\t\\r\\n')='')"))
    if (!identical(unnamed$INVALID, "0")) return(list(state = "failed", reason = "Local Unit-domain concepts used by numeric summaries have missing or blank names", vocabulary = unknown, terms = list()))
    termRows <- query(paste0(cte, " SELECT t.concept_id::text AS id,c.concept_name AS name,c.domain_id AS domain FROM term_ids t LEFT JOIN local_concepts c USING(concept_id) WHERE t.concept_id BETWEEN 0 AND 2147483647 ORDER BY t.concept_id"))
    terms <- lapply(seq_len(nrow(termRows)), function(i) {
      available <- !is.na(termRows$NAME[i]) && nzchar(trimws(termRows$NAME[i])) && !is.na(termRows$DOMAIN[i]) && nzchar(trimws(termRows$DOMAIN[i]))
      .object(concept_id = as.integer(termRows$ID[i]), state = if (available) "available" else "unknown",
        concept_name = if (available) termRows$NAME[i] else NULL, domain_id = if (available) termRows$DOMAIN[i] else NULL,
        reason = if (available) NULL else "No unambiguous name and domain in the local CONCEPT table")
    })
    results <- query(.measurement_sql(schema, request, numericStrategy))
    if (nrow(results) != 7L || !setequal(results$METRIC, .measurement_ids)) stop("Incomplete measurement reference result")
    rows <- stats::setNames(lapply(results$ROWS, jsonlite::fromJSON, simplifyVector = FALSE), results$METRIC)
    # Optional metadata has its own savepoint; denied/missing metadata never turns
    # into a fabricated release or aborts valid measurement calculations.
    execute("SAVEPOINT vocabulary_metadata")
    vocabulary <- tryCatch({
      versions <- query(paste0('SELECT DISTINCT vocabulary_version AS version FROM "', schema, '".cdm_source'))$VERSION
      if (length(versions) == 1L && !is.na(versions) && nzchar(trimws(versions)))
        .object(state = "known", id = paste0("declared:", versions), reason = NULL) else unknown
    }, error = function(e) {execute("ROLLBACK TO SAVEPOINT vocabulary_metadata"); unknown})
    execute("RELEASE SAVEPOINT vocabulary_metadata")
    list(state = "computed", rows = rows, vocabulary = vocabulary, terms = terms)

  }, error = function(e) {
    execute("ROLLBACK TO SAVEPOINT measurement_step")
    list(state = "failed", reason = "Measurement reference query failed; verify required columns, exact types and access", vocabulary = unknown, terms = list())
  })
  outcome
}

#' Generate a bounded synthetic measurement reference report
#' @export
generateMeasurementReport <- function(connectionDetails, cdmSchema, sourceId, outputDir, request, declaredCdmVersion, numericStrategy = "reference") {
  .numeric_strategy_sql(numericStrategy) # Reject unsupported strategies before connecting or writing.
  .generate_tracer(connectionDetails, cdmSchema, sourceId, outputDir, request, declaredCdmVersion, observation = TRUE, measurement = TRUE, numericStrategy = numericStrategy)
}
.measurement_documents <- function(documents, common, measured, observed, count) {
  if (measured$state != "computed") {
    for (id in .measurement_ids) documents[[id]] <- c(common, .object(metric_id = id, metric_version = "1.0.0",
      state = measured$state, reason = measured$reason, rows = NULL))
    return(documents)
  }
  windowPeople <- observed$rows$COUNT[observed$rows$METRIC == "people"]
  monthly <- observed$rows[observed$rows$METRIC == "month", , drop = FALSE]
  monthlyPeople <- stats::setNames(monthly$COUNT, monthly$MONTH)
  peopleFor <- function(d) if (d$period_kind == "window") windowPeople else
    unname(monthlyPeople[[paste0(substr(d$period_start, 1, 7), "-01")]])
  baseKey <- function(d) paste(d$measurement_concept_id, d$period_kind, d$period_start, d$period_end, sep = ":")
  records <- measured$rows[["measurement.record_count"]]
  recordCounts <- stats::setNames(vapply(records, function(r) r$values$count, ""), vapply(records, function(r) baseKey(r$dimensions), ""))
  stateFor <- function(people) if (count == "0") "empty_source" else if (people == "0") "empty_population" else "computed"
  reasonFor <- function(state) if (state == "empty_source") "Accessible PERSON is empty" else if (state == "empty_population") "No eligible population in this stratum" else NULL
  for (id in .measurement_ids) {
    rows <- lapply(measured$rows[[id]], function(r) {
      d <- r$dimensions; summary <- id == "measurement.numeric_summary"
      state <- if (summary) stateFor(r$values$n) else stateFor(peopleFor(d))
      denominator <- if (summary) .object(metric_id = id, dimensions = d, field = "n", value = r$values$n) else NULL
      if (id == "measurement.person_count") denominator <- if (d$period_kind == "window")
        .object(metric_id = "observation.person_count", dimensions = .object(), field = "count", value = windowPeople) else
        .object(metric_id = "observation.monthly_person_count", dimensions = .object(month = paste0(substr(d$period_start, 1, 7), "-01")), field = "count", value = peopleFor(d))
      if (!id %in% c("measurement.person_count", "measurement.record_count", "measurement.numeric_summary")) {
        base <- d[c("measurement_concept_id", "period_kind", "period_start", "period_end")]
        target <- unname(recordCounts[[baseKey(base)]])
        if (length(target) != 1L) stop("Missing measurement denominator", call. = FALSE)
        denominator <- .object(metric_id = "measurement.record_count", dimensions = base, field = "count", value = target)
      }
      .object(dimensions = d, denominator = denominator, state = state, reason = reasonFor(state), values = r$values)
    })
    state <- if (id == "measurement.numeric_summary") {
      if (count == "0") "empty_source" else if (!any(vapply(rows, function(r) r$state == "computed", TRUE))) "empty_population" else "computed"
    } else stateFor(windowPeople)
    documents[[id]] <- c(common, .object(metric_id = id, metric_version = "1.0.0", state = state, reason = reasonFor(state), rows = rows))
  }
  documents
}
