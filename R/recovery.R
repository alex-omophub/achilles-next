# Control messages are separate from the single-writer, hash-linked ledger.
.recovery_lock <- function(root) {
  lock <- file.path(root, ".cancel-lock")
  deadline <- proc.time()[["elapsed"]] + 5
  repeat {
    if (dir.create(lock, mode = "0700", showWarnings = FALSE)) return(lock)
    if (proc.time()[["elapsed"]] >= deadline) stop("Cancellation control is busy; no stale-lock takeover", call. = FALSE)
    Sys.sleep(0.02)
  }
}
.recovery_interrupt <- function() structure(list(message = "Measurement cancellation requested", call = NULL), class = c("AchillesCancellation", "interrupt", "condition"))
.recovery_requested <- function(ctx) {
  path <- file.path(ctx$dir, "cancel-request.json")
  if (!file.exists(path)) return(FALSE)
  r <- .viewer_decode(.viewer_read(ctx$dir, "cancel-request.json"))
  if (!identical(r$format_version, "1.0.0") || !identical(r$run_id, ctx$plan$run_id) || !identical(r$plan_sha256, ctx$planHash)) stop("Invalid cancellation request", call. = FALSE)
  TRUE
}
.recovery_check <- function(ctx) {
  if (.recovery_requested(ctx)) stop(.recovery_interrupt())
  invisible(NULL)
}
.recovery_cleanup <- function(ctx) {
  staging <- file.path(ctx$dir, "staging")
  path <- file.path(staging, "bundle")
  safe <- dir.exists(staging) && identical(normalizePath(staging, mustWork = TRUE), staging)
  if (safe) {
    link <- Sys.readlink(path)
    if (!is.na(link) && nzchar(link)) unlink(path) else if (file.exists(path)) unlink(path, recursive = TRUE)
  }
  removed <- safe && !file.exists(path) && (is.na(Sys.readlink(path)) || !nzchar(Sys.readlink(path)))
  ctx$state$bundle <- .object(path = if (removed) NULL else "staging/bundle", publication = if (removed) NULL else "partial",
    reason = if (removed) "Cancellation acknowledged; run-scoped bundle staging removed" else "Cancellation acknowledged; staging cleanup unavailable, unvalidated files may remain")
  ctx$state$cancellation <- .object(acknowledged = TRUE, cleanup = if (removed) "removed" else "unavailable", remaining_operations =
    as.list(names(Filter(function(op) op$status != "succeeded", ctx$state$operations))))
  invisible(NULL)
}
.recovery_terminal <- function(ctx, status, cause) {
  lock <- .recovery_lock(ctx$dir); on.exit(unlink(lock, recursive = TRUE), add = TRUE)
  # Serialize the last cancellation check with accepting cancellation requests.
  if (.recovery_requested(ctx)) {status <- "cancelled"; cause <- .run_cause("cancellation_requested")}
  .run_terminal(ctx, status, cause)
}
.recovery_endpoint <- function(session) {
  x <- session$query("SELECT current_database() AS database_name, shobj_description(oid,'pg_database') AS marker, COALESCE(inet_server_addr()::text,'local') AS address, COALESCE(inet_server_port()::text,'local') AS port, current_user AS role FROM pg_database WHERE datname=current_database()")
  if (nrow(x) != 1L || !identical(x$DATABASE_NAME, "achilles_next_fixtures") || !identical(x$MARKER, "AchillesNext synthetic fixture sandbox v1")) stop("TRACER_UNMARKED_SOURCE", call. = FALSE)
  .hash(.json(as.list(x[1, c("DATABASE_NAME", "ADDRESS", "PORT", "ROLE"), drop = FALSE])))
}
.recovery_bind <- function(ctx, session) {
  endpoint <- .recovery_endpoint(session)
  application <- paste0("achilles-next-", substr(.hash(ctx$plan$run_id), 1, 40))
  session$query(paste0("SELECT set_config('application_name','", application, "',false) AS name"))
  backend <- session$query("SELECT pid::text AS pid,backend_start::text AS started FROM pg_stat_activity WHERE pid=pg_backend_pid()")
  if (nrow(backend) != 1L) stop("Cannot register execution session", call. = FALSE)
  ctx$state$backend <- .object(pid = backend$PID, backend_start = backend$STARTED, application_name = application, endpoint_sha256 = endpoint,
    kind = "PostgreSQL backend process identity, not a query identifier")
  schema <- session$query(paste0("SELECT c.relname AS table_name,a.attname AS column_name,format_type(a.atttypid,a.atttypmod) AS type,a.attnotnull::text AS not_null ",
    "FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid ",
    "WHERE n.nspname='", ctx$plan$cdm_schema, "' AND a.attnum>0 AND NOT a.attisdropped AND c.relkind IN ('r','p','v','m','f') ORDER BY c.relname,a.attname"))
  ctx$state$input_identity <- .object(snapshot = .unknown("No durable immutable snapshot assertion; recovery must recompute"),
    source_id = ctx$plan$source_id, data_release = .unknown("No validated immutable data release identifier"),
    endpoint_sha256 = endpoint, schema_sha256 = .hash(.json(lapply(seq_len(nrow(schema)), function(i) as.list(schema[i, , drop = FALSE])))),
    capabilities_sha256 = .hash(.json(ctx$capabilities)), vocabulary_release = .unknown("Not yet read"), terminology_sha256 = NULL)
  .run_save(ctx)
  invisible(NULL)
}
.recovery_signal <- function(backend, connectionDetails) {
  if (is.null(backend)) return(.object(state = "unavailable", reason = "Executor has not registered a database session"))
  if (!inherits(connectionDetails, "ConnectionDetails") || !identical(connectionDetails$dbms, "postgresql")) return(.object(state = "unavailable", reason = "PostgreSQL connection details were not supplied"))
  # Validate every token before SQL construction, even for trusted local ledgers.
  if (!.string(backend$pid) || !grepl("^[1-9][0-9]{0,9}$", backend$pid) || as.numeric(backend$pid) > 2147483647 ||
      !.string(backend$backend_start) || !grepl("^[0-9 .:+-]+$", backend$backend_start) ||
      !.string(backend$application_name) || !grepl("^achilles-next-[a-f0-9]{40}$", backend$application_name))
    return(.object(state = "unavailable", reason = "Invalid recorded backend identity"))
  connection <- NULL
  on.exit(if (!is.null(connection)) try(DatabaseConnector::disconnect(connection), silent = TRUE), add = TRUE)
  tryCatch({
    connection <- DatabaseConnector::connect(connectionDetails)
    session <- .tracer_session(connection)
    on.exit(try(session$rollback(), silent = TRUE), add = TRUE, after = FALSE)
    session$execute("SET LOCAL statement_timeout='5s'")
    if (!identical(.recovery_endpoint(session), backend$endpoint_sha256)) return(.object(state = "unavailable", reason = "Database/role identity differs from execution"))
    x <- session$query(paste0("SELECT CASE WHEN pg_cancel_backend(pid) THEN 'true' ELSE 'false' END AS sent FROM pg_stat_activity ",
      "WHERE pid=", backend$pid, " AND backend_start::text='", backend$backend_start, "' AND application_name='", backend$application_name,
      "' AND datname=current_database() AND usename=current_user"))
    if (!nrow(x)) .object(state = "not_active", reason = "Matching run session is no longer present") else
      if (identical(x$SENT, "true")) .object(state = "signal_sent", reason = "PostgreSQL accepted a query cancellation signal; executor acknowledgement is separate") else
        .object(state = "unavailable", reason = "PostgreSQL did not accept the cancellation signal")
  }, error = function(e) .object(state = "unavailable", reason = "Database cancellation could not be confirmed; cooperative request remains recorded"))
}

