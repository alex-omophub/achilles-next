# Own transaction boundaries on the already configured PostgreSQL JDBC handle.
# DatabaseConnector 6.3.2's batched query cleanup commits transactions, while
# executeSql also commits non-autocommit connections. Neither can own these reads.
.tracer_session <- function(connection, observer = NULL) {
  if (!inherits(connection, "DatabaseConnectorJdbcConnection")) stop("A PostgreSQL JDBC connection is required", call. = FALSE)
  jdbc <- connection@jConnection
  rJava::.jcall(jdbc, "V", "setAutoCommit", FALSE)
  rJava::.jcall(jdbc, "V", "setReadOnly", TRUE)
  rJava::.jcall(jdbc, "V", "setTransactionIsolation", 4L) # JDBC REPEATABLE_READ
  query <- function(sql) tryCatch({
    statement <- rJava::.jcall(jdbc, "Ljava/sql/Statement;", "createStatement")
    on.exit(rJava::.jcall(statement, "V", "close"), add = TRUE)
    result <- rJava::.jcall(statement, "Ljava/sql/ResultSet;", "executeQuery", sql)
    on.exit(rJava::.jcall(result, "V", "close"), add = TRUE, after = FALSE)
    meta <- rJava::.jcall(result, "Ljava/sql/ResultSetMetaData;", "getMetaData")
    n <- rJava::.jcall(meta, "I", "getColumnCount")
    columns <- replicate(n, character(), simplify = FALSE)
    names(columns) <- vapply(seq_len(n), function(i) toupper(rJava::.jcall(meta, "S", "getColumnLabel", as.integer(i))), "")
    while (rJava::.jcall(result, "Z", "next")) for (i in seq_len(n)) {
      value <- rJava::.jcall(result, "S", "getString", as.integer(i))
      columns[[i]] <- c(columns[[i]], if (is.null(value)) NA_character_ else value)
    }
    as.data.frame(columns, stringsAsFactors = FALSE)
  }, error = function(e) stop("TRACER_QUERY_FAILED: source is unavailable or inaccessible", call. = FALSE))
  execute <- function(sql) tryCatch({
    statement <- rJava::.jcall(jdbc, "Ljava/sql/Statement;", "createStatement")
    on.exit(rJava::.jcall(statement, "V", "close"), add = TRUE)
    invisible(rJava::.jcall(statement, "Z", "execute", sql))
  }, error = function(e) stop("TRACER_TRANSACTION_FAILED", call. = FALSE))
  measured <- function(kind, sql, work) {
    if (is.null(observer)) return(work())
    started <- proc.time()[["elapsed"]]
    value <- tryCatch(work(), error = function(e) e)
    observer(.object(kind = kind, sql_sha256 = .hash(sql), duration_ms = .run_ms(started),
      state = if (inherits(value, "error")) "failed" else "succeeded", query_id = NULL,
      query_id_reason = "PostgreSQL JDBC does not expose a warehouse query identifier"))
    if (inherits(value, "error")) stop(value)
    value
  }
  list(query = function(sql) measured("query", sql, function() query(sql)),
    execute = function(sql) measured("execute", sql, function() execute(sql)),
    rollback = function() rJava::.jcall(jdbc, "V", "rollback"))
}
