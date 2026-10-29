# Exact UTF-8 JSON: named lists are objects, unnamed lists are arrays, scalars
# stay scalars. In particular, an empty dimensions object is never an array.
.object <- function(...) structure(list(...), names = names(list(...)) %||% character())
`%||%` <- function(x, y) if (is.null(x)) y else x
.json <- function(x) {
  if (is.null(x)) return("null")
  if (is.list(x)) {
    if (!is.null(names(x))) {
      if (anyDuplicated(names(x))) stop("Duplicate JSON keys", call. = FALSE)
      keys <- sort(names(x), method = "radix")
      return(paste0("{", paste(vapply(keys, function(k) paste0(.json(k), ":", .json(x[[k]])), ""), collapse = ","), "}"))
    }
    return(paste0("[", paste(vapply(x, .json, ""), collapse = ","), "]"))
  }
  if (length(x) != 1L || anyNA(x)) stop("JSON values must be explicit scalars or lists", call. = FALSE)
  as.character(jsonlite::toJSON(x, auto_unbox = TRUE, digits = NA))
}
.hash <- function(x) digest::digest(charToRaw(enc2utf8(x)), algo = "sha256", serialize = FALSE)
.stamp <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
.unknown <- function(reason) .object(state = "unknown", id = NULL, reason = reason)
.string <- function(x) is.character(x) && length(x) == 1L && !is.na(x) && nzchar(x)
.write_json <- function(value, path) {
  bytes <- charToRaw(enc2utf8(.json(value)))
  writeBin(bytes, path)
  Sys.chmod(path, "0600")
  .object(sha256 = digest::digest(bytes, algo = "sha256", serialize = FALSE), bytes = as.character(length(bytes)))
}
.check_request <- function(request, sourceId) {
  keys <- c("profile_id", "source_id", "window", "measurement_concept_ids", "output_scope", "disclosure_policy_id")
  if (!is.list(request) || anyDuplicated(names(request)) || !setequal(names(request), keys) ||
      !identical(request$profile_id, "alpha-measurement-v1") || !identical(request$source_id, sourceId) ||
      !identical(request$output_scope, "restricted") ||
      !identical(request$disclosure_policy_id, "synthetic-unsuppressed-v1")) stop("Invalid synthetic tracer request", call. = FALSE)
  window <- request$window
  if (!is.list(window) || !setequal(names(window), c("start", "end")) || anyDuplicated(names(window))) stop("Invalid date window", call. = FALSE)
  validDate <- function(x) .string(x) && grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x) && substr(x, 1, 4) != "0000" &&
    !is.na(as.Date(x, format = "%Y-%m-%d")) && identical(format(as.Date(x), "%Y-%m-%d"), x)
  if (!validDate(window$start) || !validDate(window$end) || window$start > window$end) stop("Invalid date window", call. = FALSE)
  month <- function(x) as.integer(substr(x, 1, 4)) * 12L + as.integer(substr(x, 6, 7))
  if (month(window$end) - month(window$start) + 1L > 120L) stop("Window exceeds 120 months", call. = FALSE)
  ids <- request$measurement_concept_ids
  if (!is.list(ids) || !is.null(names(ids)) || length(ids) < 1L || length(ids) > 10L ||
      !all(vapply(ids, function(x) is.numeric(x) && length(x) == 1L && is.finite(x) && x >= 0 && x <= 2147483647 && x == floor(x), TRUE)) ||
      anyDuplicated(unlist(ids))) stop("Invalid explicit concept IDs", call. = FALSE)
}

