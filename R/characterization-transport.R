# Single-column UTF-8 transport for checked programs. SQL size guards run on the
# engine before JDBC sees a payload; cursor batches and callbacks remain bounded.
.sql_execution_transport <- function(jdbc,limits,tick,startedClock) {
  records<-list();submitSeconds<-0;fetchSeconds<-0;metadataRows<-0;metadataBytes<-0
  # Keep the registered step visible even when PostgreSQL truncates activity text.
  statementTag <- function(id) {
    .sql_execution_need(.string(id) && grepl("\\A[a-z0-9_.-]{1,128}\\z",id,perl=TRUE,useBytes=TRUE),"execution.invalid_program")
    paste0("/* AchillesNext ",id," */ ")
  }
  wall<-function()proc.time()[["elapsed"]]
  timeout<-function()as.integer(max(1,min(ceiling(limits$statement_timeout_ms/1000),
    ceiling(limits$max_elapsed_seconds-(wall()-startedClock)))))
  record<-function(id,phase,kind,sql,submit,fetch,rows,bytes) {
    .sql_execution_need(length(records)<1024L,"execution.metadata_limit")
    records[[length(records)+1L]]<<-.object(id=id,phase=phase,kind=kind,sql_sha256=.hash(sql),
      submit_wait_ms=.sql_execution_ms(submit),fetch_wait_ms=.sql_execution_ms(fetch),rows=format(rows,scientific=FALSE,trim=TRUE),
      bytes=format(bytes,scientific=FALSE,trim=TRUE))
    submitSeconds<<-submitSeconds+submit;fetchSeconds<<-fetchSeconds+fetch
  }
  close<-function(stmt,rs,complete) {
    if(!complete)try(rJava::.jcall(stmt,"V","cancel"),silent=TRUE)
    if(!is.null(rs))try(rJava::.jcall(rs,"V","close"),silent=TRUE)
    try(rJava::.jcall(stmt,"V","close"),silent=TRUE)
    invisible(NULL)
  }
  execute<-function(sql,id,phase) {
    tick();stmt<-rJava::.jcall(jdbc,"Ljava/sql/Statement;","createStatement");complete<-FALSE
    on.exit(close(stmt,NULL,complete),add=TRUE)
    rJava::.jcall(stmt,"V","setQueryTimeout",timeout())
    begin<-wall();rJava::.jcall(stmt,"Z","execute",paste0(statementTag(id),sql));duration<-wall()-begin
    tick();record(id,phase,"execute",sql,duration,0,0,0);complete<-TRUE;invisible(NULL)
  }
  stream<-function(sql,visit,id,phase,parameter=NULL,maxRows=4096L,maxBytes=8*1024^2) {
    tick();.sql_execution_need(is.numeric(maxRows)&&maxRows>=0&&maxRows<=.Machine$integer.max&&maxRows==floor(maxRows)&&
      is.numeric(maxBytes)&&is.finite(maxBytes)&&maxBytes>=0,"execution.invalid_limits")
    if(!phase%in%c("aggregate","metadata_output")) {
      maxRows<-min(maxRows,8192L-metadataRows)
      maxBytes<-min(maxBytes,16*1024^2-metadataBytes)
    }
    # Keep overflow rows as tiny status sentinels. No rejected payload crosses
    # JDBC, including the extra row used to detect a row-count limit.
    rowLimit<-format(maxRows,scientific=FALSE,trim=TRUE);byteLimit<-format(maxBytes,scientific=FALSE,trim=TRUE)
    guard<-paste0("CASE WHEN row_no>",rowLimit," THEN 'rows' WHEN doc IS NULL OR octet_length(convert_to(doc,'UTF8'))>",
      limits$max_row_bytes," THEN 'row_bytes' WHEN payload_bytes>",byteLimit," THEN 'bytes' ELSE 'ok' END")
    wrapped<-paste0(statementTag(id),"SELECT CASE WHEN guard='ok' THEN doc ELSE NULL END AS doc,guard FROM (SELECT doc,",guard,
      " AS guard FROM (SELECT doc,row_number() OVER (ROWS UNBOUNDED PRECEDING) AS row_no,",
      "sum(octet_length(convert_to(doc,'UTF8'))) OVER (ROWS UNBOUNDED PRECEDING) AS payload_bytes FROM (",sql,
      ") q(doc) LIMIT ",format(maxRows+1,scientific=FALSE,trim=TRUE),") bounded) guarded")
    stmt<-rJava::.jcall(jdbc,"Ljava/sql/PreparedStatement;","prepareStatement",wrapped)
    rs<-NULL;complete<-FALSE;on.exit(close(stmt,rs,complete),add=TRUE)
    rJava::.jcall(stmt,"V","setQueryTimeout",timeout());rJava::.jcall(stmt,"V","setFetchSize",limits$fetch_size)
    if(!is.null(parameter))rJava::.jcall(stmt,"V","setString",1L,.json(parameter))
    begin<-wall();rs<-rJava::.jcall(stmt,"Ljava/sql/ResultSet;","executeQuery");submit<-wall()-begin
    meta<-rJava::.jcall(rs,"Ljava/sql/ResultSetMetaData;","getMetaData")
    .sql_execution_need(rJava::.jcall(meta,"I","getColumnCount")==2L,"execution.invalid_metadata")
    rows<-0;bytes<-0;fetch<-0
    repeat {
      tick();begin<-wall();more<-rJava::.jcall(rs,"Z","next");fetch<-fetch+wall()-begin
      if(!more)break
      begin<-wall();guardState<-rJava::.jcall(rs,"S","getString",2L);fetch<-fetch+wall()-begin
      .sql_execution_need(!identical(guardState,"rows")&&rows<maxRows,
        if(phase%in%c("aggregate","metadata_output"))"execution.row_limit" else "execution.metadata_limit")
      .sql_execution_need(!identical(guardState,"row_bytes"),"execution.row_byte_limit")
      .sql_execution_need(!identical(guardState,"bytes"),
        if(phase%in%c("aggregate","metadata_output"))"execution.byte_limit" else "execution.metadata_limit")
      .sql_execution_need(identical(guardState,"ok"),"execution.invalid_metadata")
      begin<-wall();text<-rJava::.jcall(rs,"S","getString",1L);fetch<-fetch+wall()-begin
      .sql_execution_need(.string(text),"execution.row_byte_limit")
      size<-nchar(enc2utf8(text),type="bytes")
      .sql_execution_need(size<=limits$max_row_bytes,"execution.row_byte_limit")
      .sql_execution_need(bytes+size<=maxBytes,if(phase%in%c("aggregate","metadata_output"))"execution.byte_limit" else "execution.metadata_limit")
      rows<-rows+1;bytes<-bytes+size
      if(!phase%in%c("aggregate","metadata_output")) {
        metadataRows<<-metadataRows+1;metadataBytes<<-metadataBytes+size
        .sql_execution_need(metadataRows<=8192L&&metadataBytes<=16*1024^2,"execution.metadata_limit")
      }
      tick();visit(text);tick()
    }
    record(id,phase,"query",sql,submit,fetch,rows,bytes);complete<-TRUE;invisible(NULL)
  }
  one<-function(sql,id,phase) {
    values<-list();stream(sql,function(text)values[[length(values)+1L]]<<-text,id,phase,maxRows=1L,maxBytes=limits$max_row_bytes)
    .sql_execution_need(length(values)==1L,"execution.assertion_failed");values[[1L]]
  }
  list(execute=execute,stream=stream,one=one,telemetry=function().object(
    jdbc_submit_wait_ms=.sql_execution_ms(submitSeconds),jdbc_fetch_wait_ms=.sql_execution_ms(fetchSeconds),
    jdbc_scope="Client-observed JDBC execute/fetch round-trip wall time including network/driver waits; not database CPU",
    statement_count=length(records),statements=records,metadata_rows=format(metadataRows,scientific=FALSE,trim=TRUE),
    metadata_bytes=format(metadataBytes,scientific=FALSE,trim=TRUE)))
}
