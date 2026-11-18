# A checked SQL program is reconstructed, never trusted because it has a digest.
.sql_execution_error <- function(code) {
  stop(structure(list(message=paste0("Characterization SQL execution failed [",code,"]"),
    call=NULL,reason_code=code),class=c("AchillesSqlExecutionFailure","error","condition")))
}
.sql_execution_need <- function(ok,code) {
  if(!isTRUE(ok)).sql_execution_error(code)
  invisible(TRUE)
}
.sql_execution_ms <- function(seconds) format(floor(max(0,seconds)*1000+0.5),scientific=FALSE,trim=TRUE)
.sql_execution_program <- function(program) {
  tryCatch({
    .nv_need(.nv_object(program)&&as.numeric(utils::object.size(program))<=8*1024^2)
    d<-program$declarations;s<-program$batch$source
    .nv_need(.nv_object(d)&&.nv_object(s)&&is.list(d$columns)&&length(d$columns)>0L&&length(d$columns)<=4096L)
    columns<-do.call(rbind,lapply(d$columns,function(x) {
      .nv_need(.nv_object(x)&&setequal(names(x),c("table","column","type","readable")))
      .nv_need(all(vapply(x[c("table","column","type")],.string,TRUE))&&is.logical(x$readable)&&length(x$readable)==1L&&!is.na(x$readable))
      as.data.frame(x,stringsAsFactors=FALSE)
    }))
    expected<-renderCharacterizationSql(s$cdm_schema,s$source_id,s$declared_cdm_version,columns,
      numericStrategy=d$numeric_strategy,dialect=program$dialect,stagePrefix=d$stage_prefix)
    .nv_need(identical(.json(program),.json(expected)))
    expected
  },error=function(e).sql_execution_error("execution.invalid_program"))
}
.sql_execution_limits <- function(maxStageBytes,maxAggregateRows,maxAggregateBytes,maxRowBytes,fetchSize,statementTimeoutMs,maxElapsedSeconds,visit,check) {
  number<-function(x,lo,hi,integer=TRUE)is.numeric(x)&&!is.complex(x)&&length(x)==1L&&!is.na(x)&&is.finite(x)&&x>=lo&&x<=hi&&(!integer||x==floor(x))
  .sql_execution_need(number(maxStageBytes,0,2^53)&&number(maxAggregateRows,0,.Machine$integer.max)&&
    number(maxAggregateBytes,0,2^53)&&number(maxRowBytes,1,1024^2)&&number(fetchSize,1,1024)&&
    number(statementTimeoutMs,1,2147483647)&&number(maxElapsedSeconds,.001,604800,FALSE)&&
    is.function(visit)&&(is.null(check)||is.function(check)),"execution.invalid_limits")
  .object(max_stage_bytes=maxStageBytes,max_aggregate_rows=maxAggregateRows,max_aggregate_bytes=maxAggregateBytes,
    max_row_bytes=as.integer(maxRowBytes),fetch_size=as.integer(fetchSize),statement_timeout_ms=as.integer(statementTimeoutMs),
    max_elapsed_seconds=maxElapsedSeconds)
}

