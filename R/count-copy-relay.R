# rJava returns immediately for void methods. A Java exception from a write,
# rollback or close would otherwise be reported on the next, unrelated call.
.pg_count_jvoid <- function(object, method, ...) {
  rJava::.jcall(object, "V", method, ...)
  rJava::.jcheck()
  invisible(NULL)
}

.pg_count_page_rows <- function(pageRows) {
  .candidate_need(is.numeric(pageRows) && length(pageRows) == 1L &&
    is.finite(pageRows) && pageRows >= 1L && pageRows <= 128L && pageRows == floor(pageRows))
}

# rJava retains the original Java exception on the R condition. Query
# cancellation is identified by its SQLSTATE regardless of the server locale.
.pg_count_cancelled_query <- function(error) {
  if (!inherits(error, "SQLException") || is.null(error$jobj)) return(FALSE)
  tryCatch(identical(rJava::.jcall(rJava::.jcast(error$jobj, "java/sql/SQLException"),
                                  "S", "getSQLState"), "57014"), error = function(e) FALSE)
}

.pg_count_copy_query <- function(mid, sql, verify, maxRow, pageRows = 128L) {
  .pg_count_page_rows(pageRows)
  .candidate_need(.string(mid) && grepl("^[a-z0-9_.]+$", mid) && nchar(mid, type = "bytes") <= 128L &&
    is.numeric(maxRow) && length(maxRow) == 1L && is.finite(maxRow) &&
    maxRow >= 1L && maxRow <= 1024^2 && maxRow == floor(maxRow))
  if (verify) {
    input <- paste0("SELECT key,doc,input_bytes n,seq AS ord FROM pg_temp.count_frames WHERE mid=", .store_literal(mid))
  } else {
    input <- paste0("SELECT q.*,row_number() OVER () AS ord FROM (", sql, ") q(key,doc,n)")
  }
  path <- system.file("sql/postgresql/count-copy-pages.sql", package = "AchillesNext", mustWork = TRUE)
  template <- paste(readLines(path, warn = FALSE), collapse = "\n")
  template <- gsub("__PAGE_ROWS__", as.character(as.integer(pageRows)), template, fixed = TRUE)
  template <- gsub("__MAX_ROW__", as.character(as.integer(maxRow)), template, fixed = TRUE)
  template <- gsub("__SOURCE__", if (verify) "false" else "true", template, fixed = TRUE)
  template <- gsub("__MID__", mid, template, fixed = TRUE)
  paste0("/* AchillesNext copy.", mid, if (verify) ".verify" else ".capture", " */ COPY (", sub("__INPUT__", input, template, fixed = TRUE), ") TO STDOUT WITH (FORMAT binary)")
}

# Bound PostgreSQL execution for COPY, which runs outside a JDBC Statement.
# Restore the prior setting on success. The owner rolls back and closes both
# connections on failure.
.pg_count_copy_timeout <- function(connection, seconds) {
  j <- rJava::.jcall
  statement <- function(work) {
    cursor <- j(connection, "Ljava/sql/Statement;", "createStatement")
    on.exit(.pg_count_jvoid(cursor, "close"))
    work(cursor)
  }
  original <- statement(function(cursor) {
    result <- j(cursor, "Ljava/sql/ResultSet;", "executeQuery",
                "SELECT setting::int FROM pg_settings WHERE name='statement_timeout'")
    on.exit(.pg_count_jvoid(result, "close"))
    .candidate_need(j(result, "Z", "next"))
    j(result, "I", "getInt", 1L)
  })
  set <- function(ms) statement(function(cursor) j(cursor, "Z", "execute",
    paste("SET LOCAL statement_timeout=", as.integer(ms))))
  ceiling <- min(.Machine$integer.max, as.double(seconds) * 1000)
  set(if (original > 0L) min(original, ceiling) else ceiling)
  function() set(original)
}

