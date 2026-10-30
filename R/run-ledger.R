# Local, single-writer execution records. These are not result/publication contracts.
.run_ms <- function(start) format(floor(max(0, proc.time()[["elapsed"]] - start) * 1000 + 0.5), scientific = FALSE, trim = TRUE)
.run_definitions <- function() {
  ns <- asNamespace("AchillesNext")
  ids <- sort(setdiff(ls(ns, all.names = TRUE), c(".__NAMESPACE__.", ".__S3MethodsTable__.", ".packageName")))
  syntax <- function(x) paste(deparse(x, width.cutoff = 500L,
    control = c("keepInteger", "quoteExpressions", "showAttributes", "keepNA", "S_compatible")), collapse = "\n")
  bindings <- lapply(ids, function(id) {
    x <- get(id, ns)
    .hash(if (is.function(x)) paste(syntax(formals(x)), syntax(body(x)), sep = "\n") else syntax(x))
  })
  sql <- system.file("sql/postgresql", package = "AchillesNext", mustWork = TRUE)
  paths <- sort(list.files(sql, pattern = "[.]sql$"))
  .object(package = as.character(utils::packageVersion("AchillesNext")), R = as.character(getRversion()),
    dependencies = stats::setNames(lapply(c("DatabaseConnector", "rJava", "jsonlite", "digest"), function(p) as.character(utils::packageVersion(p))), c("DatabaseConnector", "rJava", "jsonlite", "digest")),
    implementation_sha256 = .hash(.json(stats::setNames(bindings, ids))),
    sql_sha256 = stats::setNames(lapply(paths, function(p) digest::digest(file = file.path(sql, p), algo = "sha256")), paths))
}
.run_atomic <- function(value, path) {
  if (file.exists(path)) stop("Run record already exists", call. = FALSE)
  tmp <- tempfile(".pending-", tmpdir = dirname(path))
  on.exit(unlink(tmp), add = TRUE)
  .write_json(value, tmp)
  if (!file.rename(tmp, path)) stop("Cannot persist run record", call. = FALSE)
}
.run_save <- function(ctx) {
  revision <- ctx$revision + 1L
  record <- .object(format_version = "0.1.0", revision = revision, previous_sha256 = ctx$previous,
    plan_sha256 = ctx$planHash, recorded_at = .stamp(), state = ctx$state)
  path <- file.path(ctx$dir, "ledger", sprintf("%08d.json", revision))
  .run_atomic(record, path)
  ctx$revision <- revision
  ctx$previous <- digest::digest(file = path, algo = "sha256")
  invisible(NULL)
}
.run_read <- function(runDir) {
  root <- normalizePath(runDir, mustWork = TRUE)
  plan <- jsonlite::fromJSON(file.path(root, "plan.json"), simplifyVector = FALSE)
  if (!identical(plan$format_version, "0.1.0")) stop("Unsupported execution plan format", call. = FALSE)
  paths <- sort(list.files(file.path(root, "ledger"), pattern = "^[0-9]{8}[.]json$", full.names = TRUE))
  if (!length(paths)) stop("No committed execution record", call. = FALSE)
  hash <- digest::digest(file = file.path(root, "plan.json"), algo = "sha256")
  previous <- NULL; history <- list()
  for (i in seq_along(paths)) {
    record <- jsonlite::fromJSON(paths[i], simplifyVector = FALSE)
    if (basename(paths[i]) != sprintf("%08d.json", i - 1L) || !identical(record$format_version, "0.1.0") ||
        record$revision != i - 1L || !identical(record$plan_sha256, hash) || !identical(record$previous_sha256, previous) ||
        !record$state$status %in% c("requested", "planned", "running", "succeeded", "failed", "cancelled") ||
        !setequal(names(record$state$operations), vapply(plan$operations, function(op) op$id, "")) ||
        !all(vapply(record$state$operations, function(op) op$status %in% c("requested", "planned", "running", "succeeded", "failed", "skipped", "cancelled"), TRUE)))
      stop("Invalid or discontinuous execution ledger", call. = FALSE)
    previous <- digest::digest(file = paths[i], algo = "sha256")
    history[[i]] <- record
  }
  ctx <- new.env(parent = emptyenv())
  ctx$dir <- root; ctx$plan <- plan; ctx$planHash <- hash
  ctx$state <- record$state; ctx$revision <- as.integer(record$revision); ctx$previous <- previous; ctx$history <- history
  ctx
}

