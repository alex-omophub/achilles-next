# Explicit live test command. Uses marked synthetic fixtures and a disposable schema.
suppressPackageStartupMessages(library(AchillesNext))
main <- function() {
  args <- commandArgs(TRUE)
  if (length(args) != 2L) stop("Usage: observation.R <fixture-config.R> <new-artifact-parent>")
  env <- new.env(parent = globalenv()); sys.source(args[1], env)
  if (!dir.create(args[2], mode = "0700")) stop("Test artifact parent must be new")
  read <- function(name, metric) jsonlite::fromJSON(file.path(args[2], name, "results", paste0(metric, ".json")), simplifyVector = FALSE)
  generate <- function(name, cfg) do.call(generateObservationTracer, c(cfg, list(outputDir = file.path(args[2], name))))
  oracle <- jsonlite::fromJSON("tests/fixtures/analysis/alpha-oracle.json", simplifyVector = FALSE)
  for (case in oracle$cases) for (version in case$schema_versions) {
    cfg <- env$config; cfg$request <- case$request; cfg$sourceId <- case$request$source_id
    cfg$cdmSchema <- paste0("cdm_", case$fixture_source, "_", gsub(".", "", version, fixed = TRUE)); cfg$declaredCdmVersion <- version
    name <- paste0(case$id, "-", version); generate(name, cfg)
    stopifnot(read(name, "person.count")$rows[[1]]$values$count == case$expected$person_count,
      read(name, "observation.person_count")$rows[[1]]$values$count == case$expected$observed_people,
      read(name, "observation.person_days")$rows[[1]]$values$count == case$expected$person_days)
    monthly <- read(name, "observation.monthly_person_count")$rows
    actual <- stats::setNames(lapply(monthly, function(r) r$values$count), vapply(monthly, function(r) r$dimensions$month, ""))
    stopifnot(identical(actual, case$expected$observed_people_by_month))
  }
  owner <- DatabaseConnector::connect(env$fixtureConnection("owner"))
  on.exit(DatabaseConnector::disconnect(owner), add = TRUE)
  errorFile <- tempfile("observation-integration-error-")
  on.exit(unlink(errorFile), add = TRUE)
  query <- function(sql) DatabaseConnector::querySql(owner, sql, errorReportFile = errorFile, integer64AsNumeric = FALSE)
  execute <- function(sql) DatabaseConnector::executeSql(owner, sql, errorReportFile = errorFile, progressBar = FALSE, reportOverallTime = FALSE)
  guard <- query("SELECT current_database() AS db, shobj_description(oid, 'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(identical(guard$DB, "achilles_next_fixtures"), identical(guard$MARKER, "AchillesNext synthetic fixture sandbox v1"))
  schema <- paste0("cdm_tiny_observation_", Sys.getpid(), "_55")
  table <- function(name) paste0('"', schema, '".', name)
  execute(paste0('CREATE SCHEMA "', schema, '"; COMMENT ON SCHEMA "', schema, '" IS \'AchillesNext synthetic fixture sandbox v1: ', schema,
    '\'; CREATE TABLE ', table("person"), '(person_id bigint); CREATE TABLE ', table("observation_period"),
    '(person_id bigint, observation_period_start_date date, observation_period_end_date date); CREATE TABLE ', table("measurement"),
    '(measurement_id bigint, person_id bigint, measurement_date date); GRANT USAGE ON SCHEMA "', schema,
    '" TO achilles_next_runner; GRANT SELECT ON ALL TABLES IN SCHEMA "', schema, '" TO achilles_next_runner; INSERT INTO ', table("person"), ' VALUES (1),(2)'))
  on.exit(execute(paste0('DROP SCHEMA "', schema, '" CASCADE')), add = TRUE, after = FALSE)
  cfg <- env$config; cfg$cdmSchema <- schema; cfg$sourceId <- "fixture:observation-edge"; cfg$request$source_id <- cfg$sourceId
  cfg$request$window <- list(start = "2020-01-15", end = "2020-02-03")
  execute(paste0('INSERT INTO ', table("observation_period"), " VALUES ",
    "(1,'2020-01-01','2020-01-31'),(1,'2020-01-01','2020-01-31'),(1,'2020-01-05','2020-01-06'),",
    "(1,'2020-01-07','2020-01-08'),(1,'2020-01-10','2020-01-20'),(1,'2020-02-01','2020-02-01'),",
    "(1,'2020-02-03','2020-02-03'),(2,'2020-01-31','2020-02-02'); INSERT INTO ", table("measurement"),
    " VALUES (1,1,'2020-01-14'),(2,1,'2020-01-15'),(2,1,'2020-01-15'),(3,1,'2020-01-31'),",
    "(4,1,'2020-02-01'),(5,1,'2020-02-02'),(6,1,'2020-02-03'),(7,2,'2020-02-02')"))
  generate("nested-and-adjacent", cfg)
  stopifnot(read("nested-and-adjacent", "observation.person_count")$rows[[1]]$values$count == "2",
    read("nested-and-adjacent", "observation.person_days")$rows[[1]]$values$count == "22",
    identical(vapply(read("nested-and-adjacent", "observation.monthly_person_count")$rows, function(r) r$values$count, ""), c("2", "2")))
  # Two queries must share one repeatable-read snapshot despite concurrent writes.
  execute(paste0('GRANT INSERT ON ', table("person"), ' TO achilles_next_runner'))
  # Unwind the runner before main's DROP SCHEMA, including assertion failures.
  (function() {
    runner <- DatabaseConnector::connect(cfg$connectionDetails)
    session <- NULL
    on.exit({
      if (!is.null(session)) try(session$rollback(), silent = TRUE)
      DatabaseConnector::disconnect(runner)
    }, add = TRUE)
    session <- AchillesNext:::.tracer_session(runner)
    before <- session$query(paste0("SELECT COUNT(*)::text AS n, txid_current()::text AS xid, current_setting('transaction_read_only') AS ro, current_setting('transaction_isolation') AS isolation FROM ", table("person")))
    execute(paste0('INSERT INTO ', table("person"), ' VALUES (3)'))
    after <- session$query(paste0("SELECT COUNT(*)::text AS n, txid_current()::text AS xid, current_setting('transaction_read_only') AS ro, current_setting('transaction_isolation') AS isolation FROM ", table("person")))
    stopifnot(identical(before, after), before$N == "2", before$RO == "on", before$ISOLATION == "repeatable read")
    session$execute("SAVEPOINT write_probe")
    denied <- tryCatch({session$execute(paste0('INSERT INTO ', table("person"), ' VALUES (4)')); FALSE}, error = function(e) TRUE)
    stopifnot(denied)
    session$execute("ROLLBACK TO SAVEPOINT write_probe")
  })()
  execute(paste0('DELETE FROM ', table("person"), ' WHERE person_id=3'))
  # Execute the registered interval/membership operation, not a raw OP join.
  cte <- AchillesNext:::.observation_cte(schema, cfg$request$window)
  members <- query(paste0(cte, ' SELECT COUNT(*)::text AS n FROM ', table("measurement"), ' m WHERE ', AchillesNext:::.observation_membership()))
  raw <- query(paste0('SELECT COUNT(*)::text AS n FROM ', table("measurement"), ' m JOIN ', table("observation_period"),
    " o ON m.person_id=o.person_id AND m.measurement_date BETWEEN o.observation_period_start_date AND o.observation_period_end_date ",
    "WHERE m.measurement_date BETWEEN DATE '2020-01-15' AND DATE '2020-02-03'"))
  stopifnot(identical(members$N, "6"), identical(raw$N, "11"))
  for (date in c("0001-01-01", "9999-12-31")) {
    edgeCfg <- cfg; edgeCfg$request$window <- list(start = date, end = date)
    name <- paste0("calendar-", date); generate(name, edgeCfg)
    stopifnot(read(name, "observation.person_count")$state == "empty_population", length(read(name, "observation.monthly_person_count")$rows) == 1L)
  }
  execute(paste0('TRUNCATE ', table("observation_period")))
  generate("empty-observation", cfg)
  stopifnot(read("empty-observation", "observation.person_count")$state == "empty_population")
  execute(paste0('TRUNCATE ', table("person")))
  generate("empty-source", cfg)
  stopifnot(read("empty-source", "observation.person_days")$state == "empty_source")
  execute(paste0('INSERT INTO ', table("person"), ' VALUES (1),(2)'))
  invalids <- c("(1,NULL,'2020-01-01')", "(1,'2020-01-02','2020-01-01')", "(99,'2010-01-01','2010-01-02')",
    "(NULL,'2020-01-01','2020-01-02')", "(1,'2020-01-01','infinity')")
  expectState <- function(name, state) {
    generate(name, cfg)
    for (id in c("observation.person_count", "observation.person_days", "observation.monthly_person_count")) {
      doc <- read(name, id); stopifnot(doc$state == state, is.null(doc$rows), nzchar(doc$reason))
    }
    stopifnot(read(name, "person.count")$rows[[1]]$values$count == "2")
  }
  for (i in seq_along(invalids)) {
    execute(paste0('TRUNCATE ', table("observation_period"), '; INSERT INTO ', table("observation_period"), ' VALUES ', invalids[i]))
    expectState(paste0("invalid-", i), "failed")
  }
  execute(paste0('TRUNCATE ', table("observation_period"), '; REVOKE SELECT ON ', table("observation_period"), ' FROM achilles_next_runner'))
  expectState("denied-observation", "inaccessible")
  execute(paste0('GRANT SELECT ON ', table("observation_period"), ' TO achilles_next_runner; ALTER TABLE ', table("observation_period"), ' DROP COLUMN observation_period_end_date'))
  expectState("missing-column", "unavailable")
  # A query error after preflight must roll back its savepoint, preserving PERSON.
  execute(paste0('ALTER TABLE ', table("observation_period"), ' ADD COLUMN observation_period_end_date text'))
  expectState("wrong-date-type", "failed")
  cat("PASS: 15 source/version/window oracles; nested/duplicate/adjacent intervals; partial months; six physical events versus 11 raw joins; empty source/population; malformed/orphan/denied/missing/type failures\n")
}
main()
