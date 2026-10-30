# Developer harness. Only marked synthetic PostgreSQL, bounded generated inputs
# and owned disposable schemas. Credentials are never written to evidence.
suppressPackageStartupMessages(library(AchillesNext))
main <- function() {
  args <- commandArgs(TRUE)
  if (length(args) != 3L || !args[3] %in% c("parity", "benchmark")) stop("Use weighted_quantiles.py with a trusted fixture config")
  env <- new.env(parent = globalenv()); sys.source(args[1], env)
  out <- normalizePath(args[2], mustWork = TRUE)
  if (file.exists(file.path(out, "report.json"))) stop("Evidence must be new")
  oracle <- jsonlite::fromJSON(file.path(out, "oracle.json"), simplifyVector = FALSE)
  ownerDetails <- env$fixtureConnection("owner")
  settings <- "-c work_mem=64MB -c max_parallel_workers_per_gather=0 -c jit=off -c statement_timeout=30s -c lock_timeout=2s -c timezone=UTC"
  ownerDetails$extraSettings <- paste0("options=", utils::URLencode(settings, reserved = TRUE))
  owner <- DatabaseConnector::connect(ownerDetails)
  session <- AchillesNext:::.tracer_session(owner)
  # Only this harness connection may create scratch; public generation always
  # sets its own read-only transaction even when supplied owner connection details.
  rJava::.jcall(owner@jConnection, "V", "setReadOnly", FALSE)
  created <- character()
  commit <- function() rJava::.jcall(owner@jConnection, "V", "commit")
  on.exit({
    try(session$rollback(), silent = TRUE)
    for (schema in created) {
      session$execute(paste0('DROP SCHEMA IF EXISTS "', schema, '" CASCADE')); commit()
    }
    DatabaseConnector::disconnect(owner)
  }, add = TRUE)
  q <- session$query; ex <- session$execute
  guard <- q("SELECT current_database() AS db, current_user AS role, shobj_description(d.oid,'pg_database') AS marker, r.rolsuper::text AS super FROM pg_database d JOIN pg_roles r ON r.rolname=current_user WHERE d.datname=current_database()")
  stopifnot(guard$DB == "achilles_next_fixtures", guard$ROLE == "achilles_next_fixture_owner", guard$SUPER == "false", guard$MARKER == "AchillesNext synthetic fixture sandbox v1")
  actualSettings <- q("SELECT current_setting('work_mem') AS work_mem,current_setting('jit') AS jit,current_setting('max_parallel_workers_per_gather') AS parallel,current_setting('statement_timeout') AS timeout,current_setting('lock_timeout') AS lock_timeout,version() AS version")
  stopifnot(actualSettings$WORK_MEM == "64MB", actualSettings$JIT == "off", actualSettings$PARALLEL == "0", actualSettings$TIMEOUT == "30s", actualSettings$LOCK_TIMEOUT == "2s")
  readSql <- function(name) paste(readLines(system.file(paste0("sql/postgresql/", name, ".sql"), package = "AchillesNext", mustWork = TRUE), warn = FALSE), collapse = "\n")
  summarySql <- function(strategy) paste("WITH anchor AS (SELECT 1)", AchillesNext:::.numeric_ctes(strategy, materialized = TRUE),
    "SELECT dimensions::text AS dimensions, values::text AS values FROM summaries ORDER BY dimensions::text")
  save <- function(value, name) writeLines(AchillesNext:::.json(value), file.path(out, name), useBytes = TRUE)
  norm <- function(x) {
    if (!is.null(x) && grepl(".", x, fixed = TRUE)) x <- sub("[.]$", "", sub("0+$", "", x))
    if (identical(x, "-0")) "0" else x
  }
  check <- function(rows, expected) {
    if (is.null(expected)) {stopifnot(nrow(rows) == 0L); return(invisible(NULL))}
    stopifnot(nrow(rows) == 1L)
    actual <- jsonlite::fromJSON(rows$VALUES[1], simplifyVector = FALSE)
    stopifnot(setequal(names(actual), names(expected)), all(vapply(names(expected), function(k) identical(norm(actual[[k]]), norm(expected[[k]])), TRUE)))
  }
  literal <- function(x) {
    if (is.null(x)) return("NULL")
    if (!grepl("^-?[0-9]+(\\.[0-9]+)?$|^(NaN|Infinity|-Infinity)$", x)) stop("Unsafe numeric fixture")
    paste0("'", x, "'::numeric")
  }
  setupTemps <- function() {
    ex("CREATE TEMP TABLE classified(measurement_concept_id integer,unit_concept_id integer,raw_operator_tag text,value_as_number numeric,known_unit boolean,eligibility_reason text) ON COMMIT DROP")
    ex("CREATE TEMP TABLE frequency_inputs(measurement_concept_id integer,unit_concept_id integer,raw_operator_tag text,value numeric,frequency numeric) ON COMMIT DROP")
  }
  # Same production SQL fragments, independent Python-sorted expected values.
  for (case in oracle) {
    setupTemps()
    if (!is.null(case$recipe)) {
      n <- case$recipe$records; d <- case$recipe$distinct
      stopifnot(n >= 1L, n <= 100000L, d >= 1L, d <= n)
      ex(sprintf("INSERT INTO classified SELECT 900000001,900000101,'zero',((i-1)%%%d)::numeric-%d+0.125,true,'eligible' FROM generate_series(1,%d) i", d, d %/% 2L, n))
    } else if (!is.null(case$weights)) {
      for (pair in case$weights) {
        stopifnot(grepl("^[1-9][0-9]*$", pair[[2]]))
        ex(paste0("INSERT INTO classified VALUES (900000001,900000101,'zero',", literal(pair[[1]]), ",true,'eligible')"))
        ex(paste0("INSERT INTO frequency_inputs VALUES (900000001,900000101,'zero',", literal(pair[[1]]), ",", pair[[2]], "::numeric)"))
      }
    } else for (value in case$values) {
      reason <- if (is.null(value)) "missing_numeric" else if (value %in% c("NaN", "Infinity", "-Infinity")) "non_finite_numeric" else "eligible"
      ex(paste0("INSERT INTO classified VALUES (900000001,900000101,'zero',", literal(value), ",true,'", reason, "')"))
    }
    if (is.null(case$weights)) ex("INSERT INTO frequency_inputs SELECT measurement_concept_id,unit_concept_id,raw_operator_tag,value_as_number,COUNT(*)::numeric FROM classified WHERE eligibility_reason='eligible' GROUP BY 1,2,3,4")
    for (strategy in if (is.null(case$weights)) c("reference", "weighted") else "weighted") check(q(summarySql(strategy)), case$expected)
    session$rollback()
  }
  report <- list(parity_cases = length(oracle), settings = as.list(actualSettings[1, ]), trials = list(), workloads = list(), bundle_pairs = list(),
    limits = list(cache = "Warmed serial trials; no cache eviction or exclusive compute", publication = "Partial 12/15 outputs; validation includes export, not durable publication or browser", telemetry = "Server peak RSS/CPU and uncollected I/O unavailable", provenance = "Synthetic sources only, nonsuperuser fixture owner; temporary scratch rolled back, owned benchmark schemas dropped"))
  if (args[3] == "benchmark") {
    workloads <- list(list(id = "tiny", records = 12L, distinct = 7L, people = 4L),
      list(id = "repeated_100k", records = 100000L, distinct = 32L, people = 10000L),
      list(id = "distinct_100k", records = 100000L, distinct = 4096L, people = 10000L),
      list(id = "unique_100k", records = 100000L, distinct = 100000L, people = 10000L))
    dir.create(file.path(out, "bundles"), mode = "0700")
    elapsed <- function(f) {start <- proc.time()[["elapsed"]]; value <- f(); list(value = value, ms = (proc.time()[["elapsed"]] - start) * 1000)}
    for (work in workloads) {
      schema <- paste0("cdm_tiny_quantile_", Sys.getpid(), "_", work$id, "_55")
      ex(paste0('CREATE SCHEMA "', schema, '"')); created <- c(created, schema)
      table <- function(name) paste0('"', schema, '".', name)
      ex(paste0('COMMENT ON SCHEMA "', schema, '" IS \'AchillesNext synthetic fixture sandbox v1: ', schema, '\''))
      ex(paste0('CREATE TABLE ', table("person"), ' AS SELECT i::bigint AS person_id FROM generate_series(1,', work$people, ') i'))
      ex(paste0('CREATE TABLE ', table("observation_period"), " AS SELECT person_id,DATE '2020-01-01' AS observation_period_start_date,DATE '2020-12-31' AS observation_period_end_date FROM ", table("person")))
      ex(paste0('INSERT INTO ', table("observation_period"), ' SELECT * FROM ', table("observation_period"), ' WHERE person_id%5=0'))
      ex(paste0('CREATE TABLE ', table("concept"), "(concept_id integer,concept_name text,domain_id text); INSERT INTO ", table("concept"), " VALUES (900000001,'Synthetic benchmark','Measurement'),(900000101,'Synthetic unit','Unit')"))
      ex(paste0('CREATE TABLE ', table("cdm_source"), "(vocabulary_version text); INSERT INTO ", table("cdm_source"), " VALUES ('benchmark-v1')"))
      ex(sprintf('CREATE TABLE %s AS SELECT i::bigint AS measurement_id,((i-1)%%%d+1)::bigint AS person_id,900000001::integer AS measurement_concept_id,DATE \'2020-01-01\'+((i-1)%%366)::integer AS measurement_date,((i-1)%%%d)::numeric-%d+0.125 AS value_as_number,900000101::integer AS unit_concept_id,0::integer AS operator_concept_id,0::integer AS value_as_concept_id,NULL::text AS value_source_value FROM generate_series(1,%d) i', table("measurement"), work$people, work$distinct, work$distinct %/% 2L, work$records))
      for (name in c("person", "observation_period", "measurement", "concept")) ex(paste("ANALYZE", table(name)))
      commit()
      cfg <- env$config; cfg$connectionDetails <- ownerDetails; cfg$cdmSchema <- schema; cfg$sourceId <- paste0("fixture:quantile:", work$id); cfg$request$source_id <- cfg$sourceId
      cfg$request$measurement_concept_ids <- list(900000001L); cfg$request$window <- list(start = "2020-01-01", end = "2020-12-31")
      expected <- Filter(function(c) c$id == paste0("recipe_", work$records, "_", work$distinct), oracle)[[1]]$expected
      fingerprint <- function() q(paste0('SELECT md5(string_agg(row_to_json(m)::text,\'\' ORDER BY measurement_id)) AS hash FROM ', table("measurement"), ' m'))$HASH
      inputHash <- fingerprint(); session$rollback()
      work$input_md5 <- inputHash; report$workloads[[length(report$workloads) + 1L]] <- work
      for (trial in -1:5) {
        paths <- list()
        for (strategy in if (trial %% 2L == 0L) c("reference", "weighted") else c("weighted", "reference")) {
          cte <- AchillesNext:::.measurement_cte(schema, cfg$request)
          classified <- elapsed(function() ex(paste0("CREATE TEMP TABLE classified ON COMMIT DROP AS ", cte, " SELECT * FROM classified")))$ms
          frequencies <- elapsed(function() ex(paste("CREATE TEMP TABLE frequency_inputs ON COMMIT DROP AS WITH anchor AS (SELECT 1)", readSql("numeric-frequencies"), "SELECT * FROM frequency_inputs")))$ms
          operator <- elapsed(function() q(summarySql(strategy)))
          check(operator$value, expected)
          if (trial == -1L) {
            plan <- q(paste("EXPLAIN (ANALYZE,BUFFERS,SETTINGS,TIMING OFF,FORMAT JSON)", summarySql(strategy)))[[1]][1]
            writeLines(plan, file.path(out, paste0("plan-", work$id, "-", strategy, ".json")))
          }
          session$rollback()
          relative <- paste0("bundles/", work$id, "-", trial + 1L, "-", strategy); paths[[strategy]] <- relative
          generation <- elapsed(function() do.call(generateMeasurementReport, c(cfg, list(outputDir = file.path(out, relative), numericStrategy = strategy))))$ms
          logfile <- file.path(out, paste0(work$id, "-", trial + 1L, "-", strategy, "-validation.log"))
          validation <- elapsed(function() system2("node", c("packages/contracts/tools/validate.mjs", shQuote(file.path(out, relative))), stdout = logfile, stderr = logfile))
          stopifnot(validation$value == 0L)
          doc <- jsonlite::fromJSON(file.path(out, relative, "results/measurement.numeric_summary.json"), simplifyVector = FALSE)
          stopifnot(length(doc$rows) == 1L)
          check(data.frame(VALUES = AchillesNext:::.json(doc$rows[[1]]$values)), expected)
          row <- list(workload = work$id, trial = trial, retained = trial > 0L, strategy = strategy,
            classified_materialize_ms = classified, frequency_materialize_ms = frequencies, operator_query_transfer_ms = operator$ms,
            numeric_compute_materialize_ms = classified + frequencies + operator$ms,
            generator_export_ms = generation, validation_ms = validation$ms, validated_slice_ms = generation + validation$ms,
            export_separate_ms = NULL, export_reason = "Included in full generator wall time; no fabricated separate phase")
          report$trials[[length(report$trials) + 1L]] <- row
        }
        report$bundle_pairs[[length(report$bundle_pairs) + 1L]] <- paths
        stopifnot(identical(inputHash, fingerprint())); session$rollback()
        save(report, "progress.json")
      }
    }
  }
  sqlRoot <- system.file("sql/postgresql", package = "AchillesNext", mustWork = TRUE)
  sqlNames <- list.files(sqlRoot, pattern = "[.]sql$")
  report$installed_sql_sha256 <- stats::setNames(lapply(sqlNames, function(name) digest::digest(file = file.path(sqlRoot, name), algo = "sha256")), sqlNames)
  report$runtime <- list(R = as.character(getRversion()), DatabaseConnector = as.character(packageVersion("DatabaseConnector")),
    system = as.list(Sys.info()[c("sysname", "release", "machine")]), logical_cpus = parallel::detectCores(logical = TRUE))
  session$rollback()
  for (schema in created) {ex(paste0('DROP SCHEMA "', schema, '" CASCADE')); commit()}
  created <- character()
  report$cleanup <- "All owned benchmark schemas dropped; temporary scratch rolled back"
  save(report, "report.json")
  cat("PASS:", length(oracle), "independent quantile cases; bounded benchmark mode", args[3], "\n")
}
main()
