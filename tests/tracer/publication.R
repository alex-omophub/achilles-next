# End-to-end publication regressions, using only marked synthetic PostgreSQL.
library(AchillesNext)
source("tests/tracer/credential-guard.R")
main <- function() {
  a <- commandArgs(TRUE); if (length(a) != 2L) stop("Use publication.R <fixture-config.R> <new-evidence-dir>")
  e <- new.env(parent = globalenv()); sys.source(a[1], e)
  if (!dir.create(a[2], mode = "0700")) stop("Evidence directory must be new")
  root <- normalizePath(a[2])
  read <- function(path) jsonlite::fromJSON(path, simplifyVector = FALSE)
  fails <- function(work, text) stopifnot(grepl(text, tryCatch({work(); "accepted"}, error = conditionMessage), fixed = TRUE))
  run <- function(name, cfg = e$config, strategy = "reference") {
    p <- file.path(root, name)
    do.call(planMeasurementRun, c(list(runDir = p, numericStrategy = strategy), cfg[setdiff(names(cfg), "connectionDetails")]))
    r <- executeMeasurementRun(p, cfg$connectionDetails)
    stopifnot(r$state$status == "succeeded", length(r$state$outputs) == 15L,
      all(vapply(r$state$outputs, function(o) o$status == "succeeded", TRUE)))
    p
  }
  p <- run("reference")
  store <- file.path(root, "restricted"); dist <- file.path(root, "distributable")
  release <- publishMeasurementRun(p, store, "local-review-1")
  stopifnot(identical(currentMeasurementBundle(store), release), length(list.files(release, recursive = TRUE)) == 17L)
  first <- readBin(file.path(store, "current.json"), "raw", n = 1024*1024)
  nested <- file.path(p, "staging/bundle/rejected-store")
  fails(function() publishMeasurementRun(p, nested, "nested"), "outside the run directory")
  stopifnot(!file.exists(nested))
  unchanged <- function() stopifnot(identical(readBin(file.path(store, "current.json"), "raw", n = 1024*1024), first), identical(currentMeasurementBundle(store), release))
  m <- read(file.path(release, "manifest.json"))
  stopifnot(m$contract_version == "1.1.0", m$publication == "complete", m$eligible_for_current_pointer, m$disclosure$applied,
    m$source$snapshot$state == "unknown", !m$reproducibility$consistent_snapshot)
  caps <- read(file.path(release, "results/source.capabilities.json"))
  probes <- AchillesNext:::.publication_profile()$prerequisite_probes
  stopifnot(length(caps$rows) == length(probes), all(vapply(seq_along(probes), function(i) !probes[[i]]$required || caps$rows[[i]]$values$availability == "available", TRUE)))
  timing <- read(file.path(release, "results/execution.timing.json"))
  stopifnot(length(timing$rows) == 60L, any(vapply(timing$rows, function(r) r$values$availability == "measured", TRUE)),
    any(vapply(timing$rows, function(r) r$values$availability == "unavailable" && is.null(r$values$duration_ms), TRUE)))
  fails(function() publishMeasurementRun(p, store, "local-review-1"), "Release already exists"); unchanged()
  fails(function() publishMeasurementRun(p, store, "denied", institutionalPolicy = function(candidate) FALSE), "did not approve"); unchanged()
  fails(function() publishMeasurementRun(p, store, "error", institutionalPolicy = function(candidate) stop("secret sentinel")), "did not approve"); unchanged()
  fails(function() publishMeasurementRun(p, store, "mixed", outputScope = "distributable"), "scope mismatch"); unchanged()
  lock <- file.path(store, ".publication-lock"); dir.create(lock)
  fails(function() publishMeasurementRun(p, store, "locked"), "store is locked"); unlink(lock, recursive = TRUE); unchanged()
  shared <- publishMeasurementRun(p, dist, "synthetic-review-1", "distributable", institutionalPolicy = function(candidate) {
    stopifnot(candidate$manifest$request$output_scope == "distributable",
      all(vapply(candidate$manifest$outputs, function(o) o$metric_id %in% c("source.passport", "person.count", "execution.output_status") || o$state == "suppressed", TRUE)), grepl("^[0-9a-f]{64}$", candidate$content_sha256)); TRUE
  })
  stopifnot(identical(currentMeasurementBundle(dist), shared))
  d <- read(file.path(shared, "manifest.json"))
  allowed <- c("source.passport", "person.count", "execution.output_status")
  stopifnot(d$request$output_scope == "distributable", d$source$source_id == "fixture:synthetic",
    all(vapply(d$outputs, function(o) o$metric_id %in% allowed || o$state == "suppressed", TRUE)),
    length(read(file.path(shared, "terminology.json"))$concepts) == 0L)
  for (o in d$outputs) if (!o$metric_id %in% allowed) stopifnot(is.null(read(file.path(shared, o$path))$rows))
  stopifnot(length(list.files(shared, recursive = TRUE, all.files = TRUE)) == 17L)
  # Analysis failure must never move the last complete release.
  cfg <- e$config; cfg$cdmSchema <- "cdm_tiny_absent_55"; bad <- file.path(root, "failed")
  do.call(planMeasurementRun, c(list(runDir = bad), cfg[setdiff(names(cfg), "connectionDetails")]))
  stopifnot(executeMeasurementRun(bad, cfg$connectionDetails)$state$status == "failed")
  fails(function() publishMeasurementRun(bad, store, "failed"), "successfully completed"); unchanged()
  # Validate mutations even after integrity metadata is recomputed: schema and
  # semantics, not checksums alone, must reject bad values and missing outputs.
  original <- AchillesNext:::.publication_read(release)
  corrupt <- function(name, mutate) {
    path <- file.path(root, name); dir.create(path); dir.create(file.path(path, "results"))
    b <- mutate(original); AchillesNext:::.publication_write(b, path)
    fails(function() AchillesNext:::.publication_validate(path), "validation failed"); unchanged()
  }
  corrupt("unsafe-number", function(b) {b$documents[["person.count"]]$rows[[1]]$values$count <- 9007199254740992; b})
  corrupt("malformed-decimal", function(b) {b$documents[["measurement.numeric_summary"]]$rows[[1]]$values$p50 <- "NaN"; b})
  corrupt("missing-output", function(b) {b$manifest$outputs <- b$manifest$outputs[-1]; b})
  corrupt("failure-as-complete", function(b) {b$documents[["measurement.numeric_summary"]]$state <- "failed"; b$documents[["measurement.numeric_summary"]]$reason <- "Injected failure"; b$documents[["measurement.numeric_summary"]]$rows <- NULL; b})
  corrupt("scope-leak", function(b) {b$manifest$request$output_scope <- "distributable"; b$manifest$request_sha256 <- AchillesNext:::.hash(AchillesNext:::.json(b$manifest$request)); b})
  extra <- file.path(root, "extra-file"); dir.create(extra); dir.create(file.path(extra, "results")); AchillesNext:::.publication_write(original, extra)
  writeLines("private sentinel", file.path(extra, "credentials.txt"))
  fails(function() AchillesNext:::.publication_validate(extra), "validation failed"); unchanged()
  # A valid staging manifest is pinned to the successful execution; changes
  # cannot be published merely by rehashing its partitions.
  staging <- file.path(p, "staging/bundle/manifest.json"); raw <- readBin(staging, "raw", n = 1024*1024)
  changed <- read(staging); changed$created_at <- "2020-01-01T00:00:00.000Z"; AchillesNext:::.write_json(changed, staging)
  fails(function() publishMeasurementRun(p, store, "changed"), "changed after execution"); writeBin(raw, staging); unchanged()
  # Inject failed local renames at the commit seam: both before release commit
  # and between release commit and pointer switch must preserve current.
  candidate <- function(name) {
    path <- file.path(store, name); dir.create(path); dir.create(file.path(path, "results")); AchillesNext:::.publication_write(original, path); path
  }
  temp <- candidate(".candidate-before")
  fails(function() AchillesNext:::.publication_commit(temp, store, paste0("bundle-", strrep("a", 64)), rename = function(...) FALSE), "Cannot finalize"); unlink(temp, recursive = TRUE); unchanged()
  temp <- candidate(".candidate-after")
  fails(function() AchillesNext:::.publication_commit(temp, store, paste0("bundle-", strrep("b", 64)), rename = function(from, to) {
    if (basename(to) == "current.json") FALSE else file.rename(from, to)
  }), "prior current is preserved"); unchanged()
  stopifnot(!length(list.files(store, pattern = "^[.]current-", all.files = TRUE)))
  # A second successful run replaces the pointer while retaining the prior release.
  weighted <- run("weighted", strategy = "weighted")
  second <- publishMeasurementRun(weighted, store, "weighted-review")
  stopifnot(identical(currentMeasurementBundle(store), second), dir.exists(release))
  legacy <- e$config; legacy$cdmSchema <- "cdm_tiny_a_53"; legacy$declaredCdmVersion <- "5.3"
  legacyRun <- run("cdm53", legacy)
  publishMeasurementRun(legacyRun, file.path(root, "legacy-store"), "legacy-review")
  # Known empty source/population and true zero remain exact typed states after
  # publication, not failure or suppression. These fixtures have no events.
  owner <- DatabaseConnector::connect(e$fixtureConnection("owner")); on.exit(DatabaseConnector::disconnect(owner), add = TRUE)
  execute <- function(sql) DatabaseConnector::executeSql(owner, sql, progressBar = FALSE, reportOverallTime = FALSE)
  guard <- DatabaseConnector::querySql(owner, "SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB == "achilles_next_fixtures", guard$MARKER == "AchillesNext synthetic fixture sandbox v1")
  schema <- paste0("cdm_tiny_publication_", Sys.getpid(), "_55")
  execute(paste0('CREATE SCHEMA "', schema, '"; COMMENT ON SCHEMA "', schema, '" IS \'AchillesNext synthetic fixture sandbox v1: ', schema, "'"))
  on.exit(execute(paste0('DROP SCHEMA "', schema, '" CASCADE')), add = TRUE, after = FALSE)
  for (table in c("person", "observation_period", "measurement", "concept", "cdm_source"))
    execute(paste0('CREATE TABLE "', schema, '".', table, ' AS SELECT * FROM "', e$config$cdmSchema, '".', table, if (table %in% c("person", "observation_period", "measurement")) " WHERE FALSE" else ""))
  execute(paste0('GRANT USAGE ON SCHEMA "', schema, '" TO achilles_next_runner; GRANT SELECT ON ALL TABLES IN SCHEMA "', schema, '" TO achilles_next_runner'))
  cfg <- e$config; cfg$cdmSchema <- schema
  for (name in c("empty-source", "empty-population")) {
    if (name == "empty-population") execute(paste0('INSERT INTO "', schema, '".person SELECT * FROM "', e$config$cdmSchema, '".person'))
    r <- run(name, cfg); path <- publishMeasurementRun(r, file.path(root, paste0(name, "-store")), "empty-review")
    doc <- read(file.path(path, "results/measurement.record_count.json"))
    stopifnot(doc$state == if (name == "empty-source") "empty_source" else "empty_population", all(vapply(doc$rows, function(r) r$values$count == "0", TRUE)))
  }
  paths <- list.files(root, pattern = "[.]json$", recursive = TRUE, full.names = TRUE)
  text <- paste(vapply(paths, function(p) paste(readLines(p, warn = FALSE), collapse = ""), ""), collapse = "")
  assertNoCredentials(text, c(e$config$connectionDetails$password(), e$fixtureConnection("owner")$password()))
  cat("PASS: complete 15-output reference/weighted/CDM5.3 bundles; scoped stores; approval deny/error; empty/zero/suppressed states; corrupt/missing/precision rejection; extra-file rejection; analysis and rename failures preserve current; credentials absent\n")
}
main()