#' Persist a bounded measurement execution plan without connecting
#' @export
planMeasurementRun <- function(runDir, cdmSchema, sourceId, request, declaredCdmVersion,
                               numericStrategy = "reference", maxConcurrency = 1L) {
  if (!.string(sourceId)) stop("Explicit source identifier required", call. = FALSE)
  .check_request(request, sourceId); .numeric_strategy_sql(numericStrategy)
  if (!.string(cdmSchema) || !grepl("^cdm_tiny_[a-z0-9_]+_(53|54|55)$", cdmSchema) ||
      !.string(declaredCdmVersion) || !declaredCdmVersion %in% c("5.3", "5.4", "5.5") ||
      !identical(gsub(".", "", declaredCdmVersion, fixed = TRUE), sub(".*_", "", cdmSchema))) stop("Invalid marked fixture schema/version", call. = FALSE)
  if (length(maxConcurrency) != 1L || !is.numeric(maxConcurrency) || is.complex(maxConcurrency) || is.na(maxConcurrency) || maxConcurrency != 1)
    stop("This executor supports maxConcurrency = 1 only", call. = FALSE)
  if (!.string(runDir)) stop("Run directory must be new", call. = FALSE)
  link <- Sys.readlink(runDir)
  if (file.exists(runDir) || (!is.na(link) && nzchar(link))) stop("Run directory must be new", call. = FALSE)
  runDir <- file.path(normalizePath(dirname(runDir), mustWork = TRUE), basename(runDir))
  if (!dir.create(runDir, mode = "0700")) stop("Cannot reserve run directory", call. = FALSE)
  ready <- FALSE; on.exit(if (!ready) unlink(runDir, recursive = TRUE), add = TRUE)
  for (d in c("ledger", "staging")) if (!dir.create(file.path(runDir, d), mode = "0700")) stop("Cannot reserve run storage")
  profilePath <- system.file("analysis/alpha-measurement-v1.json", package = "AchillesNext", mustWork = TRUE)
  if (digest::digest(file = profilePath, algo = "sha256") != "2e106f260cbcfcaccab23c55846384886dc5c0b2d7178b48e62c7f82cbe18951") stop("Frozen profile mismatch", call. = FALSE)
  profile <- jsonlite::fromJSON(profilePath, simplifyVector = FALSE)
  op <- function(id, dependencies, outputs, resource, readiness = "succeeded") .object(id = id, dependencies = as.list(dependencies),
    readiness = readiness, outputs = as.list(outputs), resource_class = resource)
  observation <- c("observation.person_count", "observation.monthly_person_count", "observation.person_days")
  operations <- list(op("source.connect", character(), character(), "connection"),
    op("source.guard", "source.connect", character(), "metadata"),
    op("person.count", "source.guard", "person.count", "source_distinct_count"),
    op("observation.compute", "person.count", observation, "interval_union_and_distinct_count"),
    op("measurement.compute", "observation.compute", .measurement_ids, "bounded_measurement_and_exact_quantiles"),
    op("bundle.write", c("person.count", "observation.compute", "measurement.compute"), "source.passport", "local_aggregate_export", "terminal"))
  outputs <- lapply(profile$metrics, function(m) {
    at <- Filter(function(op) m$id %in% unlist(op$outputs), operations)
    .object(metric_id = m$id, metric_version = m$version, dependencies = m$dependencies,
      operation_id = if (length(at)) at[[1]]$id else NULL)
  })
  plan <- .object(format_version = "0.1.0", run_id = paste0("run-", .hash(paste(.stamp(), tempfile(), runDir))),
    source_id = sourceId, cdm_schema = cdmSchema, declared_cdm_version = declaredCdmVersion,
    request = request, request_sha256 = .hash(.json(request)), numeric_strategy = numericStrategy,
    profile_sha256 = digest::digest(file = profilePath, algo = "sha256"), definitions = .run_definitions(),
    max_concurrency = 1L, requested_outputs = profile$required_outputs, outputs = outputs, operations = operations,
    shared_inputs = list(
      .object(id = "observed_intervals", scope = "observation SQL statement", consumers = as.list(observation), strategy = "MATERIALIZED CTE"),
      .object(id = "observation_counts", scope = "same run/snapshot", consumers = as.list(setdiff(.measurement_ids, "measurement.numeric_summary")), strategy = "in-memory aggregate denominators"),
      .object(id = "classified", scope = "measurement SQL statement", consumers = as.list(.measurement_ids), strategy = "MATERIALIZED CTE"),
      .object(id = "frequency_inputs", scope = "measurement SQL statement", consumers = as.list(c("exact_n_and_sum", if (numericStrategy == "weighted") "weighted_quantile_ranks")), strategy = if (numericStrategy == "weighted") "Multiply-referenced CTE; PostgreSQL default materialization" else "Single-consumer CTE; folding permitted")),
    limitations = as.list(c("Synthetic PostgreSQL only; cost classes are descriptive, not cardinality estimates", "Observation membership is recomputed within measurement SQL; no cross-statement interval cache", "No durable source identity, retry/resume, complete publication or disclosure approval")))
  .run_atomic(plan, file.path(runDir, "plan.json"))
  ids <- vapply(operations, function(op) op$id, "")
  states <- stats::setNames(lapply(ids, function(id) .object(status = "requested", cause = NULL, attempt = 0L,
    started_at = NULL, ended_at = NULL, duration_ms = NULL, timing_reason = "Not started", queries = list(),
    query_id = NULL, query_id_reason = "PostgreSQL JDBC does not expose a warehouse query identifier")), ids)
  ctx <- new.env(parent = emptyenv()); ctx$dir <- runDir; ctx$planHash <- digest::digest(file = file.path(runDir, "plan.json"), algo = "sha256")
  ctx$revision <- -1L; ctx$previous <- NULL
  ctx$state <- .object(status = "requested", cause = NULL, attempt = 0L, operations = states,
    outputs = lapply(outputs, function(o) .object(metric_id = o$metric_id, status = "requested", availability = NULL, reason = "Not executed")),
    bundle = .object(path = NULL, publication = NULL, reason = "Not generated"))
  .run_save(ctx)
  ctx$state$status <- "planned"
  for (id in ids) ctx$state$operations[[id]]$status <- "planned"
  for (i in seq_along(ctx$state$outputs)) ctx$state$outputs[[i]]$status <- "planned"
  .run_save(ctx); ready <- TRUE
  invisible(runDir)
}
.run_cause <- function(code, dependency = NULL) .object(code = code, dependency = dependency)
.run_error_code <- function(error) {
  message <- conditionMessage(error)
  codes <- c(TRACER_CONNECTION_FAILED = "connection_failed", TRACER_UNMARKED_SOURCE = "source_identity_failed",
    TRACER_INVALID_COUNT = "invalid_count", TRACER_PERSON_INTEGRITY = "person_integrity_failed",
    "Cannot create new output directory" = "artifact_write_failed", "Result exceeds" = "artifact_limit",
    "Bundle exceeds" = "artifact_limit")
  at <- which(vapply(names(codes), function(prefix) startsWith(message, prefix), TRUE))
  if (length(at)) unname(codes[at[1]]) else "operation_error"
}
.run_control <- function(ctx) {
  queries <- list()
  update <- function(id, status, cause = NULL) {
    ctx$state$operations[[id]]$status <- status; ctx$state$operations[[id]]["cause"] <- list(cause); .run_save(ctx)
  }
  list(query = function(record) {queries[[length(queries) + 1L]] <<- record; invisible(NULL)},
    skip = function(id, dependency) {
      if (ctx$state$operations[[id]]$status != "planned" || !ctx$state$operations[[dependency]]$status %in% c("failed", "skipped", "cancelled")) stop("Invalid dependency skip")
      update(id, "skipped", .run_cause("dependency_unsatisfied", dependency))
    },
    step = function(id, work) {
      op <- Filter(function(op) op$id == id, ctx$plan$operations)[[1]]
      dependencies <- vapply(unlist(op$dependencies), function(d) ctx$state$operations[[d]]$status, "")
      allowed <- if (op$readiness == "terminal") c("succeeded", "failed", "skipped", "cancelled") else "succeeded"
      if (ctx$state$operations[[id]]$status != "planned" || !all(dependencies %in% allowed)) stop("Operation dependencies are not ready")
      queries <<- list()
      ctx$state$operations[[id]]$attempt <- 1L; ctx$state$operations[[id]]$started_at <- .stamp()
      update(id, "running")
      start <- proc.time()[["elapsed"]]
      finish <- function(status, cause = NULL) {
        ctx$state$operations[[id]]$ended_at <- .stamp(); ctx$state$operations[[id]]$duration_ms <- .run_ms(start)
        ctx$state$operations[[id]]["timing_reason"] <- list(NULL); ctx$state$operations[[id]]$queries <- queries
        update(id, status, cause)
      }
      result <- tryCatch(work(), interrupt = function(e) {finish("cancelled", .run_cause("interrupted")); stop(e)},
        error = function(e) {finish("failed", .run_cause(.run_error_code(e))); stop("Operation failed; inspect the durable run ledger", call. = FALSE)})
      bad <- id %in% c("observation.compute", "measurement.compute") && !identical(result$state, "computed")
      finish(if (bad) "failed" else "succeeded", if (bad) .run_cause(paste0("result_", result$state)) else NULL)
      result
    })
}
.run_terminal <- function(ctx, status, cause) {
  for (id in names(ctx$state$operations)) if (ctx$state$operations[[id]]$status %in% c("planned", "running")) {
    ctx$state$operations[[id]]$status <- if (status == "cancelled") "cancelled" else "skipped"
    ctx$state$operations[[id]]$cause <- .run_cause(if (status == "cancelled") "interrupted" else "run_aborted")
  }
  for (i in seq_along(ctx$state$outputs)) if (ctx$state$outputs[[i]]$status %in% c("requested", "planned")) {
    ctx$state$outputs[[i]]$status <- if (status == "cancelled") "cancelled" else "failed"
    ctx$state$outputs[[i]]$availability <- "unavailable"; ctx$state$outputs[[i]]$reason <- "Run ended before result export"
  }
  ctx$state$status <- status; ctx$state["cause"] <- list(cause); .run_save(ctx)
}

