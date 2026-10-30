# Publication is a separate, explicit action over a validated local run.
.publication_profile <- function() jsonlite::fromJSON(system.file("analysis/alpha-measurement-v1.json", package = "AchillesNext", mustWork = TRUE), simplifyVector = FALSE)
.publication_validate <- function(path) {
  node <- Sys.which("node")
  if (!nzchar(node)) stop("Node.js 22.12 or newer is required for publication validation", call. = FALSE)
  script <- system.file("validation/validate.mjs", package = "AchillesNext", mustWork = TRUE)
  lock <- jsonlite::fromJSON(system.file("validation/validator-lock.json", package = "AchillesNext", mustWork = TRUE))
  if (!identical(digest::digest(file = script, algo = "sha256"), lock$sha256)) stop("Installed validator integrity failed", call. = FALSE)
  # Fixed diagnostic: never include raw validator exceptions, paths or values.
  if (system2(node, c(shQuote(script), shQuote(normalizePath(path, mustWork = TRUE))), stdout = FALSE, stderr = FALSE) != 0L)
    stop("Bundle validation failed", call. = FALSE)
  invisible(TRUE)
}
.publication_probes <- function(query, schema) {
  profile <- .publication_profile()
  columns <- query(paste0("SELECT c.relname AS table_name,a.attname AS column_name, ",
    "CASE WHEN a.attname IS NOT NULL AND has_schema_privilege(n.oid,'USAGE') AND has_column_privilege(c.oid,a.attname,'SELECT') THEN 'true' ELSE 'false' END AS readable ",
    "FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace ",
    "LEFT JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped ",
    "WHERE n.nspname='", schema, "' AND c.relkind IN ('r','p','v','m','f')"))
  lapply(profile$prerequisite_probes, function(p) {
    table <- p$table %in% columns$TABLE_NAME
    at <- which(columns$TABLE_NAME == p$table & columns$COLUMN_NAME == p$column)
    column <- length(at) == 1L
    readable <- column && identical(columns$READABLE[at], "true")
    availability <- if (!table || !column) "absent" else if (!readable) "inaccessible" else "available"
    # Dependencies are physical report prerequisites, not clinical coverage claims.
    required <- if (!p$required) character() else if (p$table == "person") c("person.count", "observation.person_count", "observation.monthly_person_count", "observation.person_days", .measurement_ids) else
      if (p$table == "observation_period") c("observation.person_count", "observation.monthly_person_count", "observation.person_days", .measurement_ids) else .measurement_ids
    .object(dimensions = .object(probe_id = p$id), denominator = NULL, state = "computed", reason = NULL,
      values = .object(table_present = table, column_present = column, readable = readable, required_for = as.list(required),
        availability = availability, reason = if (availability == "available") NULL else if (availability == "absent") "Table or column is absent" else "Column is not readable"))
  })
}
.publication_read <- function(path) {
  .publication_validate(path)
  m <- jsonlite::fromJSON(file.path(path, "manifest.json"), simplifyVector = FALSE)
  list(manifest = m, documents = stats::setNames(lapply(m$outputs, function(p) jsonlite::fromJSON(file.path(path, p$path), simplifyVector = FALSE)), vapply(m$outputs, function(p) p$metric_id, "")),
    terminology = jsonlite::fromJSON(file.path(path, m$terminology$path), simplifyVector = FALSE))
}
.publication_document <- function(m, id, rows = NULL, state = "computed", reason = NULL) {
  .object(contract_version = m$contract_version, bundle_id = m$bundle_id, source_id = m$source$source_id, run_id = m$run_id,
    request_sha256 = m$request_sha256, metric_id = id, metric_version = "1.0.0", state = state, reason = reason, rows = rows)
}
.publication_row <- function(dimensions, values) .object(dimensions = dimensions, denominator = NULL, state = "computed", reason = NULL, values = values)
.publication_status <- function(m, docs) .publication_document(m, "execution.output_status", lapply(m$outputs, function(p) {
  d <- docs[[p$metric_id]]
  .publication_row(.object(metric_id = p$metric_id), .object(state = if (p$metric_id == "execution.output_status") "computed" else d$state,
    reason = if (p$metric_id == "execution.output_status") NULL else d$reason, requested = TRUE, metric_version = "1.0.0", source_id = m$source$source_id))
}))
.publication_write <- function(bundle, path) {
  m <- bundle$manifest
  for (i in seq_along(m$outputs)) {
    d <- bundle$documents[[m$outputs[[i]]$metric_id]]
    p <- .object(metric_id = d$metric_id, metric_version = d$metric_version, state = d$state, reason = d$reason, path = paste0("results/", d$metric_id, ".json"))
    m$outputs[[i]] <- c(p, .write_json(d, file.path(path, p$path)), .object(rows = as.character(length(d$rows))))
  }
  m$terminology <- c(.object(path = "terminology.json"), .write_json(bundle$terminology, file.path(path, "terminology.json")))
  .write_json(m, file.path(path, "manifest.json"))
  invisible(NULL)
}
.publication_metadata <- function(b) {
  integrity <- function(doc) {
    text <- .json(doc)
    .object(sha256 = .hash(text), bytes = as.character(nchar(text, type = "bytes")))
  }
  b$manifest$outputs <- lapply(b$manifest$outputs, function(p) {
    d <- b$documents[[p$metric_id]]
    c(.object(metric_id = d$metric_id, metric_version = d$metric_version, state = d$state, reason = d$reason,
      path = paste0("results/", d$metric_id, ".json")), integrity(d), .object(rows = as.character(length(d$rows))))
  })
  b$manifest$terminology <- c(.object(path = "terminology.json"), integrity(b$terminology))
  b
}
.publication_finalize <- function(ctx) {
  path <- file.path(ctx$dir, "staging/bundle")
  b <- .publication_read(path); m <- b$manifest; docs <- b$documents
  m$contract_version <- "1.1.0"
  for (id in names(docs)) docs[[id]]$contract_version <- "1.1.0"
  b$terminology$contract_version <- "1.1.0"
  docs[["source.capabilities"]] <- .publication_document(m, "source.capabilities", ctx$capabilities)
  timings <- list()
  for (id in names(docs)) for (phase in unlist(m$timing_phases)) {
    output <- Filter(function(o) o$metric_id == id, ctx$plan$outputs)[[1]]
    op <- ctx$state$operations[[output$operation_id]]
    measured <- phase == "compute" && !output$operation_id %in% "bundle.write" && op$status == "succeeded" && !is.null(op$duration_ms)
    timings[[length(timings) + 1L]] <- .publication_row(.object(metric_id = id, phase = phase),
      .object(duration_ms = if (measured) op$duration_ms else NULL, availability = if (measured) "measured" else "unavailable",
        reason = if (measured) NULL else "Phase not measured separately; see operation ledger"))
  }
  docs[["execution.timing"]] <- .publication_document(m, "execution.timing", timings)
  docs[["execution.output_status"]] <- .publication_status(m, docs)
  m$reproducibility$limitation <- "One read-only repeatable-read session; durable snapshot identity is unknown. Input reuse is disabled."
  b$manifest <- m; b$documents <- docs
  .publication_write(b, path); .publication_validate(path)
  invisible(NULL)
}
.publication_project <- function(b, scope, approvalId) {
  m <- b$manifest; docs <- b$documents
  if (scope == "distributable") {
    # Reconstruct the small approved projection rather than copying any source
    # labels, vocabulary text, capabilities, dimensions or timing values.
    m$source <- .object(source_id = "fixture:synthetic", snapshot = c(.unknown("Not retained in distributable fixtures"), .object(immutable = FALSE, assertion_id = NULL, basis = NULL)),
      data_release = .unknown("Not retained in distributable fixtures"), vocabulary_release = .unknown("Not retained in distributable fixtures"),
      schema_fingerprint = .unknown("Not retained in distributable fixtures"), declared_cdm_version = m$source$declared_cdm_version)
    m$request$source_id <- "fixture:synthetic"
    m$request$output_scope <- scope; m$request$disclosure_policy_id <- "synthetic-aggregates-v1"
    m$request_sha256 <- .hash(.json(m$request))
    m$bundle_id <- paste0("bundle-", .hash(paste(m$run_id, scope, approvalId)))
    reason <- "Suppressed by synthetic-aggregates-v1; detailed fixture aggregates are not approved"
    projected <- lapply(names(docs), function(id) .publication_document(m, id, state = "suppressed", reason = reason)); names(projected) <- names(docs)
    # Only the all-source aggregate and fixed metadata survive the projection.
    d <- docs[["person.count"]]
    projected[["person.count"]] <- .publication_document(m, "person.count", d$rows, d$state, d$reason)
    projected[["source.passport"]] <- .publication_document(m, "source.passport", list(.publication_row(.object(),
      .object(source_id = m$source$source_id, source_snapshot_id = NULL, data_release_id = NULL, declared_cdm_version = m$source$declared_cdm_version,
        observed_schema_evidence = m$source$schema_fingerprint, vocabulary_release_id = NULL, profile_id = m$profile$id, profile_revision = m$profile$revision,
        metric_versions = stats::setNames(as.list(rep("1.0.0", length(docs))), names(docs)), run_id = m$run_id))))
    docs <- projected
    b$terminology <- .object(contract_version = "1.1.0", provider_id = "synthetic-aggregates-v1", provider_version = "1.0.0", source_id = m$source$source_id,
      vocabulary_release = m$source$vocabulary_release, concepts = list())
  } else m$bundle_id <- paste0("bundle-", .hash(paste(m$run_id, scope, approvalId)))
  for (id in names(docs)) docs[[id]]$bundle_id <- m$bundle_id
  docs[["execution.output_status"]] <- .publication_status(m, docs)
  m$publication <- "complete"; m$eligible_for_current_pointer <- TRUE
  m$disclosure <- .object(policy_id = m$request$disclosure_policy_id, applied = TRUE, approval_id = approvalId, scope = scope)
  b$manifest <- m; b$documents <- docs; .publication_metadata(b)
}
.publication_commit <- function(candidate, root, bundleId, rename = file.rename) {
  release <- file.path(root, "releases", bundleId)
  link <- Sys.readlink(release)
  if (file.exists(release) || (!is.na(link) && nzchar(link))) stop("Release already exists", call. = FALSE)
  if (!rename(candidate, release)) stop("Cannot finalize immutable release", call. = FALSE)
  # An interruption after this rename leaves only an unreferenced complete
  # release. The prior pointer is still valid; it is never deleted first.
  pointer <- .object(format_version = "1.0.0", bundle_id = bundleId, path = paste0("releases/", bundleId),
    manifest_sha256 = digest::digest(file = file.path(release, "manifest.json"), algo = "sha256"))
  tmp <- tempfile(".current-", tmpdir = root); on.exit(unlink(tmp), add = TRUE)
  .write_json(pointer, tmp)
  if (!rename(tmp, file.path(root, "current.json"))) stop("Cannot switch current pointer; prior current is preserved", call. = FALSE)
  invisible(release)
}