# Network timeout bounds an individual JDBC socket read, including cleanup.
# Preserve a shorter operator limit and restore it on a successful transfer.
.pg_count_copy_network <- function(connection, seconds) {
  j <- rJava::.jcall
  original <- j(connection, "I", "getNetworkTimeout")
  ms <- min(.Machine$integer.max, max(1, as.double(seconds) * 1000))
  if (original > 0L) ms <- min(original, ms)
  executor <- rJava::.jcast(j("java/util/concurrent/ForkJoinPool",
    "Ljava/util/concurrent/ForkJoinPool;", "commonPool"), "java/util/concurrent/Executor")
  set <- function(n) .pg_count_jvoid(connection, "setNetworkTimeout", executor, as.integer(n))
  set(ms)
  function() set(original)
}

# A failed COPY drain leaves the handle unsafe for another SQL request.
# Abort the client's owned physical connection without waiting on its COPY
# protocol lock. Closing the socket does not acknowledge a SQL rollback.
.pg_count_abort_owned <- function(connection) {
  j <- rJava::.jcall
  executor <- j("java/util/concurrent/Executors", "Ljava/util/concurrent/ExecutorService;",
                "newSingleThreadExecutor")
  on.exit(.pg_count_jvoid(executor, "shutdown"))
  .pg_count_jvoid(connection, "abort", rJava::.jcast(executor, "java/util/concurrent/Executor"))
  .pg_count_jvoid(executor, "shutdown")
  unit <- rJava::.jfield("java/util/concurrent/TimeUnit", "Ljava/util/concurrent/TimeUnit;", "MILLISECONDS")
  .candidate_need(j(executor, "Z", "awaitTermination", rJava::.jlong(2000), unit) &&
    j(connection, "Z", "isClosed"), "candidate.cleanup_failed")
}