#' Request cancellation of one local measurement run
#' @export
cancelMeasurementRun <- function(runDir, connectionDetails = NULL) {
  ctx <- .run_read(runDir)
  lock <- .recovery_lock(ctx$dir); locked <- TRUE
  on.exit(if (locked) unlink(lock, recursive = TRUE), add = TRUE)
  ctx <- .run_read(runDir)
  if (ctx$state$status %in% c("succeeded", "failed", "cancelled")) return(.object(requested = FALSE, state = ctx$state$status,
    acknowledged = identical(ctx$state$status, "cancelled"), database = .object(state = "not_needed", reason = "Run is already terminal")))
  if (!.recovery_requested(ctx)) .run_atomic(.object(format_version = "1.0.0", run_id = ctx$plan$run_id, plan_sha256 = ctx$planHash,
    requested_at = .stamp()), file.path(ctx$dir, "cancel-request.json"))
  locked <- FALSE; unlink(lock, recursive = TRUE) # Relinquish ownership before releasing the lock.
  database <- .recovery_signal(ctx$state$backend, connectionDetails)
  # A receipt is observational control metadata, not a second ledger writer.
  lock <- .recovery_lock(ctx$dir); locked <- TRUE
  response <- .object(format_version = "1.0.0", recorded_at = .stamp(), run_id = ctx$plan$run_id, plan_sha256 = ctx$planHash, database = database)
  path <- file.path(ctx$dir, "cancel-response.json"); tmp <- tempfile(".cancel-", tmpdir = ctx$dir)
  on.exit(unlink(tmp), add = TRUE); .write_json(response, tmp)
  if (!file.rename(tmp, path)) stop("Cannot record cancellation response", call. = FALSE)
  latest <- .run_read(ctx$dir)
  .object(requested = TRUE, state = latest$state$status, acknowledged = identical(latest$state$status, "cancelled"), database = database)
}
.recovery_status <- function(ctx) {
  response <- if (file.exists(file.path(ctx$dir, "cancel-response.json"))) .viewer_decode(.viewer_read(ctx$dir, "cancel-response.json")) else NULL
  if (!is.null(response) && (!identical(response$format_version, "1.0.0") || !identical(response$run_id, ctx$plan$run_id) || !identical(response$plan_sha256, ctx$planHash)))
    stop("Invalid cancellation response", call. = FALSE)
  .object(lineage = ctx$plan$recovery, cancellation_requested = .recovery_requested(ctx), cancellation_response = response,
    reuse = "disabled", reason = "No durable input identity assertion is supported; every recovery attempt recomputes all operations")
}
.recovery_claim_lost <- function(message) structure(list(message = message, call = NULL), class = c("AchillesRecoveryClaimLost", "error", "condition"))
.recovery_observe <- function(target, key) {
  deadline <- proc.time()[["elapsed"]] + 5
  repeat {
    child <- .run_read(target)
    if (!identical(child$plan$recovery$key, key)) stop("Recovery target belongs to another source plan or definitions; choose a new directory", call. = FALSE)
    if (!child$state$status %in% c("requested", "planned") || !dir.exists(file.path(target, ".writer-lock")) || proc.time()[["elapsed"]] >= deadline)
      return(invisible(inspectMeasurementRun(target)))
    Sys.sleep(0.02)
  }
}