#' Publish a complete approved synthetic measurement bundle
#' @export
publishMeasurementRun <- function(runDir, publicationDir, approvalId, outputScope = "restricted", institutionalPolicy = NULL) {
  if (!.string(approvalId) || !grepl("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", approvalId) ||
      !.string(outputScope) || !outputScope %in% c("restricted", "distributable") ||
      (!is.null(institutionalPolicy) && !is.function(institutionalPolicy))) stop("Explicit approval ID, supported scope and optional policy function required", call. = FALSE)
  ctx <- .run_read(runDir)
  if (ctx$state$status != "succeeded" || !all(vapply(ctx$state$operations, function(op) op$status == "succeeded", TRUE)))
    stop("Only a successfully completed measurement run can publish", call. = FALSE)
  if (!identical(ctx$state$bundle$manifest_sha256, digest::digest(file = file.path(ctx$dir, "staging/bundle/manifest.json"), algo = "sha256")))
    stop("Run bundle changed after execution", call. = FALSE)
  b <- .publication_read(file.path(ctx$dir, "staging/bundle"))
  if (b$manifest$contract_version != "1.1.0" || b$manifest$run_id != ctx$plan$run_id || b$manifest$request_sha256 != ctx$plan$request_sha256 ||
      !all(vapply(b$manifest$outputs, function(o) o$state %in% c("computed", "empty_source", "empty_population"), TRUE))) stop("Run bundle is incomplete or mismatched", call. = FALSE)
  b <- .publication_project(b, outputScope, approvalId)
  if (!is.null(institutionalPolicy)) {
    approved <- tryCatch(institutionalPolicy(.object(manifest = b$manifest, content_sha256 = .hash(.json(b)))), error = function(e) FALSE)
    if (!identical(approved, TRUE)) stop("Institutional policy did not approve publication", call. = FALSE)
  }
  if (!.string(publicationDir)) stop("Publication directory required", call. = FALSE)
  root <- if (dir.exists(publicationDir)) normalizePath(publicationDir, mustWork = TRUE) else
    file.path(normalizePath(dirname(publicationDir), mustWork = TRUE), basename(publicationDir))
  if (startsWith(root, paste0(ctx$dir, "/")) || identical(root, ctx$dir)) stop("Publication store must be outside the run directory", call. = FALSE)
  if (!dir.exists(root) && !dir.create(root, mode = "0700")) stop("Cannot create publication store", call. = FALSE)
  lock <- file.path(root, ".publication-lock")
  if (!dir.create(lock, mode = "0700", showWarnings = FALSE)) stop("Publication store is locked; no automatic takeover", call. = FALSE)
  on.exit(unlink(lock, recursive = TRUE), add = TRUE)
  storeFile <- file.path(root, "store.json")
  expectedStore <- .object(format_version = "1.0.0", output_scope = outputScope)
  if (!file.exists(storeFile)) {
    if (!identical(list.files(root, all.files = TRUE, no.. = TRUE), ".publication-lock")) stop("New publication store must be empty", call. = FALSE)
    .run_atomic(expectedStore, storeFile)
  } else {
    stored <- .viewer_decode(.viewer_read(root, "store.json"))
    if (!identical(.json(stored), .json(expectedStore))) stop("Publication store scope mismatch", call. = FALSE)
    if (length(setdiff(list.files(root, all.files = TRUE, no.. = TRUE), c("store.json", "current.json", "releases", ".publication-lock"))))
      stop("Unexpected files in publication store", call. = FALSE)
  }
  releases <- file.path(root, "releases")
  if (!dir.exists(releases) && !dir.create(releases, mode = "0700")) stop("Cannot create releases directory", call. = FALSE)
  link <- Sys.readlink(releases)
  if (!is.na(link) && nzchar(link)) stop("Symlinked release storage is not accepted", call. = FALSE)
  candidate <- tempfile(".candidate-", tmpdir = root)
  if (!dir.create(candidate, mode = "0700") || !dir.create(file.path(candidate, "results"), mode = "0700")) stop("Cannot create publication candidate", call. = FALSE)
  on.exit(unlink(candidate, recursive = TRUE), add = TRUE)
  .publication_write(b, candidate); .publication_validate(candidate)
  .publication_commit(candidate, root, b$manifest$bundle_id)
}

