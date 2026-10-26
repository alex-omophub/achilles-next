# Render installed, pinned legacy templates; never connects to a database.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 2)
lock <- jsonlite::fromJSON(args[1], simplifyVector = FALSE)
stopifnot(as.character(packageVersion('Achilles')) == lock$achilles_version)
stopifnot(as.character(packageVersion('SqlRender')) == lock$sqlrender_version)
out <- list(versions = list(R = R.version.string, Achilles = as.character(packageVersion('Achilles')),
                           SqlRender = as.character(packageVersion('SqlRender'))), analyses = list())
render <- function(path, ...) {
  raw <- readBin(path, 'raw', n = file.info(path)$size)
  # Hash the original installed bytes in Python, before accepting this output.
  sql <- rawToChar(raw)
  samples <- numeric(7)
  for (i in seq_along(samples)) {
    start <- proc.time()[['elapsed']]
    translated <- SqlRender::translate(SqlRender::render(sql, ...), targetDialect = 'postgresql')
    samples[i] <- (proc.time()[['elapsed']] - start) * 1000
  }
  list(source_hex = paste(sprintf('%02x', as.integer(raw)), collapse = ''),
       statements = as.list(SqlRender::splitSql(translated)),
       render_translate_ms = as.list(samples), first_sample_is_warmup = TRUE)
}
for (id in lock$analysis_ids) {
  path <- system.file(sprintf('sql/sql_server/analyses/%s.sql', id), package = 'Achilles')
  out$analyses[[as.character(id)]] <- render(path, cdmDatabaseSchema = 'pg_temp',
    scratchDatabaseSchema = '#', schemaDelim = '', tempAchillesPrefix = 'bench')
}
out$export <- render(system.file('sql/sql_server/export/measurement/sqlMeasurementValueDistribution.sql', package = 'Achilles'),
                     results_database_schema = 'pg_temp', vocab_database_schema = 'pg_temp')
jsonlite::write_json(out, args[2], auto_unbox = TRUE, pretty = TRUE, digits = NA)
