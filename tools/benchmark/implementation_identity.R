# Compare actual loaded package bindings with the checkout before measuring.
# An installed R package stores lazy-load databases, not the original source files.
# Hash canonical syntax: serialized language objects can change after execution
# even when their deparsed form is unchanged. Exclude bytecode and install paths.
implementationIdentity <- function(root, installed = asNamespace("AchillesNext")) {
  root <- normalizePath(root, mustWork = TRUE)
  expected <- new.env(parent = baseenv())
  paths <- sort(list.files(file.path(root, "R"), pattern = "[.]R$", full.names = TRUE))
  for (path in paths) sys.source(path, expected, keep.source = FALSE)
  names <- sort(ls(expected, all.names = TRUE))
  actualNames <- setdiff(ls(installed, all.names = TRUE), c(".__NAMESPACE__.", ".__S3MethodsTable__.", ".packageName"))
  if (!setequal(names, actualNames)) stop("Installed R implementation has different bindings; reinstall AchillesNext from this checkout", call. = FALSE)
  fingerprint <- function(value) {
    syntax <- function(x) deparse(x, width.cutoff = 500L,
      control = c("keepInteger", "quoteExpressions", "showAttributes", "keepNA", "S_compatible"))
    payload <- if (is.function(value)) c("function", syntax(formals(value)), "body", syntax(body(value))) else c("constant", syntax(value))
    digest::digest(enc2utf8(paste(payload, collapse = "\n")), algo = "sha256", serialize = FALSE)
  }
  sourceHashes <- stats::setNames(lapply(names, function(n) fingerprint(get(n, expected, inherits = FALSE))), names)
  installedHashes <- stats::setNames(lapply(names, function(n) {
    value <- get(n, installed, inherits = FALSE)
    if (is.function(value) && !identical(environment(value), installed))
      stop("Installed R implementation has a foreign function environment: ", n, call. = FALSE)
    fingerprint(value)
  }), names)
  changed <- names[!vapply(names, function(n) identical(sourceHashes[[n]], installedHashes[[n]]), TRUE)]
  if (length(changed)) stop("Installed R implementation differs from checkout: ", paste(changed, collapse = ", "), "; reinstall AchillesNext", call. = FALSE)
  relative <- c(paste0("R/", basename(paths)), "DESCRIPTION", "NAMESPACE")
  fileHashes <- stats::setNames(lapply(relative, function(p) digest::digest(file = file.path(root, p), algo = "sha256")), relative)
  sourceSql <- file.path(root, "inst/sql/postgresql")
  installedSql <- system.file("sql/postgresql", package = "AchillesNext", mustWork = TRUE)
  sqlNames <- sort(list.files(sourceSql, pattern = "[.]sql$"))
  if (!setequal(sqlNames, list.files(installedSql, pattern = "[.]sql$"))) stop("Installed SQL file set differs from checkout; reinstall AchillesNext", call. = FALSE)
  sqlHash <- function(base) stats::setNames(lapply(sqlNames, function(p) digest::digest(file = file.path(base, p), algo = "sha256")), sqlNames)
  sqlSource <- sqlHash(sourceSql); sqlInstalled <- sqlHash(installedSql)
  if (!identical(sqlSource, sqlInstalled)) stop("Installed SQL differs from checkout; reinstall AchillesNext", call. = FALSE)
  list(method = "UTF-8 canonical deparse of function formals/body and namespace constants with explicit controls, compared in the same R runtime; function environments verified; excludes bytecode/dependency implementations",
    source_files_sha256 = fileHashes, source_bindings_sha256 = sourceHashes,
    installed_bindings_sha256 = installedHashes, installed_sql_sha256 = sqlInstalled)
}
