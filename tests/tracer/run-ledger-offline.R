# Durable planning/state-machine tests without database access.
library(AchillesNext)
source("tests/tracer/credential-guard.R")
main <- function() {
  root <- tempfile("execution-offline-"); dir.create(root); on.exit(unlink(root, recursive = TRUE), add = TRUE)
  request <- list(profile_id = "alpha-measurement-v1", source_id = "fixture:tiny_a",
    window = list(start = "2020-01-01", end = "2020-12-31"), measurement_concept_ids = list(900000001L),
    output_scope = "restricted", disclosure_policy_id = "synthetic-unsuppressed-v1")
  plan <- function(name, ...) {p <- file.path(root, name); planMeasurementRun(p, "cdm_tiny_a_55", request$source_id, request, "5.5", ...); p}
  fails <- function(work, text) stopifnot(grepl(text, tryCatch({work(); "accepted"}, error = conditionMessage), fixed = TRUE))
  fakeSecret <- 'fixture-"secret\\-value'
  assertNoCredentials('{"safe":"clean"}', fakeSecret)
  fails(function() assertNoCredentials(AchillesNext:::.json(list(renamed_field = fakeSecret)), fakeSecret), "Credential value found")
  fails(function() assertNoCredentials(AchillesNext:::.json(list(message = paste("prefix", fakeSecret, "suffix"))), fakeSecret), "Credential value found")
  p <- plan("planned"); r <- inspectMeasurementRun(p)
  stopifnot(length(r$plan$requested_outputs) == 15L, length(r$plan$outputs) == 15L,
    length(r$plan$operations) == 6L, r$plan$max_concurrency == 1L,
    identical(vapply(r$history, function(h) h$state$status, ""), c("requested", "planned")),
    identical(r$plan$operations[[5]]$dependencies, list("observation.compute")),
    length(r$plan$shared_inputs) == 4L)
  fails(function() planMeasurementRun(p, "cdm_tiny_a_55", request$source_id, request, "5.5"), "Run directory must be new")
  fails(function() plan("parallel", maxConcurrency = 2), "maxConcurrency = 1")
  stopifnot(!dir.exists(file.path(root, "parallel")))
  bad <- request; bad$source_id <- 1
  fails(function() planMeasurementRun(file.path(root, "bad-source"), "cdm_tiny_a_55", 1, bad, "5.5"), "Explicit source identifier")
  stopifnot(!dir.exists(file.path(root, "bad-source")))
  # Persist a classified failure without leaking the raw exception text.
  ctx <- AchillesNext:::.run_read(p); ctl <- AchillesNext:::.run_control(ctx)
  fails(function() ctl$step("person.count", function() "0"), "not ready")
  ctl$step("source.connect", function() TRUE); ctl$step("source.guard", function() TRUE)
  fails(function() ctl$step("person.count", function() stop("secret-sentinel")), "Operation failed")
  AchillesNext:::.run_terminal(ctx, "failed", AchillesNext:::.run_cause("run_aborted"))
  r <- inspectMeasurementRun(p)
  stopifnot(r$state$status == "failed", r$state$operations$person.count$status == "failed",
    r$state$operations$measurement.compute$status == "skipped",
    r$state$operations$person.count$cause$code == "operation_error",
    !grepl("secret-sentinel", AchillesNext:::.json(r), fixed = TRUE))
  # A caught interrupt is a persisted cancellation, not a successful zero.
  q <- plan("cancelled"); ctx <- AchillesNext:::.run_read(q); ctl <- AchillesNext:::.run_control(ctx)
  tryCatch(ctl$step("source.connect", function() stop(structure(list(message = "interrupted", call = NULL), class = c("interrupt", "condition")))),
    interrupt = function(e) AchillesNext:::.run_terminal(ctx, "cancelled", AchillesNext:::.run_cause("interrupted")))
  r <- inspectMeasurementRun(q)
  stopifnot(r$state$status == "cancelled", r$state$operations$source.connect$status == "cancelled",
    all(vapply(r$state$outputs, function(o) o$status == "cancelled" && o$availability == "unavailable", TRUE)))
  # A new R process can read all terminal outcomes without a connection config.
  script <- file.path(root, "read.R"); output <- file.path(root, "reopened.json")
  writeLines('library(AchillesNext); a<-commandArgs(TRUE); writeLines(AchillesNext:::.json(inspectMeasurementRun(a[1])),a[2])', script)
  stopifnot(system2(file.path(R.home("bin"), "Rscript"), c("--vanilla", shQuote(script), shQuote(q), shQuote(output))) == 0L)
  stopifnot(jsonlite::fromJSON(output)$state$status == "cancelled")
  # Kill a separate writer after its running state is committed. Inspection does
  # not rewrite history or pretend the stale writer lock is safe to steal.
  q <- plan("killed"); marker <- file.path(root, "pid")
  writeLines(c('library(AchillesNext); a<-commandArgs(TRUE); ctx<-AchillesNext:::.run_read(a[1]); dir.create(file.path(a[1],".writer-lock"));',
    'ctx$state$status<-"running"; AchillesNext:::.run_save(ctx); ctl<-AchillesNext:::.run_control(ctx);',
    'ctl$step("source.connect",function(){writeLines(as.character(Sys.getpid()),a[2]); repeat Sys.sleep(0.1)})'), script)
  log <- file.path(root, "child.log")
  system2(file.path(R.home("bin"), "Rscript"), c("--vanilla", shQuote(script), shQuote(q), shQuote(marker)), stdout = log, stderr = log, wait = FALSE)
  deadline <- Sys.time() + 10
  while (!file.exists(marker) && Sys.time() < deadline) Sys.sleep(0.05)
  stopifnot(file.exists(marker)); pid <- as.integer(readLines(marker)); tools::pskill(pid, signal = 9L)
  r <- inspectMeasurementRun(q)
  stopifnot(r$state$status == "running", r$state$operations$source.connect$status == "running",
    is.null(r$state$operations$source.connect$duration_ms), dir.exists(file.path(q, ".writer-lock")))
  details <- structure(list(dbms = "postgresql"), class = "ConnectionDetails") # Lock check must precede any driver access.
  fails(function() executeMeasurementRun(q, details), "Run is locked")
  # Missing committed revisions and edits to the plan fail closed.
  q <- plan("corrupt"); writeLines("{}", file.path(q, "plan.json")); fails(function() inspectMeasurementRun(q), "Unsupported execution plan")
  q <- plan("partial-write"); writeLines("unfinished", file.path(q, "ledger", ".pending-test"))
  stopifnot(inspectMeasurementRun(q)$state$status == "planned")
  q <- plan("plan-edited"); f <- file.path(q, "plan.json"); changed <- jsonlite::fromJSON(f, simplifyVector = FALSE)
  changed$request$window$end <- "2020-11-30"; AchillesNext:::.write_json(changed, f)
  fails(function() inspectMeasurementRun(q), "discontinuous")
  q <- plan("revision-edited"); f <- file.path(q, "ledger", "00000000.json"); changed <- jsonlite::fromJSON(f, simplifyVector = FALSE)
  changed$recorded_at <- "2020-01-01T00:00:00.000Z"; AchillesNext:::.write_json(changed, f)
  fails(function() inspectMeasurementRun(q), "discontinuous")
  q <- plan("gap"); unlink(file.path(q, "ledger", "00000000.json")); fails(function() inspectMeasurementRun(q), "discontinuous")
  cat("PASS: offline plan, dependency guard, persisted failure/cancellation, fresh-process read, killed writer/lock refusal and corrupted-history checks\n")
}
main()