#' Generate an exact-count development bundle
#'
#' Only marked synthetic PostgreSQL fixture schemas are accepted. The function
#' uses its own read-only transaction, never writes source tables, and refuses
#' an existing output directory. It does not publish a complete alpha result.
#' @export
generateCountTracer <- function(connectionDetails, cdmSchema, sourceId, outputDir,
                                request, declaredCdmVersion) {
  if (!inherits(connectionDetails, "ConnectionDetails") || !identical(connectionDetails$dbms, "postgresql")) stop("PostgreSQL connection details required", call. = FALSE)
  if (!.string(cdmSchema) || !grepl("^cdm_tiny_[a-z0-9_]+_(53|54|55)$", cdmSchema)) stop("A marked tiny fixture schema is required", call. = FALSE)
  if (!.string(sourceId) || !.string(outputDir) || !.string(declaredCdmVersion) || !declaredCdmVersion %in% c("5.3", "5.4", "5.5") ||
      !identical(gsub(".", "", declaredCdmVersion, fixed = TRUE), sub(".*_", "", cdmSchema))) stop("Invalid source/output/version configuration", call. = FALSE)
  .check_request(request, sourceId)
  link <- Sys.readlink(outputDir)
  if (file.exists(outputDir) || dir.exists(outputDir) || (!is.na(link) && nzchar(link))) stop("Output directory must be new", call. = FALSE)
  parent <- normalizePath(dirname(outputDir), mustWork = TRUE)
  outputDir <- file.path(parent, basename(outputDir))
  started <- .stamp()
  connection <- tryCatch(DatabaseConnector::connect(connectionDetails), error = function(e) stop("TRACER_CONNECTION_FAILED: check local configuration and driver", call. = FALSE))
  on.exit(try(DatabaseConnector::disconnect(connection), silent = TRUE), add = TRUE)
  errorFile <- tempfile("achilles-next-sql-", fileext = ".txt")
  on.exit(unlink(errorFile), add = TRUE)
  query <- function(sql) tryCatch(DatabaseConnector::querySql(connection, sql, errorReportFile = errorFile,
      integerAsNumeric = FALSE, integer64AsNumeric = FALSE), error = function(e) stop("TRACER_QUERY_FAILED: source is unavailable or inaccessible", call. = FALSE))
  execute <- function(sql) tryCatch(DatabaseConnector::executeSql(connection, sql, progressBar = FALSE,
      reportOverallTime = FALSE, errorReportFile = errorFile), error = function(e) stop("TRACER_TRANSACTION_FAILED", call. = FALSE))
  execute("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
  on.exit(try(execute("ROLLBACK"), silent = TRUE), add = TRUE, after = FALSE)
  # Fixed identifiers and a validated schema prevent SQL interpolation of input.
  guard <- query(paste0("SELECT current_database() AS database_name, current_setting('transaction_read_only') AS read_only, ",
    "shobj_description(d.oid, 'pg_database') AS database_marker, obj_description(n.oid, 'pg_namespace') AS schema_marker ",
    "FROM pg_database d CROSS JOIN pg_namespace n WHERE d.datname=current_database() AND n.nspname='", cdmSchema, "'"))
  marker <- "AchillesNext synthetic fixture sandbox v1"
  if (nrow(guard) != 1L || !identical(guard[["DATABASE_NAME"]], "achilles_next_fixtures") ||
      !identical(guard[["READ_ONLY"]], "on") || !identical(guard[["DATABASE_MARKER"]], marker) ||
      !identical(guard[["SCHEMA_MARKER"]], paste0(marker, ": ", cdmSchema))) stop("TRACER_UNMARKED_SOURCE: fixture identity/read-only check failed", call. = FALSE)
  counts <- query(paste0('SELECT COUNT(*)::text AS records, COUNT(person_id)::text AS nonnull_ids, ',
    'COUNT(DISTINCT person_id)::text AS people FROM "', cdmSchema, '"."person"'))
  if (nrow(counts) != 1L || !all(vapply(counts, function(x) is.character(x) && length(x) == 1L && !is.na(x) && grepl("^(0|[1-9][0-9]*)$", x), TRUE))) stop("TRACER_INVALID_COUNT: driver must preserve exact count text", call. = FALSE)
  if (!identical(counts[["RECORDS"]], counts[["NONNULL_IDS"]]) || !identical(counts[["RECORDS"]], counts[["PEOPLE"]])) stop("TRACER_PERSON_INTEGRITY: null or duplicate person IDs", call. = FALSE)
  count <- counts[["PEOPLE"]]
  ended <- .stamp()
  profilePath <- system.file("analysis", "alpha-measurement-v1.json", package = "AchillesNext", mustWork = TRUE)
  profile <- jsonlite::fromJSON(profilePath, simplifyVector = FALSE)
  profileHash <- digest::digest(file = profilePath, algo = "sha256")
  if (profileHash != "2e106f260cbcfcaccab23c55846384886dc5c0b2d7178b48e62c7f82cbe18951") stop("Frozen profile mismatch", call. = FALSE)
  ids <- unlist(profile$required_outputs, use.names = FALSE)
  runId <- paste0("count-", .hash(paste(started, sourceId, tempfile(), sep = ":")))
  bundleId <- runId
  unknown <- .unknown("Not established by the count tracer")
  snapshot <- c(unknown, .object(immutable = FALSE, assertion_id = NULL, basis = NULL))
  source <- .object(source_id = sourceId, snapshot = snapshot, data_release = unknown,
    vocabulary_release = unknown, schema_fingerprint = .unknown("Only PERSON prerequisites were probed"), declared_cdm_version = declaredCdmVersion)
  requestHash <- .hash(.json(request))
  common <- .object(contract_version = "1.0.0", bundle_id = bundleId, source_id = sourceId, run_id = runId, request_sha256 = requestHash)
  unsupported <- "Not implemented by the count-only development tracer"
  documents <- lapply(ids, function(id) c(common, .object(metric_id = id, metric_version = "1.0.0", state = "unsupported", reason = unsupported, rows = NULL)))
  names(documents) <- ids
  computed <- function(id, values, state = "computed", reason = NULL) c(common, .object(metric_id = id, metric_version = "1.0.0", state = state, reason = reason,
    rows = list(.object(dimensions = .object(), denominator = NULL, state = state, reason = reason, values = values))))
  documents[["source.passport"]] <- computed("source.passport", .object(source_id = sourceId,
    source_snapshot_id = NULL, data_release_id = NULL, declared_cdm_version = declaredCdmVersion,
    observed_schema_evidence = source$schema_fingerprint, vocabulary_release_id = NULL,
    profile_id = profile$profile_id, profile_revision = profile$revision,
    metric_versions = stats::setNames(as.list(rep("1.0.0", length(ids))), ids), run_id = runId))
  documents[["person.count"]] <- computed("person.count", .object(count = count),
    if (count == "0") "empty_source" else "computed", if (count == "0") "Accessible PERSON is empty" else NULL)
  if (!dir.create(outputDir, mode = "0700")) stop("Cannot create new output directory", call. = FALSE)
  success <- FALSE
  on.exit(if (!success) unlink(outputDir, recursive = TRUE), add = TRUE)
  dir.create(file.path(outputDir, "results"), mode = "0700")
  partitions <- lapply(ids, function(id) {
    doc <- documents[[id]]
    path <- paste0("results/", id, ".json")
    integrity <- .write_json(doc, file.path(outputDir, path))
    c(.object(metric_id = id, metric_version = "1.0.0", state = doc$state, reason = doc$reason, path = path),
      integrity, .object(rows = as.character(length(doc$rows))))
  })
  terminology <- .object(contract_version = "1.0.0", provider_id = "count-tracer-no-terminology", provider_version = "1.0.0",
    source_id = sourceId, vocabulary_release = unknown, concepts = list())
  termIntegrity <- .write_json(terminology, file.path(outputDir, "terminology.json"))
  manifest <- .object(contract_version = "1.0.0", bundle_id = bundleId, run_id = runId, created_at = ended,
    generator = .object(name = "AchillesNext-count-tracer", version = "0.0.0.9000"),
    profile = .object(id = profile$profile_id, revision = profile$revision, sha256 = profileHash), source = source,
    request = request, request_sha256 = requestHash, publication = "partial", eligible_for_current_pointer = FALSE,
    disclosure = .object(policy_id = request$disclosure_policy_id, applied = FALSE, approval_id = NULL, scope = "restricted"),
    reproducibility = .object(consistent_snapshot = FALSE, execution_start = started, execution_end = ended,
      limitation = "Read-only repeatable-read query; no durable snapshot identity or disclosure approval, so reuse and complete publication are disabled"),
    outputs = partitions, terminology = c(.object(path = "terminology.json"), termIntegrity),
    timing_phases = as.list(c("compute", "materialize", "validate", "export")))
  .write_json(manifest, file.path(outputDir, "manifest.json"))
  success <- TRUE
  invisible(outputDir)
}