#' Recover work into an isolated, idempotent new measurement attempt
#' @export
resumeMeasurementRun <- function(runDir, newRunDir, connectionDetails) {
  parent <- .run_read(runDir); p <- parent$plan
  if (!.string(newRunDir)) stop("New recovery directory required", call. = FALSE)
  target <- if (dir.exists(newRunDir)) normalizePath(newRunDir, mustWork = TRUE) else file.path(normalizePath(dirname(newRunDir), mustWork = TRUE), basename(newRunDir))
  if (identical(target, parent$dir) || startsWith(target, paste0(parent$dir, "/"))) stop("Recovery directory must be outside the previous run", call. = FALSE)
  definitions <- .run_definitions()
  key <- .hash(.json(.object(parent_plan_sha256 = parent$planHash, definitions = definitions)))
  if (dir.exists(target)) {
    child <- .run_read(target)
    if (!identical(child$plan$recovery$key, key)) stop("Recovery target belongs to another source plan or definitions; choose a new directory", call. = FALSE)
    if (child$state$status != "planned" || dir.exists(file.path(target, ".writer-lock"))) return(.recovery_observe(target, key))
  } else {
    recovery <- .object(key = key, root_run_id = p$recovery$root_run_id %||% p$run_id, parent_run_id = p$run_id, parent_plan_sha256 = parent$planHash,
      parent_revision_sha256 = parent$previous, attempt = (p$recovery$attempt %||% 1L) + 1L, reused_operations = list(),
      recompute_reason = if (!identical(.json(p$definitions), .json(definitions))) "Definitions changed and durable source identity is unknown" else "Durable source identity is unknown",
      recompute_operations = as.list(vapply(p$operations, function(op) op$id, "")))
    .plan_measurement_run(target, p$cdm_schema, p$source_id, p$request, p$declared_cdm_version, p$numeric_strategy, 1L, recovery)
  }
  tryCatch(executeMeasurementRun(target, connectionDetails),
    AchillesRecoveryClaimLost = function(e) .recovery_observe(target, key))
}
