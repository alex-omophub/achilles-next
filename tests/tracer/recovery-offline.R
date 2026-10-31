library(AchillesNext)
main <- function() {
  root <- tempfile("recovery-offline-"); dir.create(root); on.exit(unlink(root, recursive = TRUE), add = TRUE)
  request <- list(profile_id = "alpha-measurement-v1", source_id = "fixture:recovery",
    window = list(start = "2020-01-01", end = "2020-12-31"), measurement_concept_ids = list(900000001L),
    output_scope = "restricted", disclosure_policy_id = "synthetic-unsuppressed-v1")
  make <- function(name) {p <- file.path(root, name); planMeasurementRun(p, "cdm_tiny_a_55", request$source_id, request, "5.5"); p}
  fails <- function(work, text) stopifnot(grepl(text, tryCatch({work(); "accepted"}, error = conditionMessage), fixed = TRUE))
  p <- make("planned"); first <- cancelMeasurementRun(p); second <- cancelMeasurementRun(p)
  stopifnot(first$requested, second$requested, !first$acknowledged, inspectMeasurementRun(p)$recovery$cancellation_requested)
  details <- structure(list(dbms = "postgresql"), class = "ConnectionDetails") # No usable driver connection: cancellation must happen first.
  r <- executeMeasurementRun(p, details)
  stopifnot(r$state$status == "cancelled", r$state$cancellation$cleanup == "removed",
    !dir.exists(file.path(p, ".writer-lock")), !dir.exists(file.path(p, ".cancel-lock")), is.null(r$state$backend))
  fails(function() resumeMeasurementRun(p, file.path(p, "nested"), details), "outside the previous run")
  stopifnot(!dir.exists(file.path(p, "nested")))
  # Cleanup refuses a symlinked staging parent and leaves the other directory intact.
  p <- make("linked"); outside <- file.path(root, "outside"); dir.create(outside); dir.create(file.path(outside, "bundle"))
  sentinel <- file.path(outside, "bundle", "keep"); writeLines("outside sentinel", sentinel)
  unlink(file.path(p, "staging"), recursive = TRUE); stopifnot(file.symlink(outside, file.path(p, "staging")))
  cancelMeasurementRun(p); r <- executeMeasurementRun(p, details)
  stopifnot(r$state$status == "cancelled", r$state$cancellation$cleanup == "unavailable", file.exists(sentinel))
  # An unrecognized control message cannot authorize cancellation or completion.
  p <- make("wrong-context"); ctx <- AchillesNext:::.run_read(p)
  AchillesNext:::.write_json(list(format_version = "1.0.0", run_id = "other", plan_sha256 = ctx$planHash), file.path(p, "cancel-request.json"))
  fails(function() inspectMeasurementRun(p), "Invalid cancellation request")
  # The final commit and cancellation request use the same short lock: a prior
  # request wins even if work has just produced a complete candidate.
  p <- make("completion-race"); cancelMeasurementRun(p); ctx <- AchillesNext:::.run_read(p)
  AchillesNext:::.recovery_terminal(ctx, "succeeded", NULL)
  stopifnot(inspectMeasurementRun(p)$state$status == "cancelled")
  cat("PASS: offline idempotent cancellation, zero-driver acknowledgement, destination guard, symlink-safe cleanup, wrong-context rejection and cancellation/completion ordering\n")
}
main()