.pg_count_copy_pages <- function(src, sink, query, mid, maxRows, maxBytes, maxFrames,
                                 maxRow, timeout, tick, remaining, afterPage, pageRows = 128L) {
  .pg_count_page_rows(pageRows)
  j <- rJava::.jcall
  pg <- function(x) rJava::.jcast(x, "org/postgresql/PGConnection")
  jdbcClass <- j(src, "Ljava/lang/Class;", "getClass")
  loader <- j(jdbcClass, "Ljava/lang/ClassLoader;", "getClassLoader")
  driverObject <- function(type, ...) rJava::.jnew(type, ..., class.loader = loader)
  copyOut <- NULL
  sourceStream <- NULL
  sinkStream <- NULL
  completed <- FALSE

  cleanup <- function() {
    clean <- TRUE
    attempt <- function(work) tryCatch({work(); TRUE}, error = function(e) {
      clean <<- FALSE
      FALSE
    })
    if (!is.null(sinkStream)) {
      attempt(function() .pg_count_copy_network(sink, 2))
      cancelled <- attempt(function() if (j(sinkStream, "Z", "isActive")) .pg_count_jvoid(sinkStream, "cancelCopy"))
      if (!cancelled) attempt(function() .pg_count_abort_owned(sink))
      if (!attempt(function() .pg_count_jvoid(sinkStream, "close"))) attempt(function() .pg_count_abort_owned(sink))
    }
    if (!is.null(copyOut)) {
      drained <- attempt(function() {
        if (!j(copyOut, "Z", "isActive")) return(invisible(NULL))
        # On JDBC 42.2.18 cancelCopy() on COPY OUT can unlock the connection
        # before ReadyForQuery is consumed. Cancel the backend query, then
        # poll the underlying CopyOut (the stream wrapper ignores FALSE).
        .pg_count_copy_network(src, 2)
        .pg_count_jvoid(pg(src), "cancelQuery")
        deadline <- proc.time()[["elapsed"]] + 5
        bytesRead <- 0
        while (j(copyOut, "Z", "isActive")) {
          .candidate_need(proc.time()[["elapsed"]] <= deadline && bytesRead <= 8 * 1024^2,
                          "candidate.cleanup_failed")
          packet <- tryCatch(j(copyOut, "[B", "readFromCopy", FALSE), error = function(e) {
            if (!.pg_count_cancelled_query(e)) stop(e)
            NULL
          })
          if (length(packet)) bytesRead <- bytesRead + length(packet) else Sys.sleep(0.005)
        }
      })
      if (!drained) attempt(function() .pg_count_abort_owned(src))
      if (!is.null(sourceStream) && !attempt(function() .pg_count_jvoid(sourceStream, "close"))) {
        attempt(function() .pg_count_abort_owned(src))
      }
    }
    if (completed) {
      attempt(restoreSource)
      attempt(restoreSourceNetwork)
      if (!is.null(sink)) {
        attempt(restoreSink)
        attempt(restoreSinkNetwork)
      }
    }
    if (!clean) .candidate_error("candidate.cleanup_failed")
  }
  on.exit(suspendInterrupts(cleanup()))
  restoreSourceNetwork <- .pg_count_copy_network(src, timeout)
  restoreSource <- .pg_count_copy_timeout(src, timeout)
  if (!is.null(sink)) {
    restoreSinkNetwork <- .pg_count_copy_network(sink, timeout)
    restoreSink <- .pg_count_copy_timeout(sink, timeout)
  }
  manager <- j(pg(src), "Lorg/postgresql/copy/CopyManager;", "getCopyAPI")
  copyOut <- j(manager, "Lorg/postgresql/copy/CopyOut;", "copyOut", query)
  sourceStream <- driverObject("org/postgresql/copy/PGCopyInputStream", copyOut)
  input <- rJava::.jnew("java/io/DataInputStream", rJava::.jcast(sourceStream, "java/io/InputStream"))
  bufferBytes <- 524288L
  buffer <- rJava::.jarray(raw(bufferBytes))
  view <- j("java/nio/ByteBuffer", "Ljava/nio/ByteBuffer;", "wrap", buffer)
  # readFully blocks inside JDBC; the configured socket-read timeout and
  # server statement timeout apply in between the page-level callbacks.
  readAt <- function(offset, size) .pg_count_jvoid(input, "readFully", buffer, as.integer(offset), as.integer(size))

  # PostgreSQL binary COPY has a 19-byte header (signature, flags, extension
  # length) and an int16 -1 trailer. The sole outer column is a bytea page.
  header <- c(charToRaw("PGCOPY\n"), as.raw(c(255,13,10,0)), raw(8L))
  javaHeader <- rJava::.jarray(header)
  trailer <- rJava::.jarray(as.raw(c(255L,255L)))
  readAt(0L, length(header))
  .candidate_need(identical(j("java/util/Arrays", "[B", "copyOfRange", buffer, 0L, 19L), header))
  newHash <- function() j("java/security/MessageDigest", "Ljava/security/MessageDigest;", "getInstance", "SHA-256")
  hashText <- function(value) paste(as.character(j(value, "[B", "digest")), collapse = "")
  documents <- newHash()
  nativeTuples <- newHash()
  # Each inner tuple contains int16 nfields, int32 length + metric, int32
  # length + 64-byte key, int32 document length, document, int32 length +
  # int32 input charge. The document starts 78 + metricBytes into the tuple.
  metricBytes <- nchar(mid, type = "bytes")
  documentOffset <- 78L + metricBytes
  rows <- bytes <- frames <- 0
  pages <- 0L
  repeat {
    tick()
    readAt(0L, 2L)
    fields <- j(view, "T", "getShort", 0L)
    if (fields == -1L) {
      .candidate_need(j(input, "I", "read") == -1L)
      break
    }
    .candidate_need(fields == 1L)
    readAt(2L, 4L)
    body <- j(view, "I", "getInt", 2L)
    # Six outer framing bytes precede a 16-byte page header: logical rows
    # (int32), original aggregate bytes (int64), canonical frame bytes (int32).
    if (body == 4L) {
      readAt(6L, 4L)
      status <- j(view, "I", "getInt", 6L)
      if (!is.null(sink)) {
        if (status == -1L) .sql_execution_error("execution.row_limit")
        if (status == -2L) .sql_execution_error("execution.byte_limit")
        if (status == -3L) .sql_execution_error("execution.row_byte_limit")
      }
      .candidate_error("candidate.invalid_capture")
    }
    .candidate_need(body >= 16L && body <= bufferBytes - 6L)
    readAt(6L, body)
    count <- j(view, "I", "getInt", 6L)
    inputBytes <- j(view, "J", "getLong", 10L)
    frameBytes <- j(view, "I", "getInt", 18L)
    .candidate_need(count >= 1L && count <= pageRows && rows + count <= maxRows &&
      inputBytes >= count && inputBytes <= count * as.double(maxRow) && bytes + inputBytes <= maxBytes &&
      frameBytes >= count && frameBytes <= count * 65536)
    if (frameBytes > remaining() || frames + frameBytes > maxFrames) {
      if (is.null(sink)) .candidate_error("candidate.invalid_capture")
      .v2_scratch_error("byte_limit")
    }
    # Length directory: one int32 per canonical document. The first tuple
    # follows the directory; bounds are checked before accessing its fields.
    start <- 22L + count * 4L
    .candidate_need(start <= 6L + body)
    position <- start
    seenFrames <- seenBytes <- 0
    for (index in seq_len(count)) {
      size <- j(view, "I", "getInt", 22L + (index - 1L) * 4L)
      offset <- position + documentOffset
      .candidate_need(size >= 1L && size <= 65536L && offset + size + 8L <= 6L + body &&
        j(view, "T", "getShort", position) == 4L && j(view, "I", "getInt", position + 2L) == metricBytes &&
        j(view, "I", "getInt", position + 6L + metricBytes) == 64L &&
        j(view, "I", "getInt", offset - 4L) == size && j(view, "I", "getInt", offset + size) == 4L)
      charge <- j(view, "I", "getInt", offset + size + 4L)
      .candidate_need(charge >= 1L && charge <= maxRow)
      .pg_count_jvoid(documents, "update", buffer, offset, size)
      seenFrames <- seenFrames + size
      seenBytes <- seenBytes + charge
      position <- offset + size + 8L
    }
    .candidate_need(position == 6L + body && seenFrames == frameBytes && seenBytes == inputBytes)
    # Document digest matches scalar capture. The second digest also binds
    # each key, metric and original input charge, in source order.
    .pg_count_jvoid(nativeTuples, "update", buffer, start, position - start)
    if (!is.null(sink)) {
      sinkStream <- driverObject("org/postgresql/copy/PGCopyOutputStream", pg(sink),
        "COPY pg_temp.count_frames(mid,key,doc,input_bytes) FROM STDIN WITH (FORMAT binary)", 32768L)
      .pg_count_jvoid(sinkStream, "writeToCopy", javaHeader, 0L, 19L)
      .pg_count_jvoid(sinkStream, "writeToCopy", buffer, start, position - start)
      .pg_count_jvoid(sinkStream, "writeToCopy", trailer, 0L, 2L)
      .candidate_need(j(sinkStream, "J", "endCopy") == count)
      .pg_count_jvoid(sinkStream, "close")
      sinkStream <- NULL
    }
    rows <- rows + count
    bytes <- bytes + inputBytes
    frames <- frames + frameBytes
    pages <- pages + 1L
    afterPage(rows, bytes, frames)
    tick()
  }
  completed <- TRUE
  list(rows = rows, bytes = bytes, frames = frames, sha = hashText(documents),
       wire_sha = hashText(nativeTuples), pages = pages)
}
