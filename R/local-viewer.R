.viewer_error <- function(state, message) {
  stop(structure(list(message = message, call = NULL, state = state), class = c("AchillesViewerError", "error", "condition")))
}
.viewer_read <- function(root, path) {
  if (!.string(path) || !grepl("^[A-Za-z0-9_./-]+$", path) || grepl("..", path, fixed = TRUE) || startsWith(path, "/"))
    .viewer_error("invalid", "The bundle contains an unsafe file path.")
  target <- file.path(root, path)
  if (!file.exists(target)) .viewer_error("missing", "A declared result file is missing.")
  actual <- normalizePath(target, mustWork = TRUE)
  if (!identical(actual, target) || !startsWith(actual, paste0(root, "/")) || dir.exists(target))
    .viewer_error("invalid", "Result files must be ordinary files inside the selected folder, without symbolic links.")
  if (file.access(target, 4L) != 0L) .viewer_error("unavailable", "A result file cannot be read. Check local file permissions.")
  size <- file.info(target)$size
  if (is.na(size) || size > 10 * 1024 * 1024) .viewer_error("invalid", "A result file exceeds the 10 MiB viewer limit.")
  readBin(target, what = "raw", n = size + 1)
}
.viewer_decode <- function(bytes) {
  tryCatch(jsonlite::fromJSON(rawToChar(bytes), simplifyVector = FALSE),
    error = function(e) .viewer_error("invalid", "A result file is not valid JSON."))
}
.viewer_snapshot <- function(bundleDir) {
  tryCatch({
    if (!dir.exists(bundleDir)) .viewer_error("missing", "The selected results folder does not exist.")
    root <- normalizePath(bundleDir, mustWork = TRUE)
    files <- list("manifest.json" = .viewer_read(root, "manifest.json"))
    m <- .viewer_decode(files[["manifest.json"]])
    if (!is.list(m) || !.string(m$contract_version)) .viewer_error("invalid", "The manifest has no valid contract version.")
    if (m$contract_version != "1.0.0" || !identical(m$profile$id, "alpha-measurement-v1") ||
        !identical(m$profile$revision, "1.0.0") || !identical(m$generator$name, "AchillesNext-count-tracer") ||
        !identical(m$publication, "partial")) .viewer_error("incompatible", "This viewer supports partial count-tracer bundles using contract 1.0.0.")
    profilePath <- system.file("analysis/alpha-measurement-v1.json", package = "AchillesNext", mustWork = TRUE)
    profile <- jsonlite::fromJSON(profilePath, simplifyVector = FALSE)
    if (!identical(m$profile$sha256, digest::digest(file = profilePath, algo = "sha256")))
      .viewer_error("incompatible", "The results use a different analysis profile.")
    ids <- unlist(profile$required_outputs, use.names = FALSE)
    if (!is.list(m$outputs) || length(m$outputs) != length(ids) || !is.null(names(m$outputs)) ||
        !identical(m$eligible_for_current_pointer, FALSE) || !identical(m$request$output_scope, "restricted") ||
        !identical(m$disclosure$scope, "restricted")) .viewer_error("invalid", "The partial manifest structure or output scope is invalid.")
    declared <- vapply(m$outputs, function(p) if (.string(p$metric_id)) p$metric_id else "", "")
    if (anyDuplicated(declared) || !setequal(declared, ids)) .viewer_error("invalid", "The manifest must declare all 15 output partitions exactly once.")
    total <- length(files[["manifest.json"]])
    add <- function(partition, path) {
      if (!.string(partition$sha256) || !grepl("^[0-9a-f]{64}$", partition$sha256) || !.string(partition$bytes))
        .viewer_error("invalid", "A result file has invalid integrity metadata.")
      bytes <- .viewer_read(root, path)
      if (!identical(as.character(length(bytes)), partition$bytes) ||
          !identical(digest::digest(bytes, algo = "sha256", serialize = FALSE), partition$sha256))
        .viewer_error("invalid", "A result file changed or failed its integrity check.")
      total <<- total + length(bytes)
      if (total > 64 * 1024 * 1024) .viewer_error("invalid", "The bundle exceeds the 64 MiB viewer limit.")
      files[[path]] <<- bytes
      .viewer_decode(bytes)
    }
    for (p in m$outputs) {
      if (!.string(p$path) || !grepl("^results/[a-z][a-z0-9._-]*[.]json$", p$path) || p$path %in% names(files))
        .viewer_error("invalid", "The manifest has an unsafe or duplicate result path.")
      doc <- add(p, p$path)
      if (!identical(doc$metric_id, p$metric_id) || !identical(doc$source_id, m$source$source_id) ||
          !identical(doc$bundle_id, m$bundle_id) || !identical(doc$run_id, m$run_id) ||
          !identical(doc$request_sha256, m$request_sha256) || !identical(doc$state, p$state))
        .viewer_error("invalid", "A result document does not match its declared identity.")
    }
    if (!identical(m$terminology$path, "terminology.json")) .viewer_error("invalid", "The terminology path is invalid.")
    term <- add(m$terminology, "terminology.json")
    if (!identical(term$source_id, m$source$source_id)) .viewer_error("invalid", "Terminology belongs to a different source.")
    list(status = .object(state = "ready", message = NULL), files = files)
  }, AchillesViewerError = function(e) list(status = .object(state = e$state, message = e$message), files = list()),
  error = function(e) list(status = .object(state = "invalid", message = "The selected bundle could not be read. Check its structure and permissions."), files = list()))
}
.viewer_assets <- function() {
  root <- normalizePath(system.file("viewer", package = "AchillesNext", mustWork = TRUE), mustWork = TRUE)
  lock <- jsonlite::fromJSON(file.path(root, "viewer-lock.json"), simplifyVector = FALSE)
  if (!identical(lock$generated_by, "achilles-next-package-viewer") || !is.list(lock$files) ||
      !"index.html" %in% names(lock$files)) stop("Packaged viewer assets are unavailable; reinstall AchillesNext", call. = FALSE)
  assets <- lapply(names(lock$files), function(path) {
    bytes <- .viewer_read(root, path)
    if (!identical(digest::digest(bytes, algo = "sha256", serialize = FALSE), lock$files[[path]]))
      stop("Packaged viewer integrity failed; reinstall AchillesNext", call. = FALSE)
    bytes
  })
  names(assets) <- names(lock$files)
  html <- rawToChar(assets[["index.html"]])
  if (!grepl("<head>", html, fixed = TRUE)) stop("Packaged viewer HTML is invalid", call. = FALSE)
  assets[["index.html"]] <- charToRaw(sub("<head>", '<head><meta name="achilles-next-mode" content="served-bundle">', html, fixed = TRUE))
  assets
}