#' Execute a new persisted measurement plan once
#' @export
executeMeasurementRun <- function(runDir, connectionDetails) {
  if (!inherits(connectionDetails, "ConnectionDetails") || !identical(connectionDetails$dbms, "postgresql")) stop("PostgreSQL connection details required", call. = FALSE)
  ctx <- .run_read(runDir)
  lock <- file.path(ctx$dir, ".writer-lock")
  if (!dir.create(lock, mode = "0700", showWarnings = FALSE)) stop("Run is locked; no automatic lock takeover or resume", call. = FALSE)
  on.exit(unlink(lock, recursive = TRUE), add = TRUE)
  ctx <- .run_read(runDir)
  if (ctx$state$status != "planned") stop("Only a new planned run can execute; create another run", call. = FALSE)
  if (!identical(.json(ctx$plan$definitions), .json(.run_definitions()))) stop("Installed definitions changed after planning; create another run", call. = FALSE)
  ctx$state$status <- "running"; ctx$state$attempt <- 1L; .run_save(ctx)
  p <- ctx$plan; control <- .run_control(ctx)
  tryCatch({
    .generate_tracer(connectionDetails, p$cdm_schema, p$source_id, file.path(ctx$dir, "staging", "bundle"),
      p$request, p$declared_cdm_version, TRUE, TRUE, p$numeric_strategy, control, p$run_id)
    manifest <- jsonlite::fromJSON(file.path(ctx$dir, "staging/bundle/manifest.json"), simplifyVector = FALSE)
    ctx$state$outputs <- lapply(manifest$outputs, function(o) .object(metric_id = o$metric_id,
      status = if (o$state %in% c("computed", "empty_source", "empty_population", "suppressed")) "succeeded" else if (o$state %in% c("unsupported", "not_requested")) "skipped" else "failed",
      availability = o$state, reason = o$reason))
    ctx$state$bundle <- .object(path = "staging/bundle", publication = manifest$publication, reason = "Unvalidated partial staging bundle; no current pointer")
    complete <- all(vapply(ctx$state$outputs, function(o) o$status == "succeeded", TRUE))
    .run_terminal(ctx, if (complete) "succeeded" else "failed", if (complete) NULL else .run_cause("requested_outputs_incomplete"))
  }, interrupt = function(e) .run_terminal(ctx, "cancelled", .run_cause("interrupted")),
     error = function(e) .run_terminal(ctx, "failed", .run_cause("run_aborted")))
  invisible(inspectMeasurementRun(ctx$dir))
}

#' Inspect persisted execution history without connecting or resuming
#' @export
inspectMeasurementRun <- function(runDir) {
  ctx <- .run_read(runDir)
  .object(plan = ctx$plan, state = ctx$state, history = ctx$history,
    liveness = "Last persisted states only; process liveness is not asserted. Running after a crash is not success.")
}