#' Resolve and validate the current complete local release
#' @export
currentMeasurementBundle <- function(publicationDir) {
  root <- normalizePath(publicationDir, mustWork = TRUE)
  pointer <- .viewer_decode(.viewer_read(root, "current.json"))
  if (!identical(sort(names(pointer)), sort(c("format_version", "bundle_id", "path", "manifest_sha256"))) ||
      !identical(pointer$format_version, "1.0.0") || !.string(pointer$bundle_id) || !grepl("^bundle-[a-f0-9]{64}$", pointer$bundle_id) ||
      !identical(pointer$path, paste0("releases/", pointer$bundle_id))) stop("Invalid current pointer", call. = FALSE)
  path <- file.path(root, pointer$path)
  if (!identical(normalizePath(path, mustWork = TRUE), path)) stop("Symlinked release storage is not accepted", call. = FALSE)
  bytes <- .viewer_read(path, "manifest.json")
  if (!identical(.hash(rawToChar(bytes)), pointer$manifest_sha256)) stop("Current manifest integrity failed", call. = FALSE)
  .publication_validate(path)
  m <- .viewer_decode(bytes)
  if (!identical(m$bundle_id, pointer$bundle_id) || !identical(m$publication, "complete") || !identical(m$eligible_for_current_pointer, TRUE)) stop("Current release is not complete", call. = FALSE)
  path
}
