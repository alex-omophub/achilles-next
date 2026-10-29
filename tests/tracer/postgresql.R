# Live integration command; never run implicitly during R CMD check.
# Uses only the marked synthetic database and a test-owned disposable schema.
suppressPackageStartupMessages(library(AchillesNext))
main <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) != 2L) stop("Usage: postgresql.R <fixture-config.R> <new-artifact-parent>")
  env <- new.env(parent = globalenv()); sys.source(args[1], env)
  if (!dir.create(args[2], mode = "0700")) stop("Test artifact parent must be new")
  generate <- function(name, cfg) do.call(generateCountTracer, c(cfg, list(outputDir = file.path(args[2], name))))
  expectFailure <- function(code, action, output) {
    failure <- tryCatch({action(); NULL}, error = identity)
    stopifnot(inherits(failure, "error"), grepl(code, conditionMessage(failure)), !file.exists(output))
  }
  for (version in c("5.3", "5.4", "5.5")) for (source in c("a", "b")) {
    cfg <- env$config; cfg$cdmSchema <- paste0("cdm_tiny_", source, "_", gsub(".", "", version, fixed = TRUE))
    cfg$sourceId <- paste0("fixture:tiny_", source); cfg$request$source_id <- cfg$sourceId; cfg$declaredCdmVersion <- version
    name <- paste0(source, "-", version); generate(name, cfg)
    doc <- jsonlite::fromJSON(file.path(args[2], name, "results/person.count.json"), simplifyVector = FALSE)
    stopifnot(identical(doc$rows[[1]]$values$count, if (source == "a") "4" else "2"))
  }
  cfg <- env$config; cfg$cdmSchema <- 'person; DROP TABLE person'
  expectFailure("fixture schema", function() generate("unsafe-schema", cfg), file.path(args[2], "unsafe-schema"))
  cfg <- env$config; cfg$request$measurement_concept_ids <- list(TRUE)
  expectFailure("concept IDs", function() generate("bad-request", cfg), file.path(args[2], "bad-request"))
  # Independent malformed/empty PERSON cases; never modify the canonical tiny data.
  owner <- DatabaseConnector::connect(env$fixtureConnection("owner"))
  on.exit(DatabaseConnector::disconnect(owner), add = TRUE)
  q <- function(sql) DatabaseConnector::querySql(owner, sql, errorReportFile = tempfile(), integer64AsNumeric = FALSE)
  guard <- q("SELECT current_database() AS db, shobj_description(oid, 'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(identical(guard$DB, "achilles_next_fixtures"), identical(guard$MARKER, "AchillesNext synthetic fixture sandbox v1"))
  errorFile <- tempfile("tracer-integration-error-")
  on.exit(unlink(errorFile), add = TRUE)
  execute <- function(sql) DatabaseConnector::executeSql(owner, sql, progressBar = FALSE, reportOverallTime = FALSE, errorReportFile = errorFile)
  schema <- paste0("cdm_tiny_tracer_", Sys.getpid(), "_55")
  execute(paste0('CREATE SCHEMA "', schema, '"; COMMENT ON SCHEMA "', schema, '" IS \'AchillesNext synthetic fixture sandbox v1: ', schema,
    '\'; CREATE TABLE "', schema, '".person(person_id bigint); GRANT USAGE ON SCHEMA "', schema,
    '" TO achilles_next_runner; GRANT SELECT ON "', schema, '".person TO achilles_next_runner;'))
  on.exit(execute(paste0('DROP SCHEMA "', schema, '" CASCADE')), add = TRUE, after = FALSE)
  cfg <- env$config; cfg$cdmSchema <- schema; cfg$sourceId <- "fixture:edge"; cfg$request$source_id <- cfg$sourceId
  generate("empty", cfg)
  empty <- jsonlite::fromJSON(file.path(args[2], "empty/results/person.count.json"), simplifyVector = FALSE)
  stopifnot(empty$state == "empty_source", identical(empty$rows[[1]]$values$count, "0"))
  execute(paste0('INSERT INTO "', schema, '".person VALUES (1),(1)'))
  expectFailure("TRACER_PERSON_INTEGRITY", function() generate("duplicates", cfg), file.path(args[2], "duplicates"))
  execute(paste0('DELETE FROM "', schema, '".person; INSERT INTO "', schema, '".person VALUES (NULL)'))
  expectFailure("TRACER_PERSON_INTEGRITY", function() generate("null-id", cfg), file.path(args[2], "null-id"))
  execute(paste0('REVOKE SELECT ON "', schema, '".person FROM achilles_next_runner'))
  expectFailure("TRACER_QUERY_FAILED", function() generate("denied", cfg), file.path(args[2], "denied"))
  exact <- q("SELECT 9007199254740993::bigint::text AS exact")
  stopifnot(identical(exact$EXACT, "9007199254740993"))
  expectFailure("must be new", function() generate("a-5.5", env$config), file.path(args[2], "not-created"))
  cat("PASS: six canonical source/version counts; empty source; duplicate/null prerequisite failures; denied access; exact JDBC text; unsafe inputs; overwrite refusal\n")
}
main()
