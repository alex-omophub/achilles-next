# All database writes/locks are confined to a disposable marked synthetic schema.
library(AchillesNext)
source("tests/tracer/credential-guard.R")
a <- commandArgs(TRUE)
if (length(a) && a[1] %in% c("worker", "resume", "control")) {
  e <- new.env(parent = globalenv()); sys.source(a[2], e)
  if (a[1] == "worker") executeMeasurementRun(a[3], e$config$connectionDetails)
  if (a[1] == "resume") resumeMeasurementRun(a[3], a[4], e$config$connectionDetails)
  if (a[1] == "control") {
    c <- DatabaseConnector::connect(e$config$connectionDetails)
    query <- function(sql) DatabaseConnector::querySql(c, sql, integer64AsNumeric = FALSE)
    deadline <- Sys.time() + 15; blocked <- FALSE
    while (Sys.time() < deadline) {
      r <- inspectMeasurementRun(a[3]); b <- r$state$backend
      if (!is.null(b)) {
        wait <- query(paste0("SELECT wait_event_type AS wait FROM pg_stat_activity WHERE pid=", b$pid, " AND application_name='", b$application_name, "'"))
        if (nrow(wait) == 1L && identical(wait$WAIT, "Lock")) {blocked <- TRUE; break}
      }
      Sys.sleep(0.05)
    }
    stopifnot(blocked)
    if (a[4] == "cancel") {
      # A mismatched nonce must never signal an otherwise matching session.
      wrong <- b; wrong$application_name <- paste0("achilles-next-", strrep("0", 40))
      stopifnot(AchillesNext:::.recovery_signal(wrong, e$config$connectionDetails)$state == "not_active")
      response <- cancelMeasurementRun(a[3], e$config$connectionDetails)
      stopifnot(response$requested, response$database$state == "signal_sent")
    } else {
      tools::pskill(as.integer(a[5]), signal = 9L)
      response <- list(killed = TRUE)
    }
    writeLines(AchillesNext:::.json(list(blocked_in_database = blocked, response = response)), a[6])
    DatabaseConnector::disconnect(c)
  }
} else {
main <- function() {
  if (length(a) != 2L) stop("Use recovery.R <fixture-config.R> <new-evidence-dir>")
  e <- new.env(parent = globalenv()); sys.source(a[1], e)
  if (!dir.create(a[2], mode = "0700")) stop("Evidence directory must be new")
  root <- normalizePath(a[2]); cfg <- e$config
  fails <- function(work, text) stopifnot(grepl(text, tryCatch({work(); "accepted"}, error = conditionMessage), fixed = TRUE))
  owner <- DatabaseConnector::connect(e$fixtureConnection("owner"))
  on.exit(DatabaseConnector::disconnect(owner), add = TRUE)
  execute <- function(sql) DatabaseConnector::executeSql(owner, sql, progressBar = FALSE, reportOverallTime = FALSE)
  guard <- DatabaseConnector::querySql(owner, "SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB == "achilles_next_fixtures", guard$MARKER == "AchillesNext synthetic fixture sandbox v1")
  schema <- paste0("cdm_tiny_recovery_", Sys.getpid(), "_55")
  execute(paste0('CREATE SCHEMA "', schema, '"; COMMENT ON SCHEMA "', schema, '" IS \'AchillesNext synthetic fixture sandbox v1: ', schema, "'"))
  on.exit(execute(paste0('DROP SCHEMA "', schema, '" CASCADE')), add = TRUE, after = FALSE)
  for (table in c("person", "observation_period", "measurement", "concept", "cdm_source"))
    execute(paste0('CREATE TABLE "', schema, '".', table, ' AS SELECT * FROM "', cfg$cdmSchema, '".', table))
  execute(paste0('GRANT USAGE ON SCHEMA "', schema, '" TO achilles_next_runner; GRANT SELECT ON ALL TABLES IN SCHEMA "', schema, '" TO achilles_next_runner'))
  cfg$cdmSchema <- schema
  fixtureConfig <- file.path(root, "worker-config.R")
  # Only paths/configuration tokens are emitted; credentials stay in the fixture loader.
  writeLines(c(paste0("source(", AchillesNext:::.json(normalizePath(a[1])), ")"), paste0("config$cdmSchema <- ", AchillesNext:::.json(schema))), fixtureConfig)
  plan <- function(name) {p <- file.path(root, name); do.call(planMeasurementRun, c(list(runDir = p), cfg[setdiff(names(cfg), "connectionDetails")])); p}
  inspect <- inspectMeasurementRun
  resume <- function(p, name) resumeMeasurementRun(p, file.path(root, name), cfg$connectionDetails)
  baseline <- plan("baseline"); b <- executeMeasurementRun(baseline, cfg$connectionDetails)
  stopifnot(b$state$status == "succeeded", b$state$input_identity$snapshot$state == "unknown")
  weighted <- file.path(root, "weighted")
  do.call(planMeasurementRun, c(list(runDir = weighted, numericStrategy = "weighted"), cfg[setdiff(names(cfg), "connectionDetails")]))
  wb <- executeMeasurementRun(weighted, cfg$connectionDetails)
  wr <- resume(weighted, "weighted-recovered")
  stopifnot(wb$state$status == "succeeded", wr$state$status == "succeeded", wr$plan$numeric_strategy == "weighted",
    identical(wb$state$analytical_sha256, wr$state$analytical_sha256))
  store <- file.path(root, "releases")
  current <- publishMeasurementRun(baseline, store, "synthetic-recovery-test")
  pointer <- digest::digest(file = file.path(store, "current.json"), algo = "sha256")
  # Planned cancellation never opens a source connection; duplicate requests are safe.
  pre <- plan("pre-cancelled"); stopifnot(cancelMeasurementRun(pre)$requested)
  cancelMeasurementRun(pre)
  r <- executeMeasurementRun(pre, cfg$connectionDetails)
  stopifnot(r$state$status == "cancelled", is.null(r$state$backend), r$state$cancellation$cleanup == "removed",
    all(vapply(r$state$operations, function(o) o$status == "cancelled" && o$attempt == 0L, TRUE)))
  # A terminal success cannot be relabelled cancelled by a late request.
  stopifnot(!cancelMeasurementRun(baseline)$requested, inspect(baseline)$state$status == "succeeded")
  # Hold a table lock in an independent owner transaction so cancellation must
  # reach a genuinely blocked database query rather than a convenient idle gap.
  lockSession <- AchillesNext:::.tracer_session(owner)
  rJava::.jcall(owner@jConnection, "V", "setReadOnly", FALSE) # Fixture-only test lock; no source mutation by the executor.
  on.exit(try(lockSession$rollback(), silent = TRUE), add = TRUE, after = FALSE)
  worker <- function(mode, name) {
    p <- plan(name); out <- file.path(root, paste0(name, "-control")); dir.create(out)
    lockSession$execute(paste0('LOCK TABLE "', schema, '".measurement IN ACCESS EXCLUSIVE MODE'))
    code <- system2("python3", c("tests/tracer/recovery-workers.py", mode, shQuote(file.path(R.home("bin"), "Rscript")),
      shQuote(normalizePath("tests/tracer/recovery.R")), shQuote(fixtureConfig), shQuote(out), shQuote(p)))
    lockSession$rollback()
    stopifnot(code == 0L)
    p
  }
  cancelled <- worker("cancel", "cancelled-query"); r <- inspect(cancelled)
  stopifnot(r$state$status == "cancelled", r$state$operations$measurement.compute$status == "cancelled",
    r$state$cancellation$cleanup == "removed", !file.exists(file.path(cancelled, "staging/bundle")),
    r$recovery$cancellation_requested, all(vapply(r$state$outputs, function(o) o$status == "cancelled", TRUE)))
  r <- resume(cancelled, "resumed"); stopifnot(r$state$status == "succeeded", identical(r$state$analytical_sha256, b$state$analytical_sha256),
    r$plan$recovery$attempt == 2L, length(r$plan$recovery$reused_operations) == 0L,
    all(vapply(r$state$operations, function(o) o$attempt == 1L && o$status == "succeeded", TRUE)))
  fails(function() publishMeasurementRun(cancelled, store, "cancelled-test"), "successfully completed")
  stopifnot(identical(currentMeasurementBundle(store), current), identical(digest::digest(file = file.path(store,"current.json"), algo = "sha256"), pointer))
  # CLI idempotency and offline JSON inspection use the same linked attempt.
  cli <- file.path(root, "cli-status.json")
  stopifnot(system2(file.path(R.home("bin"), "Rscript"), c("--vanilla", "tools/measurement_run.R", "retry", shQuote(fixtureConfig), shQuote(cancelled), shQuote(file.path(root,"resumed"))), stdout = FALSE) == 0L,
    system2(file.path(R.home("bin"), "Rscript"), c("--vanilla", "tools/measurement_run.R", "status", shQuote(file.path(root,"resumed")), "--json"), stdout = cli) == 0L,
    jsonlite::fromJSON(cli, simplifyVector = FALSE)$state$status == "succeeded")
  pinned <- AchillesNext:::.json(r); again <- resume(cancelled, "resumed"); stopifnot(identical(pinned, AchillesNext:::.json(again)))
  killed <- worker("kill", "killed-query"); before <- inspect(killed)
  stopifnot(before$state$status == "running", dir.exists(file.path(killed, ".writer-lock")))
  r <- resume(killed, "after-kill"); stopifnot(r$state$status == "succeeded", identical(r$state$analytical_sha256, b$state$analytical_sha256),
    identical(AchillesNext:::.json(before), AchillesNext:::.json(inspect(killed))))
  # Definition and metadata changes never bless a previous successful aggregate.
  # A new plan uses current definitions and records the conservative invalidation.
  stale <- plan("stale-definitions"); ctx <- AchillesNext:::.run_read(stale)
  changed <- ctx$plan; changed$definitions$implementation_sha256 <- strrep("0", 64)
  AchillesNext:::.write_json(changed, file.path(stale, "plan.json"))
  # Recreate this planned test history to represent a valid older implementation.
  ctx$plan <- changed; ctx$planHash <- digest::digest(file = file.path(stale, "plan.json"), algo = "sha256")
  unlink(list.files(file.path(stale, "ledger"), full.names = TRUE)); ctx$revision <- -1L; ctx$previous <- NULL; AchillesNext:::.run_save(ctx)
  r <- resume(stale, "after-definitions"); stopifnot(r$state$status == "succeeded", grepl("Definitions changed", r$plan$recovery$recompute_reason, fixed = TRUE))
  # Reusing a target for another parent is rejected, even if source IDs match.
  fails(function() resume(killed, "resumed"), "another source plan or definitions")
  fails(function() resumeMeasurementRun(killed, file.path(killed, "nested"), cfg$connectionDetails), "outside the previous run")
  execute(paste0('INSERT INTO "', schema, '".measurement SELECT m.* FROM "', schema, '".measurement m WHERE measurement_concept_id=900000001 AND measurement_date BETWEEN DATE \'2020-01-01\' AND DATE \'2020-12-31\' AND EXISTS (SELECT 1 FROM "', schema, '".observation_period o WHERE o.person_id=m.person_id AND m.measurement_date BETWEEN o.observation_period_start_date AND o.observation_period_end_date) LIMIT 1'))
  changed <- resume(baseline, "after-source-change")
  stopifnot(changed$state$status == "succeeded", !identical(changed$state$analytical_sha256, b$state$analytical_sha256))
  execute(paste0('UPDATE "', schema, '".cdm_source SET vocabulary_version=\'fixture-changed\''))
  vocab <- resume(baseline, "after-vocabulary-change")
  stopifnot(vocab$state$status == "succeeded", !identical(vocab$state$input_identity$vocabulary_release, b$state$input_identity$vocabulary_release))
  execute(paste0('UPDATE "', schema, '".concept SET domain_id=\'UnknownUnit\' WHERE concept_id=900000101'))
  terms <- resume(baseline, "after-concept-change")
  stopifnot(terms$state$status == "succeeded", !identical(terms$state$input_identity$terminology_sha256, vocab$state$input_identity$terminology_sha256),
    !identical(terms$state$analytical_sha256, vocab$state$analytical_sha256))
  execute(paste0('ALTER TABLE "', schema, '".measurement RENAME COLUMN measurement_date TO missing_measurement_date'))
  absent <- resume(baseline, "after-required-column-change")
  stopifnot(absent$state$status == "failed", absent$state$operations$measurement.compute$status == "failed",
    all(vapply(Filter(function(o) startsWith(o$metric_id,"measurement."), absent$state$outputs), function(o) o$status == "failed", TRUE)))
  execute(paste0('ALTER TABLE "', schema, '".measurement RENAME COLUMN missing_measurement_date TO measurement_date'))
  execute(paste0('ALTER TABLE "', schema, '".measurement ADD COLUMN recovery_probe integer'))
  structure <- resume(baseline, "after-schema-change")
  stopifnot(structure$state$status == "succeeded", !identical(structure$state$input_identity$schema_sha256, b$state$input_identity$schema_sha256))
  # Independent recovery attempts never share staging; a repeated in-flight
  # target is observed rather than executed for a second time.
  for (mode in c("parallel", "same-target")) {
    out <- file.path(root, mode); dir.create(out)
    stopifnot(system2("python3", c("tests/tracer/recovery-workers.py", mode, shQuote(file.path(R.home("bin"), "Rscript")),
      shQuote(normalizePath("tests/tracer/recovery.R")), shQuote(fixtureConfig), shQuote(out), shQuote(cancelled))) == 0L)
    paths <- if (mode == "parallel") c("attempt-a", "attempt-b") else "attempt-a"
    rs <- lapply(file.path(out, paths), inspect)
    stopifnot(all(vapply(rs, function(r) r$state$status == "succeeded" && length(Filter(function(h) h$state$status == "running", r$history)) > 0L &&
      all(vapply(r$state$operations, function(o) o$attempt == 1L, TRUE)), TRUE)))
    if (mode == "parallel") stopifnot(rs[[1]]$plan$run_id != rs[[2]]$plan$run_id)
  }
  stopifnot(identical(currentMeasurementBundle(store), current), identical(digest::digest(file = file.path(store,"current.json"), algo = "sha256"), pointer))
  text <- paste(vapply(list.files(root, pattern = "[.]json$", recursive = TRUE, full.names = TRUE), function(p) paste(readLines(p, warn = FALSE), collapse = ""), ""), collapse = "")
  assertNoCredentials(text, c(cfg$connectionDetails$password(), e$fixtureConnection("owner")$password()))
  cat("PASS: blocked-query PG cancellation, zero-connection planned cancel, cleanup, hard-kill recovery, identical analytical hashes, idempotent targets, changed source/vocabulary/schema/definitions, concurrent isolated attempts and credential screening\n")
}
main()
}
