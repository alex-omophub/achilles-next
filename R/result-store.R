# Dedicated installer transaction: never reuse the source-read-only tracer session.
#' Initialize an empty PostgreSQL aggregate store
#'
#' Creates new results and serving schemas atomically. Existing schemas are refused.
#' This installs storage, not domain computation or an approved publication.
#' @param connectionDetails PostgreSQL DatabaseConnector connection details.
#' @param resultsSchema New schema for restricted aggregate storage.
#' @param servingSchema New schema for approved-page views.
#' @param sourceSchemas Existing CDM/vocabulary schemas, excluded from installation.
#' @export
initializeResultStore <- function(connectionDetails, resultsSchema, servingSchema, sourceSchemas) {
  valid <- function(x) is.character(x) && length(x) == 1L && !is.na(x) &&
    grepl("^[a-z][a-z0-9_]{0,62}$", x) && !grepl("^pg_|^information_schema$|^public$", x)
  if (!valid(resultsSchema) || !valid(servingSchema) || identical(resultsSchema, servingSchema))
    stop("Specify distinct new results and serving schema identifiers", call. = FALSE)
  if (!is.character(sourceSchemas) || !length(sourceSchemas) || anyNA(sourceSchemas) ||
      any(!nzchar(sourceSchemas)) || any(c(resultsSchema, servingSchema) %in% tolower(sourceSchemas)))
    stop("Source schemas must be declared and excluded from store installation", call. = FALSE)
  if (!identical(connectionDetails$dbms, "postgresql")) stop("PostgreSQL is required", call. = FALSE)
  path <- system.file("sql/postgresql/result-store.sql", package = "AchillesNext", mustWork = TRUE)
  sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
  sql <- gsub("__STORE__", paste0('"', resultsSchema, '"'), sql, fixed = TRUE)
  sql <- gsub("__SERVE__", paste0('"', servingSchema, '"'), sql, fixed = TRUE)
  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection), add = TRUE)
  jdbc <- connection@jConnection
  rJava::.jcall(jdbc, "V", "setAutoCommit", FALSE)
  rJava::.jcall(jdbc, "V", "setReadOnly", FALSE)
  committed <- FALSE
  on.exit(if (!committed) try(rJava::.jcall(jdbc, "V", "rollback"), silent = TRUE), add = TRUE, after = FALSE)
  tryCatch({
    statement <- rJava::.jcall(jdbc, "Ljava/sql/Statement;", "createStatement")
    on.exit(rJava::.jcall(statement, "V", "close"), add = TRUE, after = FALSE)
    rJava::.jcall(statement, "V", "setQueryTimeout", 60L)
    rJava::.jcall(statement, "Z", "execute", sql)
    profilePath <- system.file("analysis/core-characterization-v2.json", package = "AchillesNext", mustWork = TRUE)
    bytes <- readBin(profilePath, "raw", n = file.info(profilePath)$size)
    hex <- paste(sprintf("%02x", as.integer(bytes)), collapse = "")
    register <- paste0("WITH input AS (SELECT decode('", hex, "','hex') AS b), parsed AS ",
      "(SELECT b,convert_from(b,'UTF8')::jsonb AS d FROM input) INSERT INTO \"", resultsSchema,
      "\".profile_registry SELECT encode(sha256(b),'hex'),d->>'profile_id',d->>'revision',b,d FROM parsed")
    rJava::.jcall(statement, "Z", "execute", register)
    rJava::.jcall(jdbc, "V", "commit")
    committed <- TRUE
  }, error = function(e) stop("Result store installation failed; transaction rolled back", call. = FALSE))
  invisible(list(storage_version = "2.0.0", results_schema = resultsSchema, serving_schema = servingSchema))
}

.store_control <- function(connectionDetails, resultsSchema, functionName, target, expectedRevision = NULL) {
  if (!is.character(resultsSchema) || length(resultsSchema) != 1L || is.na(resultsSchema) ||
      !grepl("^[a-z][a-z0-9_]{0,62}$", resultsSchema) || grepl("^pg_|^public$|^information_schema$", resultsSchema))
    stop("Invalid results schema", call. = FALSE)
  if (!is.character(target) || length(target) != 1L || is.na(target) ||
      !grepl("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", target))
    stop("A UUID target is required", call. = FALSE)
  if (!identical(connectionDetails$dbms, "postgresql")) stop("PostgreSQL is required", call. = FALSE)
  stopifnot(functionName %in% c("seal_release", "promote_publication"))
  if (!is.null(expectedRevision) && (!is.character(expectedRevision) || length(expectedRevision) != 1L ||
      is.na(expectedRevision) || !grepl("^(0|[1-9][0-9]{0,17})$", expectedRevision)))
    stop("Expected revision must be a canonical integer string of at most 18 digits", call. = FALSE)
  sql <- paste0('SELECT "', resultsSchema, '".', functionName, "('", target, "'::uuid",
    if (is.null(expectedRevision)) "" else paste0(",", expectedRevision, "::bigint"), ")::text")
  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection), add = TRUE)
  jdbc <- connection@jConnection
  rJava::.jcall(jdbc, "V", "setAutoCommit", FALSE)
  rJava::.jcall(jdbc, "V", "setReadOnly", FALSE)
  rJava::.jcall(jdbc, "V", "setTransactionIsolation", 2L)
  committed <- FALSE
  on.exit(if (!committed) try(rJava::.jcall(jdbc, "V", "rollback"), silent = TRUE), add = TRUE, after = FALSE)
  tryCatch({
    statement <- rJava::.jcall(jdbc, "Ljava/sql/Statement;", "createStatement")
    on.exit(rJava::.jcall(statement, "V", "close"), add = TRUE, after = FALSE)
    rJava::.jcall(statement, "V", "setQueryTimeout", 30L)
    result <- rJava::.jcall(statement, "Ljava/sql/ResultSet;", "executeQuery", sql)
    on.exit(rJava::.jcall(result, "V", "close"), add = TRUE, after = FALSE)
    if (!rJava::.jcall(result, "Z", "next")) stop("Missing operation result")
    revision <- rJava::.jcall(result, "S", "getString", 1L)
    rJava::.jcall(jdbc, "V", "commit")
    committed <- TRUE
    revision
  }, error = function(e) {
    if (grepl("Current publication conflict", conditionMessage(e), fixed = TRUE))
      stop("Current publication conflict", call. = FALSE)
    stop("Store operation failed; transaction rolled back", call. = FALSE)
  })
}

#' Seal a complete aggregate dataset inventory
#' @inheritParams initializeResultStore
#' @param releaseId UUID of a building release.
#' @export
sealResultRelease <- function(connectionDetails, resultsSchema, releaseId) {
  .store_control(connectionDetails, resultsSchema, "seal_release", releaseId)
}

#' Select an already validated and approved database publication
#' @inheritParams initializeResultStore
#' @param publicationId UUID of a ready publication.
#' @param expectedRevision Current pointer revision as an exact string; zero for absent.
#' @export
promoteResultPublication <- function(connectionDetails, resultsSchema, publicationId, expectedRevision = "0") {
  .store_control(connectionDetails, resultsSchema, "promote_publication", publicationId, expectedRevision)
}