#' Execute a checked complete PostgreSQL SQL program through a bounded callback
#' @param connectionDetails PostgreSQL DatabaseConnector connection details.
#' @param program Current unmodified output of renderCharacterizationSql().
#' @param visit Function(metricId,row) consuming restricted aggregate intermediates.
#' @param maxStageBytes Owned temporary relation/index bytes, checked after allocation.
#' @param maxAggregateRows Total output rows, including metadata.
#' @param maxAggregateBytes Total UTF-8 output JSON payload bytes.
#' @param maxRowBytes Maximum UTF-8 payload bytes per fetched row.
#' @param fetchSize JDBC cursor fetch rows.
#' @param statementTimeoutMs PostgreSQL statement timeout in milliseconds.
#' @param maxElapsedSeconds Cooperative whole-call elapsed deadline.
#' @param check Optional cancellation check; FALSE, error or interrupt cancels.
#' @return A completed receipt, not a candidate, wire bundle or publication.
#' @export
executeCharacterizationSql <- function(connectionDetails,program,visit,maxStageBytes=64*1024^2,
  maxAggregateRows=1000000L,maxAggregateBytes=256*1024^2,maxRowBytes=131072L,fetchSize=128L,
  statementTimeoutMs=30000L,maxElapsedSeconds=3600,check=NULL) {
  clock<-proc.time();wall<-function()proc.time()[["elapsed"]]
  startedClock<-wall();program<-.sql_execution_program(program)
  limits<-.sql_execution_limits(maxStageBytes,maxAggregateRows,maxAggregateBytes,maxRowBytes,fetchSize,
    statementTimeoutMs,maxElapsedSeconds,visit,check)
  .sql_execution_need(inherits(connectionDetails,"ConnectionDetails")&&identical(connectionDetails$dbms,"postgresql"),"execution.invalid_limits")
  validationSeconds<-wall()-startedClock
  tick<-function() {
    .sql_execution_need(wall()-startedClock<=limits$max_elapsed_seconds,"execution.elapsed_limit")
    if(!is.null(check)) {
      value<-tryCatch(check(),error=function(e).sql_execution_error("execution.cancelled"),
        interrupt=function(e).sql_execution_error("execution.cancelled"))
      .sql_execution_need(!identical(value,FALSE),"execution.cancelled")
    }
    invisible(TRUE)
  }
  connection<-NULL;jdbc<-NULL;cleaned<-FALSE;rollbackConfirmed<-FALSE;disconnectConfirmed<-FALSE
  cleanup<-function() {
    if(cleaned)return(TRUE)
    if(!rollbackConfirmed)rollbackConfirmed<<-is.null(jdbc)||isTRUE(tryCatch({
      rJava::.jcall(jdbc,"V","rollback");TRUE
    },error=function(e)FALSE,interrupt=function(e)FALSE))
    # Attempt disconnect even when rollback failed. Retain each unconfirmed
    # action for on.exit retry; network failure is never a rollback guarantee.
    if(!disconnectConfirmed)disconnectConfirmed<<-is.null(connection)||isTRUE(tryCatch({
      DatabaseConnector::disconnect(connection);TRUE
    },error=function(e)FALSE,interrupt=function(e)FALSE))
    cleaned<<-rollbackConfirmed&&disconnectConfirmed;cleaned
  }
  on.exit(if(!cleaned)cleanup(),add=TRUE)
  work<-function() {
    tick();started<-.stamp();generationClock<-wall()
    connection<<-tryCatch(DatabaseConnector::connect(connectionDetails),error=function(e).sql_execution_error("execution.connection_failed"))
    jdbc<<-connection@jConnection
    rJava::.jcall(jdbc,"V","setAutoCommit",FALSE)
    rJava::.jcall(jdbc,"V","setReadOnly",FALSE)
    rJava::.jcall(jdbc,"V","setTransactionIsolation",4L)
    transport<-.sql_execution_transport(jdbc,limits,tick,startedClock)
    transport$execute(paste0("SET LOCAL statement_timeout=",limits$statement_timeout_ms),"executor.statement_timeout","control")
    transport$execute("SET LOCAL lock_timeout=2000","executor.lock_timeout","control")
    prefix<-paste0(program$declarations$stage_prefix,"_")
    stagePeak<-"0";stageStarts<-list();stageTimings<-list()
    stageBudget<-function() {
      bytes<-transport$one(paste0("SELECT COALESCE(sum(pg_total_relation_size(c.oid)),0)::text FROM pg_class c ",
        "WHERE c.relnamespace=pg_my_temp_schema() AND c.relkind IN ('r','p','m') AND left(c.relname,",nchar(prefix),")=",.store_literal(prefix)),
        "executor.stage_bytes","resource")
      .sql_execution_need(.v2_count(bytes),"execution.invalid_metadata")
      if(.nv_unsigned_cmp(bytes,stagePeak)>0)stagePeak<<-bytes
      .sql_execution_need(.nv_unsigned_cmp(bytes,format(limits$max_stage_bytes,scientific=FALSE,trim=TRUE))<=0,"execution.stage_limit")
      invisible(NULL)
    }
    for(step in program$steps) {
      tick();sid<-sub("[.](create|index|analyze)$","",step$id)
      if(endsWith(step$id,".create"))stageStarts[[sid]]<-wall()
      if(step$kind=="assert_scalar") {
        value<-transport$one(step$sql,step$id,"assertion")
        .sql_execution_need(identical(value,step$expected),"execution.assertion_failed")
      } else transport$execute(step$sql,step$id,"materialization")
      if(grepl("[.](create|index|drop)$",step$id))stageBudget()
      if(grepl("[.](create|index|analyze)$",step$id))stageTimings[[sid]]<-list(duration_ms=.sql_execution_ms(wall()-stageStarts[[sid]]))
    }
    # Physical input conservation totals remain independent of report aggregates.
    # This one fixed-size control row uses the separate metadata transfer budget.
    auditTotals<-.sql_execution_audit_totals(transport$one(program$source_audit$sql,"source.audit_totals","metadata"))
    # No schema declaration substitutes for actual observations in this snapshot.
    capabilities<-.core_capabilities(list(one=function(sql)transport$one(sql,"capabilities.scalar","metadata"),
      stream=function(sql,visitor)transport$stream(sql,visitor,"capabilities.catalog","metadata",maxRows=4096L,maxBytes=8*1024^2)),program$batch$source$cdm_schema)
    .sql_execution_need(.string(capabilities$schema_sha256)&&grepl("^[0-9a-f]{64}$",capabilities$schema_sha256)&&
      setequal(names(capabilities$values),.core_probes()),"execution.invalid_metadata")
    assets<-.v2_assets();metaIds<-.core_metadata_ids();ids<-names(program$outputs);numericIds<-setdiff(ids,metaIds)
    for(cap in capabilities$values).v2_metadata(metaIds[2],cap,assets)
    numericInventory<-paste0('pg_temp."',program$declarations$stage_prefix,'_inventory"')
    preInventory<-list()
    transport$stream(paste0("SELECT row_to_json(i)::text FROM ",numericInventory," i"),function(text) {
      d<-.store_decode(text);.sql_execution_need(.string(d$metric_id)&&d$metric_id%in%numericIds&&is.null(preInventory[[d$metric_id]]),"execution.invalid_metadata")
      preInventory[[d$metric_id]]<<-d
    },"inventory.numeric","metadata",maxRows=length(numericIds),maxBytes=8*1024^2)
    .sql_execution_need(setequal(names(preInventory),numericIds),"execution.invalid_metadata")
    numericRows<-"0"
    for(d in preInventory) {
      .sql_execution_need(.v2_count(d$rows),"execution.invalid_metadata");numericRows<-.nv_add(numericRows,d$rows)
    }
    timingRows<-length(stageTimings)+5L
    minimumRows<-.nv_add(numericRows,as.character(1L+length(capabilities$values)+length(ids)+timingRows))
    .sql_execution_need(.nv_unsigned_cmp(minimumRows,format(limits$max_aggregate_rows,scientific=FALSE,trim=TRUE))<=0,"execution.row_limit")
    rows<-0;bytes<-0;decodeVisitSeconds<-0
    metricRows<-stats::setNames(as.list(rep("0",length(ids))),ids)
    deliver<-function(mid,text,metadata) {
      tick();begin<-wall();n<-nchar(enc2utf8(text),type="bytes")
      .sql_execution_need(rows<limits$max_aggregate_rows,"execution.row_limit")
      .sql_execution_need(bytes+n<=limits$max_aggregate_bytes,"execution.byte_limit")
      row<-.store_decode(text)
      .sql_execution_need(.nv_object(row)&&setequal(names(row),c("metric_id","row_kind","dimensions","values","state","reason_code"))&&
        identical(row$metric_id,mid)&&.nv_object(row$dimensions)&&.string(row$row_kind)&&row$row_kind%in%names(assets$rows[[mid]]$value_keys_by_row_kind)&&
        .string(row$state)&&row$state%in%c("computed","empty_source","empty_population","unsupported","unavailable"),"execution.invalid_metadata")
      if(metadata) {
        .v2_metadata(mid,row$values,assets);.v2_dimensions(mid,row,assets)
      } else if(!is.null(row$values)) {
        .sql_execution_need(.nv_object(row$values)&&all(vapply(row$values,function(x)is.null(x)||.string(x),TRUE)),"execution.invalid_metadata")
        row$values<-lapply(row$values,.baseline_normalize)
      }
      rows<<-rows+1;bytes<<-bytes+n;metricRows[[mid]]<<-.nv_add(metricRows[[mid]],"1")
      visitFailure<-tryCatch({visit(mid,row);NULL},error=identity,interrupt=identity)
      if(!is.null(visitFailure)).sql_execution_error(if(inherits(visitFailure,"interrupt"))"execution.cancelled" else "execution.consumer_failed")
      decodeVisitSeconds<<-decodeVisitSeconds+wall()-begin;tick();invisible(NULL)
    }
    outputSql<-function(spec,metadata)paste0("SELECT jsonb_build_object('metric_id',metric_id,'row_kind',row_kind,'dimensions',dimensions,'values',values,'state',",
      if(metadata)"'computed'::text" else "state",",'reason_code',",if(metadata)"NULL::text" else "reason_code",")::text FROM (",spec$sql,") output")
    for(mid in numericIds) {
      spec<-program$outputs[[mid]]
      transport$stream(outputSql(spec,FALSE),function(text)deliver(mid,text,FALSE),paste0("output.",mid),"aggregate",
        maxRows=limits$max_aggregate_rows-rows,maxBytes=limits$max_aggregate_bytes-bytes)
      .sql_execution_need(identical(metricRows[[mid]],preInventory[[mid]]$rows),"execution.invalid_metadata")
    }
    ended<-.stamp();timings<-.core_timing(stageTimings,.sql_execution_ms(wall()-generationClock))
    facts<-.object(observed_schema_sha256=capabilities$schema_sha256,capabilities=capabilities$values,
      started_at=started,ended_at=ended,timings=lapply(timings,function(t)c(t$dimensions,.object(duration_ms=t$values$duration_ms))))
    .sql_execution_need(.nv_date(started,TRUE)&&.nv_date(ended,TRUE)&&started<=ended,"execution.invalid_metadata")
    inventory<-list()
    transport$stream(paste0("SELECT row_to_json(i)::text FROM (",program$inventory_sql,") i"),function(text) {
      d<-.store_decode(text);mid<-d$metric_id
      .sql_execution_need(.string(mid)&&mid%in%ids&&is.null(inventory[[mid]]),"execution.invalid_metadata")
      m<-assets$metrics[[mid]]
      descriptor<-c(.object(version=m$version,population=m$population,grain=m$grain,row_schema_id=assets$rows[[mid]]$row_schema_id,
        definition_sha256=.v2_hash(.v2_bytes(m)),required=TRUE),d)
      .v2_dataset(descriptor,assets)
      if(mid%in%numericIds).sql_execution_need(identical(.json(d),.json(preInventory[[mid]])),"execution.invalid_metadata")
      inventory[[mid]]<<-d
    },"inventory.complete","metadata",parameter=facts,maxRows=length(ids),maxBytes=8*1024^2)
    .sql_execution_need(setequal(names(inventory),ids),"execution.invalid_metadata")
    for(mid in metaIds) {
      transport$stream(outputSql(program$outputs[[mid]],TRUE),function(text)deliver(mid,text,TRUE),paste0("output.",mid),"metadata_output",
        parameter=facts,maxRows=limits$max_aggregate_rows-rows,maxBytes=limits$max_aggregate_bytes-bytes)
    }
    .sql_execution_need(all(vapply(ids,function(mid)identical(metricRows[[mid]],inventory[[mid]]$rows),TRUE)),"execution.invalid_metadata")
    tick();telemetry<-transport$telemetry()
    telemetry$client_validation_wall_ms<-.sql_execution_ms(validationSeconds)
    telemetry$client_decode_visit_wall_ms<-.sql_execution_ms(decodeVisitSeconds)
    telemetry$engine<-.object(cpu_ms=NULL,peak_memory_bytes=NULL,query_id=NULL,reason_code="postgresql.jdbc_not_attributed")
    telemetry$stage_peak_bytes<-stagePeak
    telemetry$enforcement<-"Stage bytes are sampled after CREATE/INDEX/DROP, not hard disk reservation; cancellation/deadline checks occur between JDBC calls and rows, with per-statement server/JDBC timeout"
    .object(format_version="1.0.0",kind="characterization_execution_receipt",state="succeeded",program_sha256=program$program_sha256,
      profile=program$batch$profile,source=program$batch$source,observed_schema_sha256=capabilities$schema_sha256,capabilities=capabilities$values,
      generation=.object(started_at=started,ended_at=ended),audit_totals=auditTotals,inventory=inventory[ids],runtime_facts=facts,
      rows=format(rows,scientific=FALSE,trim=TRUE),bytes=format(bytes,scientific=FALSE,trim=TRUE),metric_rows=metricRows,telemetry=telemetry,
      cleanup=.object(transaction="rolled_back",connection="disconnected"),canonical_wire=FALSE,publication_changed=FALSE)
  }
  # Capture first, then rethrow outside sibling handlers: tryCatch nests them,
  # so rethrowing an error from a specific handler can invoke a generic sibling.
  outcome<-tryCatch(list(value=work(),failure=NULL),error=function(e)list(value=NULL,failure=e),
    interrupt=function(e)list(value=NULL,failure=e))
  if(!is.null(outcome$failure)) {
    .sql_execution_need(cleanup(),"execution.cleanup_failed")
    if(inherits(outcome$failure,"AchillesSqlExecutionFailure"))stop(outcome$failure)
    .sql_execution_error(if(inherits(outcome$failure,"interrupt"))"execution.cancelled" else "execution.query_failed")
  }
  result<-outcome$value
  .sql_execution_need(cleanup(),"execution.cleanup_failed")
  tick()
  used<-proc.time()-clock
  result$telemetry$client_process_cpu_ms<-.sql_execution_ms(sum(used[c("user.self","sys.self")]))
  result$telemetry$client_call_wall_ms<-.sql_execution_ms(wall()-startedClock)
  result
}
