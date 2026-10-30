# Live, marked synthetic PostgreSQL tests; temporary changes use a disposable schema.
suppressPackageStartupMessages(library(AchillesNext))
main <- function() {
  source("tools/benchmark/implementation_identity.R", local = TRUE)
  implementation <- implementationIdentity(getwd())
  args <- commandArgs(TRUE)
  if (length(args) != 2L) stop("Usage: measurement.R <fixture-config.R> <new-artifact-parent>")
  env <- new.env(parent = globalenv()); sys.source(args[1], env)
  if (!dir.create(args[2], mode = "0700")) stop("Test artifact parent must be new")
  read <- function(name, metric) jsonlite::fromJSON(file.path(args[2], name, "results", paste0(metric, ".json")), simplifyVector = FALSE)
  strategy <- Sys.getenv("ACHILLES_NEXT_TEST_NUMERIC_STRATEGY", "reference")
  generate <- function(name, cfg) do.call(generateMeasurementReport, c(cfg, list(outputDir = file.path(args[2], name), numericStrategy = strategy)))
  windowRows <- function(name, metric, concept = 900000001L) Filter(function(r) r$dimensions$measurement_concept_id == concept &&
    (is.null(r$dimensions$period_kind) || r$dimensions$period_kind == "window"), read(name, metric)$rows)
  # Compare exact decimal text by removing only insignificant trailing zeros.
  decimal <- function(x) if (!is.null(x) && grepl(".", x, fixed = TRUE)) sub("[.]$", "", sub("0+$", "", x)) else x
  exactValues <- function(actual, expected) stopifnot(setequal(names(actual), names(expected)),
    all(vapply(names(expected), function(k) identical(decimal(actual[[k]]), decimal(expected[[k]])), TRUE)))
  oracle <- jsonlite::fromJSON("tests/fixtures/analysis/alpha-oracle.json", simplifyVector = FALSE)
  for (case in oracle$cases) for (version in case$schema_versions) {
    cfg <- env$config; cfg$request <- case$request; cfg$sourceId <- case$request$source_id
    cfg$cdmSchema <- paste0("cdm_", case$fixture_source, "_", gsub(".", "", version, fixed = TRUE)); cfg$declaredCdmVersion <- version
    name <- paste0(case$id, "-", version); generate(name, cfg)
    for (id in c("source.capabilities", "execution.output_status", "execution.timing")) {
      reserved <- read(name, id)
      stopifnot(reserved$state == "unsupported", is.null(reserved$rows),
        reserved$reason == "Not implemented by the measurement development generator")
    }
    for (metric in c("record_count", "person_count")) {
      expected <- if (metric == "record_count") case$expected$records_by_concept else case$expected$people_by_concept
      for (id in names(expected)) stopifnot(windowRows(name, paste0("measurement.", metric), as.integer(id))[[1]]$values$count == expected[[id]])
    }
    maps <- list(numeric_eligibility_count = c("eligibility_reason", "primary_eligibility_nonzero"),
      unit_count = c("raw_unit_tag", "primary_unit_nonzero"), operator_count = c("raw_operator_tag", "primary_operator_nonzero"),
      representation_count = c("flags", "primary_representation_nonzero"))
    for (metric in names(maps)) {
      rows <- Filter(function(r) r$values$count != "0", windowRows(name, paste0("measurement.", metric)))
      key <- function(r) if (maps[[metric]][1] == "flags") paste0(as.integer(unlist(r$dimensions[c("numeric_present", "coded_present", "source_text_present")])), collapse = "") else r$dimensions[[maps[[metric]][1]]]
      actual <- stats::setNames(lapply(rows, function(r) r$values$count), vapply(rows, key, ""))
      stopifnot(identical(AchillesNext:::.json(actual), AchillesNext:::.json(case$expected[[maps[[metric]][2]]])))
    }
    summary <- windowRows(name, "measurement.numeric_summary")
    if (is.null(case$expected$primary_numeric_summary)) stopifnot(length(summary) == 0L) else {
      stopifnot(length(summary) == 1L); exactValues(summary[[1]]$values, case$expected$primary_numeric_summary)
    }
    terms <- jsonlite::fromJSON(file.path(args[2], name, "terminology.json"), simplifyVector = FALSE)
    stopifnot(terms$provider_id == "local-concept-table", terms$vocabulary_release$id == "declared:fixture-1",
      any(vapply(terms$concepts, function(c) c$concept_id == 900000001L && c$state == "available", TRUE)))
  }
  # Exercise the declared request ceiling end-to-end, including dense zeros.
  bounded <- env$config; bounded$request$measurement_concept_ids <- as.list(c(0L,900000001L,900000002L,900000010:900000016))
  bounded$request$window <- list(start = "2016-01-01", end = "2025-12-31")
  generate("maximum-bounded-request", bounded)
  stopifnot(length(read("maximum-bounded-request", "measurement.record_count")$rows) == 1210L,
    length(read("maximum-bounded-request", "measurement.representation_count")$rows) == 9680L,
    length(read("maximum-bounded-request", "measurement.numeric_eligibility_count")$rows) == 8470L)
  owner <- DatabaseConnector::connect(env$fixtureConnection("owner"))
  on.exit(DatabaseConnector::disconnect(owner), add = TRUE)
  errorFile <- tempfile("measurement-error-"); on.exit(unlink(errorFile), add = TRUE)
  query <- function(sql) DatabaseConnector::querySql(owner, sql, errorReportFile = errorFile, integer64AsNumeric = FALSE)
  execute <- function(sql) DatabaseConnector::executeSql(owner, sql, errorReportFile = errorFile, progressBar = FALSE, reportOverallTime = FALSE)
  guard <- query("SELECT current_database() AS db, shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(identical(guard$DB, "achilles_next_fixtures"), identical(guard$MARKER, "AchillesNext synthetic fixture sandbox v1"))
  schema <- paste0("cdm_tiny_measurement_", Sys.getpid(), "_55")
  table <- function(name) paste0('"', schema, '".', name)
  execute(paste0('CREATE SCHEMA "', schema, '"; COMMENT ON SCHEMA "', schema, '" IS \'AchillesNext synthetic fixture sandbox v1: ', schema,
    '\'; CREATE TABLE ', table("person"), '(person_id bigint); INSERT INTO ', table("person"), ' VALUES (1); CREATE TABLE ', table("observation_period"),
    "(person_id bigint,observation_period_start_date date,observation_period_end_date date); INSERT INTO ", table("observation_period"),
    " VALUES (1,'2020-01-01','2020-01-31'),(1,'2020-01-01','2020-01-31'),(1,'2020-01-10','2020-01-20'); CREATE TABLE ", table("measurement"),
    '(measurement_id bigint,person_id bigint,measurement_concept_id integer,measurement_date date,value_as_number numeric,unit_concept_id integer,operator_concept_id integer,value_as_concept_id integer,value_source_value text); CREATE TABLE ', table("concept"),
    '(concept_id integer,concept_name text,domain_id text); INSERT INTO ', table("concept"),
    " VALUES (900000001,'Synthetic test','Measurement'),(900000101,'Unit one','Unit'),(900000102,'Unit two','Unit'),(900000103,'Empty numeric unit','Unit'),(900000201,'Equals','Meas Value Operator'),(900000301,'Coded value','Meas Value'); GRANT USAGE ON SCHEMA \"", schema,
    '" TO achilles_next_runner; GRANT SELECT ON ALL TABLES IN SCHEMA "', schema, '" TO achilles_next_runner'))
  on.exit(execute(paste0('DROP SCHEMA "', schema, '" CASCADE')), add = TRUE, after = FALSE)
  cfg <- env$config; cfg$cdmSchema <- schema; cfg$sourceId <- "fixture:measurement-edge"; cfg$request$source_id <- cfg$sourceId
  cfg$request$window <- list(start = "2020-01-01", end = "2020-01-31")
  edge <- jsonlite::fromJSON("tests/fixtures/analysis/numeric-edge-oracle.json", simplifyVector = FALSE)
  sqlValue <- function(x) if (is.null(x)) "NULL" else paste0("'", x, "'")
  for (r in edge$rows) execute(paste0('INSERT INTO ', table("measurement"), " VALUES (1,1,900000001,'2020-01-15',",
    paste(vapply(r[c("value_as_number", "unit_concept_id", "operator_concept_id")], sqlValue, ""), collapse = ","), ",NULL,NULL)"))
  generate("numeric-edges", cfg)
  stopifnot(windowRows("numeric-edges", "measurement.record_count")[[1]]$values$count == "16")
  eligibility <- windowRows("numeric-edges", "measurement.numeric_eligibility_count")
  expected <- base::table(unlist(edge$expected$eligibility_by_record))
  for (r in eligibility) stopifnot(r$values$count == if (r$dimensions$eligibility_reason %in% names(expected)) as.character(expected[[r$dimensions$eligibility_reason]]) else "0")
  for (r in windowRows("numeric-edges", "measurement.numeric_summary")) {
    expected <- edge$expected$strata[[paste0("id:", r$dimensions$unit_concept_id, "|", r$dimensions$raw_operator_tag)]]
    exactValues(r$values[c("n", "sum", "p50")], expected[c("n", "sum", "p50")])
  }
  # Read exactly the required fields: access to unrelated source columns is not
  # needed, and identical duplicate local metadata must not multiply events.
  execute(paste0('REVOKE SELECT ON ', table("measurement"), ' FROM achilles_next_runner; GRANT SELECT(person_id,measurement_concept_id,measurement_date,value_as_number,unit_concept_id,operator_concept_id,value_as_concept_id,value_source_value) ON ', table("measurement"), ' TO achilles_next_runner; INSERT INTO ', table("concept"), " VALUES (900000101,'Unit one','Unit')"))
  generate("column-access", cfg)
  stopifnot(windowRows("column-access", "measurement.record_count")[[1]]$values$count == "16")
  execute(paste0('REVOKE SELECT(person_id,measurement_concept_id,measurement_date,value_as_number,unit_concept_id,operator_concept_id,value_as_concept_id,value_source_value) ON ', table("measurement"), ' FROM achilles_next_runner; GRANT SELECT ON ', table("measurement"), ' TO achilles_next_runner'))
  # All eight representations, space-only vs a literal tab, zero/unmapped coded
  # values and an observed valid-unit group with no finite numeric population.
  execute(paste0('TRUNCATE ', table("measurement")))
  for (n in c(FALSE, TRUE)) for (c in c(FALSE, TRUE)) for (t in c(FALSE, TRUE)) execute(paste0('INSERT INTO ', table("measurement"),
    " VALUES (1,1,900000001,'2020-01-01',", if (n) "10" else "NULL", ",900000101,0,", if (c) "999999999" else "0", ",", if (t) "E'\\t'" else "'   '", ")"))
  execute(paste0('INSERT INTO ', table("measurement"), " VALUES (1,1,900000001,'2020-01-31',NULL,900000103,NULL,NULL,NULL)"))
  generate("representations", cfg)
  reps <- windowRows("representations", "measurement.representation_count")
  stopifnot(length(reps) == 8L, all(vapply(reps, function(r) as.integer(r$values$count) >= 1L, TRUE)))
  summary <- windowRows("representations", "measurement.numeric_summary")
  zero <- Filter(function(r) r$dimensions$unit_concept_id == 900000103L, summary)[[1]]
  stopifnot(zero$state == "empty_population", zero$values$n == "0", all(vapply(zero$values[names(zero$values) != "n"], is.null, TRUE)))
  # No selected events with an observed denominator is computed zero, not an
  # empty population; local unknown concepts remain selectable without expansion.
  emptyCfg <- cfg; emptyCfg$request$measurement_concept_ids <- list(999999999L)
  generate("unobserved-concept", emptyCfg)
  stopifnot(read("unobserved-concept", "measurement.record_count")$state == "computed", windowRows("unobserved-concept", "measurement.record_count", 999999999L)[[1]]$values$count == "0")
  for (date in c("0001-01-01", "9999-12-31")) {
    dateCfg <- cfg; dateCfg$request$window <- list(start = date, end = date)
    generate(paste0("calendar-", date), dateCfg)
    stopifnot(read(paste0("calendar-", date), "measurement.record_count")$state == "empty_population")
  }
  execute(paste0('UPDATE ', table("concept"), " SET domain_id='Measurement' WHERE concept_id=900000101"))
  generate("wrong-unit-domain", cfg)
  stopifnot(all(vapply(windowRows("wrong-unit-domain", "measurement.numeric_summary"), function(r) r$dimensions$unit_concept_id != 900000101L, TRUE)))
  execute(paste0('UPDATE ', table("concept"), " SET domain_id='Unit' WHERE concept_id=900000101; TRUNCATE ", table("observation_period")))
  generate("empty-observation", cfg)
  for (id in AchillesNext:::.measurement_ids) stopifnot(read("empty-observation", id)$state == "empty_population")
  execute(paste0('TRUNCATE ', table("measurement"), ',', table("person")))
  generate("empty-source", cfg)
  for (id in AchillesNext:::.measurement_ids) stopifnot(read("empty-source", id)$state == "empty_source")
  execute(paste0('INSERT INTO ', table("person"), " VALUES (1); INSERT INTO ", table("observation_period"), " VALUES (1,'2020-01-01','2020-01-31'); INSERT INTO ", table("measurement"), " VALUES (1,1,900000001,'2020-01-15',1,900000101,0,NULL,NULL)"))
  expectState <- function(name, state) {
    generate(name, cfg)
    for (id in AchillesNext:::.measurement_ids) stopifnot(read(name, id)$state == state, is.null(read(name, id)$rows), nzchar(read(name, id)$reason))
    stopifnot(read(name, "person.count")$rows[[1]]$values$count == "1", read(name, "observation.person_count")$state == "computed")
  }
  for (i in seq_along(c("'   '", "E'\\t\\r\\n'", "NULL"))) {
    literal <- c("'   '", "E'\\t\\r\\n'", "NULL")[i]
    execute(paste0('UPDATE ', table("concept"), ' SET concept_name=', literal, ' WHERE concept_id=900000101'))
    cte <- AchillesNext:::.measurement_cte(schema, cfg$request)
    classified <- query(paste0(cte, " SELECT COUNT(*) FILTER (WHERE eligibility_reason='eligible')::text AS n FROM classified"))
    stopifnot(classified$N == "1") # Local domain, not its display label, defines eligibility.
    name <- paste0("unnamed-unit-", i); expectState(name, "failed")
    stopifnot(grepl("missing or blank names", read(name, "measurement.numeric_summary")$reason, fixed = TRUE))
  }
  execute(paste0('UPDATE ', table("concept"), " SET concept_name='Unit one' WHERE concept_id=900000101; UPDATE ", table("concept"), " SET concept_name=NULL WHERE concept_id=900000001"))
  generate("unnamed-measurement", cfg)
  stopifnot(windowRows("unnamed-measurement", "measurement.record_count")[[1]]$values$count == "1",
    windowRows("unnamed-measurement", "measurement.numeric_summary")[[1]]$values$n == "1")
  execute(paste0('UPDATE ', table("concept"), " SET concept_name='Synthetic test' WHERE concept_id=900000001"))
  execute(paste0('INSERT INTO ', table("measurement"), " VALUES (1,99,900000001,'2020-01-15',1,900000101,0,NULL,NULL)")); expectState("orphan", "failed")
  execute(paste0('UPDATE ', table("measurement"), ' SET person_id=NULL WHERE person_id=99')); expectState("null-person", "failed")
  execute(paste0('DELETE FROM ', table("measurement"), ' WHERE person_id IS NULL; INSERT INTO ', table("concept"), " VALUES (900000101,'Conflicting label','Unit')")); expectState("conflicting-terms", "failed")
  execute(paste0('DELETE FROM ', table("concept"), " WHERE concept_name='Conflicting label'; REVOKE SELECT ON ", table("measurement"), ' FROM achilles_next_runner')); expectState("denied", "inaccessible")
  execute(paste0('GRANT SELECT ON ', table("measurement"), ' TO achilles_next_runner; REVOKE SELECT ON ', table("concept"), ' FROM achilles_next_runner')); expectState("denied-terminology", "inaccessible")
  execute(paste0('GRANT SELECT ON ', table("concept"), ' TO achilles_next_runner; ALTER TABLE ', table("measurement"), ' ALTER COLUMN value_as_number TYPE double precision')); expectState("float-source", "failed")
  execute(paste0('ALTER TABLE ', table("measurement"), ' DROP COLUMN value_source_value')); expectState("missing-column", "unavailable")
  stopifnot(identical(implementation, implementationIdentity(getwd())))
  cat("PASS: 15 source/version/window measurement oracles; 16 numeric edge rows; eight representations; exact precision; zero-n; duplicate events/intervals; bounded calendars; missing/denied/type/integrity failures; stable executed implementation identity\n")
}
main()
