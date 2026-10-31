# Live ledger regression, restricted to the existing synthetic fixture sandbox.
library(AchillesNext)
source("tests/tracer/credential-guard.R")
main <- function() {
  a <- commandArgs(TRUE); if (length(a) != 2L) stop("Use run-ledger.R <fixture-config.R> <new-evidence-dir>")
  e <- new.env(parent = globalenv()); sys.source(a[1], e)
  if (!dir.create(a[2], mode = "0700")) stop("Evidence directory must be new")
  make <- function(name, cfg = e$config, strategy = "reference") {
    p <- file.path(a[2], name)
    do.call(planMeasurementRun, c(list(runDir = p, numericStrategy = strategy), cfg[setdiff(names(cfg), "connectionDetails")]))
    p
  }
  run <- function(name, cfg = e$config, strategy = "reference") {
    p <- make(name, cfg, strategy); executeMeasurementRun(p, cfg$connectionDetails)
  }
  valid <- function(name, r) {
    stopifnot(r$state$status == "succeeded", is.null(r$state$cause),
      all(vapply(r$state$operations, function(op) op$status == "succeeded" && op$attempt == 1L &&
        !is.null(op$duration_ms) && grepl("^[0-9]+$", op$duration_ms) && is.null(op$query_id) && nzchar(op$query_id_reason), TRUE)),
      sum(vapply(r$state$outputs, function(o) o$status == "succeeded", TRUE)) == 15L,
      sum(vapply(r$state$outputs, function(o) o$availability == "unsupported", TRUE)) == 0L)
    p <- file.path(a[2], name, "staging/bundle")
    m <- jsonlite::fromJSON(file.path(p, "manifest.json"), simplifyVector = FALSE)
    stopifnot(m$run_id == r$plan$run_id, m$publication == "partial", !m$eligible_for_current_pointer)
    stopifnot(system2("node", c("packages/contracts/tools/validate.mjs", shQuote(p)), stdout = FALSE) == 0L)
    trace <- r$state$operations$measurement.compute$queries
    stopifnot(length(trace) > 1L, all(vapply(trace, function(q) is.null(q$query_id) && nzchar(q$query_id_reason) &&
      grepl("^[0-9a-f]{64}$", q$sql_sha256) && grepl("^[0-9]+$", q$duration_ms), TRUE)))
  }
  # Two separate processes execute different runs concurrently. Each plan still
  # admits only one operation at a time; the cap is not a global warehouse cap.
  script <- file.path(a[2], "worker.R")
  writeLines('library(AchillesNext); a<-commandArgs(TRUE); e<-new.env(); sys.source(a[1],e); executeMeasurementRun(a[2],e$config$connectionDetails); writeLines("done",a[3])', script)
  children <- lapply(c("parallel-a", "parallel-b"), function(name) list(path = make(name), name = name))
  stopifnot(system2("python3", c("tests/tracer/run-workers.py", shQuote(file.path(R.home("bin"), "Rscript")),
    shQuote(normalizePath(script)), shQuote(normalizePath(a[1])), shQuote(normalizePath(a[2])))) == 0L)
  for (c in children) valid(c$name, inspectMeasurementRun(c$path))
  ids <- vapply(children, function(c) inspectMeasurementRun(c$path)$plan$run_id, ""); stopifnot(length(unique(ids)) == 2L)
  r <- run("reference"); valid("reference", r)
  w <- run("weighted", strategy = "weighted"); valid("weighted", w)
  stopifnot(r$plan$run_id != w$plan$run_id)
  # New writers cannot overwrite a prior run or retry partial/failed work.
  error <- tryCatch({executeMeasurementRun(file.path(a[2], "reference"), e$config$connectionDetails); "accepted"}, error = conditionMessage)
  stopifnot(grepl("Only a new planned run", error, fixed = TRUE))
  missing <- e$config; missing$cdmSchema <- "cdm_tiny_absent_55"
  r <- run("guard-failed", missing)
  stopifnot(r$state$operations$source.guard$status == "failed", r$state$operations$source.guard$cause$code == "source_identity_failed",
    is.null(r$state$bundle$path), all(vapply(r$state$outputs, function(o) o$status == "failed", TRUE)))
  owner <- DatabaseConnector::connect(e$fixtureConnection("owner"))
  on.exit(DatabaseConnector::disconnect(owner), add = TRUE)
  execute <- function(sql) DatabaseConnector::executeSql(owner, sql, progressBar = FALSE, reportOverallTime = FALSE)
  query <- function(sql) DatabaseConnector::querySql(owner, sql, integer64AsNumeric = FALSE)
  guard <- query("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB == "achilles_next_fixtures", guard$MARKER == "AchillesNext synthetic fixture sandbox v1")
  # The default reference may inline its single-consumer frequency aggregate;
  # weighted still shares that aggregate between totals and cumulative ranks.
  cteNames <- function(x) {
    if (!is.list(x)) return(character())
    c(x[["CTE Name"]], unlist(lapply(x, cteNames), use.names = FALSE))
  }
  for (strategy in c("reference", "weighted")) {
    planText <- query(paste("EXPLAIN (FORMAT JSON)", AchillesNext:::.measurement_sql(e$config$cdmSchema, e$config$request, strategy)))[[1]][1]
    plan <- jsonlite::fromJSON(planText, simplifyVector = FALSE)
    stopifnot(("frequency_inputs" %in% cteNames(plan)) == (strategy == "weighted"))
    writeLines(planText, file.path(a[2], paste0("explain-", strategy, ".json")))
  }
  schema <- paste0("cdm_tiny_execution_", Sys.getpid(), "_55")
  execute(paste0('CREATE SCHEMA "', schema, '"; COMMENT ON SCHEMA "', schema, '" IS \'AchillesNext synthetic fixture sandbox v1: ', schema, "'"))
  on.exit(execute(paste0('DROP SCHEMA "', schema, '" CASCADE')), add = TRUE, after = FALSE)
  for (table in c("person", "observation_period", "measurement", "concept", "cdm_source"))
    execute(paste0('CREATE TABLE "', schema, '".', table, ' AS SELECT * FROM "', e$config$cdmSchema, '".', table))
  execute(paste0('GRANT USAGE ON SCHEMA "', schema, '" TO achilles_next_runner; GRANT SELECT ON ALL TABLES IN SCHEMA "', schema, '" TO achilles_next_runner'))
  cfg <- e$config; cfg$cdmSchema <- schema
  execute(paste0('UPDATE "', schema, '".measurement SET person_id=99999 WHERE measurement_concept_id=900000001'))
  r <- run("measurement-failed", cfg)
  stopifnot(r$state$operations$measurement.compute$status == "failed",
    sum(vapply(r$state$outputs, function(o) startsWith(o$metric_id, "measurement.") && o$status == "failed" && o$availability == "failed", TRUE)) == 7L)
  execute(paste0('DROP TABLE "', schema, '".observation_period'))
  r <- run("dependency-skipped", cfg)
  stopifnot(r$state$operations$observation.compute$status == "failed", r$state$operations$measurement.compute$status == "skipped",
    r$state$operations$measurement.compute$cause$dependency == "observation.compute",
    length(r$state$operations$measurement.compute$queries) == 0L,
    is.null(r$state$operations$measurement.compute$duration_ms))
  # A write failure preserves successful computation attempts but cannot claim
  # any finalized metric output or remove the ledger with the bundle cleanup.
  p <- make("write-failed"); Sys.chmod(file.path(p, "staging"), "0500")
  r <- executeMeasurementRun(p, e$config$connectionDetails); Sys.chmod(file.path(p, "staging"), "0700")
  stopifnot(r$state$status == "failed", r$state$operations$bundle.write$status == "failed",
    r$state$operations$bundle.write$cause$code == "artifact_write_failed",
    all(vapply(r$state$outputs, function(o) o$status == "failed", TRUE)), !dir.exists(file.path(p, "staging/bundle")))
  # Finalization belongs to bundle.write. Real validator/write failures after
  # the initial export must remain failed operations with an explicit partial
  # staging path, including when reopened in another process.
  node <- Sys.which("node"); stopifnot(nzchar(node))
  bin <- file.path(a[2], "fault-bin"); dir.create(bin)
  finalizationFault <- function(name, script, cause) {
    p <- make(name)
    writeLines(c("#!/bin/sh", script), file.path(bin, "node")); Sys.chmod(file.path(bin, "node"), "0700")
    oldPath <- Sys.getenv("PATH"); on.exit(Sys.setenv(PATH = oldPath), add = TRUE)
    Sys.setenv(PATH = paste(normalizePath(bin), oldPath, sep = .Platform$path.sep))
    r <- executeMeasurementRun(p, e$config$connectionDetails)
    stopifnot(r$state$status == "failed", r$state$operations$bundle.write$status == "failed",
      r$state$operations$bundle.write$cause$code == cause,
      r$state$bundle$path == "staging/bundle", r$state$bundle$publication == "partial",
      grepl("unvalidated partial staging retained", r$state$bundle$reason, fixed = TRUE),
      all(vapply(r$state$outputs, function(o) o$status == "failed", TRUE)),
      !any(vapply(r$history, function(h) h$state$operations$bundle.write$status == "succeeded", TRUE)))
    Sys.chmod(file.path(p, "staging/bundle/manifest.json"), "0600")
    p
  }
  invalid <- finalizationFault("validation-failed", "exit 1", "bundle_validation_failed")
  unwritable <- finalizationFault("manifest-write-failed", c('chmod 400 "$2/manifest.json"', paste("exec", shQuote(node), '"$@"')), "operation_error")
  reopened <- file.path(a[2], "reopened-finalization.json")
  writeLines('library(AchillesNext); a<-commandArgs(TRUE); x<-lapply(a[1:2],inspectMeasurementRun); stopifnot(all(vapply(x,function(r) r$state$operations$bundle.write$status=="failed" && r$state$bundle$publication=="partial",TRUE))); writeLines(AchillesNext:::.json(x),a[3])', script)
  stopifnot(system2(file.path(R.home("bin"), "Rscript"), c("--vanilla", shQuote(script), shQuote(invalid), shQuote(unwritable), shQuote(reopened))) == 0L)
  # No credential strings are stored in plan/ledger JSON or query text.
  paths <- list.files(a[2], pattern = "[.]json$", recursive = TRUE, full.names = TRUE)
  text <- paste(vapply(paths, function(p) paste(readLines(p, warn = FALSE), collapse = ""), ""), collapse = "")
  stopifnot(!grepl('"password"', text, fixed = TRUE), !grepl('"connectionDetails"', text, fixed = TRUE))
  assertNoCredentials(text, c(e$config$connectionDetails$password(), e$fixtureConnection("owner")$password()))
  cat("PASS: reference/weighted durable runs, exact validated bundles, failed/skipped dependencies, export failure, two concurrent isolated runs and telemetry\n")
}
main()
