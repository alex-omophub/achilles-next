#!/usr/bin/env Rscript
# Trusted local config is evaluated only for plan/execute, never inspection.
suppressPackageStartupMessages(library(AchillesNext))
a <- commandArgs(TRUE)
usage <- function() stop("Usage: measurement_run.R plan|execute <trusted-config.R> <run-dir> OR status <run-dir> [--json]", call. = FALSE)
if (!length(a) || !a[1] %in% c("plan", "execute", "status")) usage()
if (a[1] == "status") {
  if (!length(a) %in% 2:3 || (length(a) == 3L && a[3] != "--json")) usage()
  r <- inspectMeasurementRun(a[2])
  if (length(a) == 3L) cat(AchillesNext:::.json(r), "\n", sep = "") else {
    cat("Run:", r$plan$run_id, "\nLast persisted state:", r$state$status, "\n")
    cat("Run cause:", if (is.null(r$state$cause)) "none" else r$state$cause$code, "\n")
    cat("Concurrency limit per run:", r$plan$max_concurrency, "\n")
    for (op in r$plan$operations) {
      s <- r$state$operations[[op$id]]
      cat(op$id, "|", s$status, "| resource:", op$resource_class, "| dependencies:", paste(unlist(op$dependencies), collapse = ","),
        "| ms:", if (is.null(s$duration_ms)) paste0("unavailable (", s$timing_reason, ")") else s$duration_ms,
        "| cause:", if (is.null(s$cause)) "none" else s$cause$code,
        "| query ID: unavailable (", s$query_id_reason, ")\n")
    }
    for (o in r$state$outputs) cat(o$metric_id, "|", o$status, "| availability:", if (is.null(o$availability)) "not executed" else o$availability, "\n")
    cat(r$liveness, "\n")
  }
} else {
  if (length(a) != 3L) usage()
  e <- new.env(parent = globalenv()); sys.source(a[2], e)
  if (!is.list(e$config)) stop("Config must define config", call. = FALSE)
  if (a[1] == "plan") {
    args <- e$config[intersect(names(e$config), c("cdmSchema", "sourceId", "request", "declaredCdmVersion", "numericStrategy", "maxConcurrency"))]
    do.call(planMeasurementRun, c(list(runDir = a[3]), args))
    cat("Persisted plan; no database connection opened.\n")
  } else {
    r <- executeMeasurementRun(a[3], e$config$connectionDetails)
    cat("Last persisted run state:", r$state$status, "\n")
    quit(status = if (r$state$status == "succeeded") 0L else 2L)
  }
}