#' View generated results using the installed browser assets
#' @export
viewResults <- function(bundleDir, browse = TRUE, port = 0L, basePath = "/achilles-next/", block = !interactive()) {
  if (!.string(bundleDir) || !is.logical(browse) || length(browse) != 1L || is.na(browse) ||
      !is.logical(block) || length(block) != 1L || is.na(block)) stop("Supply a result folder and scalar browse/block flags", call. = FALSE)
  if (!is.numeric(port) || length(port) != 1L || !is.finite(port) || port != floor(port) ||
      !(port == 0 || (port >= 1024 && port <= 65535))) stop("Use port 0 or an unprivileged integer port", call. = FALSE)
  if (!.string(basePath) || !(basePath == "/" || grepl("^/([A-Za-z0-9_-]+/)+$", basePath)))
    stop("basePath must start and end with / and contain simple path segments", call. = FALSE)
  assets <- .viewer_assets()
  snapshot <- .viewer_snapshot(bundleDir)
  if (port == 0) port <- httpuv::randomPort(host = "127.0.0.1")
  origin <- paste0("http://127.0.0.1:", port)
  url <- paste0(origin, basePath)
  routes <- assets
  routes[["api/status.json"]] <- charToRaw(.json(snapshot$status))
  for (name in names(snapshot$files)) routes[[paste0("api/", name)]] <- snapshot$files[[name]]
  headers <- list("Cache-Control" = "no-store", "X-Content-Type-Options" = "nosniff",
    "Referrer-Policy" = "no-referrer", "Content-Security-Policy" = paste(
      "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self';",
      "img-src 'self' data:; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'"))
  response <- function(status, body, type = "text/plain; charset=utf-8")
    list(status = as.integer(status), headers = c(headers, list("Content-Type" = type)), body = body)
  call <- function(req) {
    host <- req$HTTP_HOST %||% ""
    requestOrigin <- req$HTTP_ORIGIN %||% ""
    if (!identical(host, paste0("127.0.0.1:", port)) || !(requestOrigin %in% c("", origin)))
      return(response(403L, "Local origin required"))
    if (!req$REQUEST_METHOD %in% c("GET", "HEAD")) return(response(405L, "Only GET and HEAD are supported"))
    path <- req$PATH_INFO
    if (!.string(path) || !startsWith(path, basePath) || nzchar(req$QUERY_STRING %||% "")) return(response(404L, "Not found"))
    key <- substring(path, nchar(basePath) + 1L)
    if (key == "") key <- "index.html"
    if (!key %in% names(routes)) return(response(404L, "Not found"))
    type <- if (key == "index.html") "text/html; charset=utf-8" else if (endsWith(key, ".js")) "text/javascript; charset=utf-8" else
      if (endsWith(key, ".css")) "text/css; charset=utf-8" else if (endsWith(key, ".json")) "application/json; charset=utf-8" else "text/plain; charset=utf-8"
    result <- response(200L, if (req$REQUEST_METHOD == "HEAD") raw() else routes[[key]], type)
    result$headers[["Content-Length"]] <- as.character(length(routes[[key]]))
    result
  }
  server <- httpuv::startServer("127.0.0.1", as.integer(port), list(call = call))
  active <- TRUE
  stop <- function() {if (active) {httpuv::stopServer(server); active <<- FALSE}; invisible(NULL)}
  viewer <- list(url = url, stop = stop, status = snapshot$status$state)
  if (browse) tryCatch(utils::browseURL(url), error = function(e) warning("Open the viewer URL in your browser: ", url, call. = FALSE))
  message("AchillesNext viewer: ", url)
  if (block) {
    on.exit(stop(), add = TRUE)
    while (active) httpuv::service(100)
  }
  invisible(viewer)
}
