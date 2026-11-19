# A single owned result-store transaction holds aggregate COPY pages. It opens
# before source execution and permits only temporary staging until source cleanup.
.candidate_copy_workspace <- function(tx,plan,capture,budget,limits,tick,started) {
  assets <- .v2_assets()
  pageRows <- min(128L,limits$fetch_size)
  metrics <- plan$metrics
  .candidate_need(length(metrics)>0L && !anyDuplicated(metrics))
  captured <- list()
  imported <- list()
  verified <- FALSE
  upstream <- NULL
  staged <- 0
  sourceBytes <- 0
  peakStage <- 0
  stageMeasurements <- 0
  canonicalBytes <- 0
  transferPages <- 0
  verificationPages <- 0
  targetReads <- 0
  targetRows <- 0
  targetPeak <- 0
  copySeconds <- 0
  verifySeconds <- 0
  clock <- function() proc.time()[["elapsed"]]
  timeout <- function() as.integer(max(1,min(2147483,ceiling(limits$statement_timeout_ms/1000),
    ceiling(limits$max_elapsed_seconds-(clock()-started)))))
  remaining <- function() {x <- budget$inspect(); x$max_bytes-x$bytes}

  # Each read is separately bounded. The long-lived source and store transports
  # keep their fixed control-query budgets and cannot accumulate one entry per page.
  readPort <- function(canonical=FALSE) {
    readLimits <- limits
    if (canonical) readLimits$max_row_bytes <- 65536L
    .sql_execution_transport(tx$jdbc,readLimits,tick,started)
  }
  measure <- function() {
    size <- readPort()$one(paste0("SELECT (pg_total_relation_size('pg_temp.count_frames')+",
      "pg_total_relation_size(pg_get_serial_sequence('pg_temp.count_frames','seq')))::text"),"copy.stage_bytes","resource")
    .candidate_need(.v2_count(size))
    stageMeasurements <<- stageMeasurements+1
    physical <- as.numeric(size)
    .candidate_need(physical>=staged)
    # Roll back the owned store transaction if allocation exceeds either bound.
    # Record an acquired reservation atomically so cleanup cannot release twice.
    suspendInterrupts({budget$acquire(physical-staged); staged <<- physical})
    peakStage <<- max(peakStage,staged)
    .candidate_need(sourceBytes+staged<=limits$max_stage_bytes,"candidate.stage_limit")
  }
  tx$execute(paste0("CREATE TEMP TABLE count_frames (seq bigint GENERATED ALWAYS AS IDENTITY, ",
    "mid text NOT NULL,key text NOT NULL UNIQUE,doc bytea NOT NULL CHECK(octet_length(doc)<=65536),",
    "input_bytes integer NOT NULL CHECK(input_bytes>0),UNIQUE(mid,seq)) ON COMMIT DROP"))
  measure()
  source_stage <- function(bytes) {
    sourceBytes <<- bytes
    .candidate_need(sourceBytes+staged<=limits$max_stage_bytes,"candidate.stage_limit")
  }
  receive <- function(jdbc,mid,rows,bytes) {
    .candidate_need(!verified && mid %in% metrics && is.null(captured[[mid]]))
    if (is.null(upstream)) upstream <<- jdbc
    start <- clock()
    sql <- plan$query(mid,rows,bytes,limits$max_row_bytes)
    query <- .pg_count_copy_query(mid,sql,FALSE,limits$max_row_bytes,pageRows)
    page <- function(...) {measure(); transferPages <<- transferPages+1}
    frameAllowance <- min(remaining(),budget$inspect()$max_bytes-canonicalBytes)
    info <- .pg_count_copy_pages(jdbc,tx$jdbc,query,mid,rows,bytes,frameAllowance,
      limits$max_row_bytes,timeout(),tick,remaining,page,pageRows)
    copySeconds <<- copySeconds+clock()-start
    .candidate_need(info$rows>=0 && info$rows<=rows && info$bytes<=bytes)
    canonicalBytes <<- canonicalBytes+info$frames
    captured[[mid]] <<- info
    info
  }
  capture_stats <- function() .object(strategy="postgresql_binary_copy",
    metrics=length(captured),pages=transferPages,page_rows=pageRows,canonical_bytes=canonicalBytes,
    source_rows=sum(vapply(captured,function(x)x$rows,0)),
    logical_source_bytes=sum(vapply(captured,function(x)x$bytes,0)),
    receipts=lapply(captured,function(info)info[c("rows","bytes","frames","pages","sha","wire_sha")]),
    client_capture_wall_ms=.sql_execution_ms(copySeconds),
    scope="Client wall time for checked count COPY, sink staging and accounting")
  complete <- function(receipt) {
    .candidate_need(!verified && setequal(names(captured),metrics) && !is.null(upstream) &&
      isTRUE(rJava::.jcall(upstream,"Z","isClosed")) &&
      identical(receipt$cleanup$transaction,"rolled_back") && identical(receipt$cleanup$connection,"disconnected") &&
      identical(receipt$program_sha256,plan$program_sha256))
    verified <<- TRUE
    vapply(captured,function(v)format(v$rows,scientific=FALSE,trim=TRUE),"")
  }
  persist <- function(mid,dataset,assets,ids) {
    .candidate_need(verified && mid %in% metrics && is.null(imported[[mid]]))
    info <- captured[[mid]]
    start <- clock()
    query <- .pg_count_copy_query(mid,NULL,TRUE,limits$max_row_bytes,pageRows)
    check <- .pg_count_copy_pages(tx$jdbc,NULL,query,mid,info$rows,info$bytes,info$frames,
      limits$max_row_bytes,timeout(),tick,function() Inf,
      function(...) {verificationPages <<- verificationPages+1},pageRows)
    verifySeconds <<- verifySeconds+clock()-start
    fields <- c("rows","bytes","frames","sha","wire_sha")
    .candidate_need(all(fields %in% names(info)) && identical(info[fields],check[fields]),"candidate.invalid_capture")
    imported[[mid]] <<- .candidate_copy_import(tx,mid,dataset,assets,ids,tick,limits,info)
  }

  # Non-COPY rows can reference a target held in the temp table. Load only the
  # current page's distinct targets; SQL parameters are validated SHA-256 keys.
  targets <- list()
  replay <- function(mid,visit) {
    dep <- .analysis_dependency(mid,assets)
    if (is.null(dep) || !dep %in% metrics) return(capture$replay(mid,visit))
    .candidate_need(verified && !is.null(imported[[dep]]))
    items <- list()
    flush <- function() {
      if (!length(items)) return(invisible(NULL))
      keys <- unique(unlist(lapply(items,function(row) {
        if (row$state %in% c("unsupported","unavailable")) return(NULL)
        spec <- .analysis_denominator(mid,row,assets,forKey=TRUE)
        if (is.null(spec)) return(NULL)
        .candidate_need(identical(spec$metric_id,dep))
        .v2_row_identity(assets$rows[[dep]],.object(row_kind="counts",dimensions=spec$dimensions))
      }),use.names=FALSE))
      targets <<- list()
      if (length(keys)) {
        .candidate_need(length(keys)<=pageRows && all(grepl("^[0-9a-f]{64}$",keys)))
        sql <- paste0("SELECT convert_from(doc,'UTF8') FROM pg_temp.count_frames WHERE mid=", .store_literal(dep),
          " AND key IN (",paste(vapply(keys,.store_literal,""),collapse=","),")")
        readPort(TRUE)$stream(sql,function(text) {
          raw <- charToRaw(enc2utf8(text))
          .candidate_need(length(raw)<=65536L)
          row <- .nv_json(raw)
          .v2_row(dep,row,assets,expectedBytes=raw)
          key <- row$row_key
          .candidate_need(key %in% keys && is.null(targets[[key]]))
          targets[[key]] <<- c(.object(metric_id=dep),row)
        },"copy.denominators","aggregate",maxRows=length(keys),maxBytes=length(keys)*65536)
        .candidate_need(setequal(keys,names(targets)))
        targetReads <<- targetReads+1; targetRows <<- targetRows+length(keys)
        targetPeak <<- max(targetPeak,length(keys))
      }
      for (row in items) {tick(); visit(row)}
      targets <<- list()
      items <<- list()
      invisible(NULL)
    }
    capture$replay(mid,function(row) {
      items[[length(items)+1L]] <<- row
      if (length(items)>=pageRows) flush()
    })
    flush()
  }
  lookup <- function(mid,key) {
    target <- targets[[key]]
    .candidate_need(!is.null(target) && identical(target$metric_id,mid) && identical(target$row_key,key))
    target
  }
  finish <- function(writer,receipt,ids) {
    .candidate_need(verified && setequal(names(imported),metrics))
    counters <- c("rows","edges","cell_statements","edge_statements","sql_bytes")
    spoolWrites <- writer[counters]
    for (field in counters) {
      for (item in imported) {
        value <- as.numeric(item[[field]])
        .candidate_need(length(value)==1 && is.finite(value) && value>=0 && value==floor(value))
        writer[[field]] <- writer[[field]]+value
      }
    }
    writer$strategy <- "bounded_values_and_postgresql_copy"
    writer$spool_writes <- spoolWrites
    writer$copy_writes <- lapply(counters,function(field)writer[[field]]-spoolWrites[[field]])
    names(writer$copy_writes) <- counters
    writer$copy_max_statement_bytes <- max(vapply(imported,function(x)x$max_statement_bytes,0))
    .candidate_need(writer$rows==as.numeric(receipt$rows))
    release <- .store_uuid(ids$release_id)
    sql <- paste0("SELECT json_build_object('revision',content_revision::text,",
      "'rows',(SELECT count(*)::text FROM ",tx$schema,".achillesnext_aggregate_cell WHERE release_id=",release,"),",
      "'edges',(SELECT count(*)::text FROM ",tx$schema,".achillesnext_denominator_edge WHERE release_id=",release,"),",
      "'datasets',(SELECT count(*)::text FROM ",tx$schema,".achillesnext_dataset WHERE release_id=",release,"))::text FROM ",
      tx$schema,".achillesnext_result_release WHERE state='building' AND release_id=",release)
    actual <- .store_decode(tx$one(sql))
    .candidate_need(identical(actual$rows,receipt$rows) && identical(actual$datasets,"142") &&
      .v2_count(actual$edges) && writer$edges==as.numeric(actual$edges) &&
      identical(actual$revision,.nv_add(actual$datasets,.nv_add(actual$rows,actual$edges))))
    writer
  }
  drop <- function() {
    tx$execute("DROP TABLE pg_temp.count_frames")
    suspendInterrupts({budget$release(staged); staged <<- 0})
  }
  stats <- function() .object(peak_store_stage_bytes=peakStage,verification_pages=verificationPages,
    client_verification_wall_ms=.sql_execution_ms(verifySeconds),stage_size_queries=stageMeasurements,target_queries=targetReads,
    prefetched_target_rows=targetRows,peak_targets_per_page=targetPeak)
  list(metrics=metrics,source_stage=source_stage,receive=receive,complete=complete,
    persist=persist,replay=replay,lookup=lookup,finish=finish,drop=drop,stats=stats,capture_stats=capture_stats)
}


# Local capture cleanup releases only its own reservations. The store shares the
# overall ceiling but retains its reservation until DROP or transaction cleanup.
.candidate_copy_file_budget <- function(parent) {
  bytes <- 0
  files <- 0
  list(
    acquire=function(n,f=0) suspendInterrupts({
      parent$acquire(n,f); bytes <<- bytes+n; files <<- files+f
    }),
    release=function(n,f=0) suspendInterrupts({
      .candidate_need(n<=bytes && f<=files)
      parent$release(n,f); bytes <<- bytes-n; files <<- files-f
    }),
    inspect=function() {
      x <- parent$inspect()
      x$bytes <- bytes; x$files <- files
      x
    })
}
