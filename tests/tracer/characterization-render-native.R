# Metadata cardinalities must follow the inventory, including metadata-only input.
testCharacterizationRenderMetadata <- function(query) {
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object')
  batch<-planCharacterizationBatch('cdm','fixture:metadata-inventory','5.5')
  ids<-f('.core_metadata_ids')();facts<-o(capabilities=o(),timings=list())
  for(n in c(0L,1L,3L,138L,139L)) {
    inventory<-paste0("SELECT 'fixture.metric.'||i::text AS metric_id,'computed'::text AS state,",
      "NULL::text AS reason_code,'0'::text AS rows,'{}'::jsonb AS conditional_support,",
      "'{}'::jsonb AS completeness FROM generate_series(1,",n,") i")
    inventorySql<-f('.render_metadata_queries')(batch,inventory,TRUE)
    ledgerSql<-f('.render_metadata_queries')(batch,inventory)[[ids[3]]]
    counts<-query(paste0("SELECT jsonb_build_object('actual',COUNT(*)::text,'declared',",
      "MAX(rows) FILTER(WHERE metric_id=",f('.store_literal')(ids[3]),"))::text FROM (",inventorySql,") inventory"),facts)
    ledgerRows<-query(paste0("SELECT COUNT(*)::text FROM (",ledgerSql,") ledger"),facts)
    stopifnot(length(counts)==1L,length(ledgerRows)==1L)
    counts<-f('.store_decode')(counts[[1]])
    stopifnot(identical(counts$declared,counts$actual),identical(counts$actual,ledgerRows[[1]]),
      identical(counts$actual,as.character(n+length(ids))))
  }
  cat('RENDERED_METADATA_LEDGER_COUNTS_FOLLOW_INVENTORY_0_1_3_138_139_OK\n')
}

# Small aggregate-only differential proof, called before source access is denied.
# Fixture metadata probes own this small transaction; full programs use the public executor.
testCharacterizationRender <- function(details,schema,sourceId,version,snap) {
  f<-function(n)get(n,asNamespace('AchillesNext'));wire<-f('.json');o<-f('.object')
  connection<-DatabaseConnector::connect(details);jdbc<-connection@jConnection
  on.exit(DatabaseConnector::disconnect(connection),add=TRUE)
  rJava::.jcall(jdbc,'V','setAutoCommit',FALSE);rJava::.jcall(jdbc,'V','setTransactionIsolation',4L)
  on.exit(try(rJava::.jcall(jdbc,'V','rollback'),silent=TRUE),add=TRUE,after=FALSE)
  statement<-function(sql,parameter=NULL) {
    s<-if(is.null(parameter))rJava::.jcall(jdbc,'Ljava/sql/Statement;','createStatement') else
      rJava::.jcall(jdbc,'Ljava/sql/PreparedStatement;','prepareStatement',sql)
    rJava::.jcall(s,'V','setQueryTimeout',60L)
    if(!is.null(parameter))rJava::.jcall(s,'V','setString',1L,wire(parameter))
    s
  }
  execute<-function(sql) {
    s<-statement(sql);on.exit(rJava::.jcall(s,'V','close'))
    rJava::.jcall(s,'Z','execute',sql);invisible(NULL)
  }
  query<-function(sql,parameter=NULL) {
    s<-statement(sql,parameter);on.exit(rJava::.jcall(s,'V','close'))
    rJava::.jcall(s,'V','setFetchSize',128L)
    rs<-if(is.null(parameter))rJava::.jcall(s,'Ljava/sql/ResultSet;','executeQuery',sql) else rJava::.jcall(s,'Ljava/sql/ResultSet;','executeQuery')
    on.exit(rJava::.jcall(rs,'V','close'),add=TRUE,after=FALSE);rows<-list();bytes<-0L
    while(rJava::.jcall(rs,'Z','next')) {
      text<-rJava::.jcall(rs,'S','getString',1L);bytes<-bytes+nchar(text,type='bytes')
      stopifnot(length(rows)<10000L,bytes<8*1024^2)
      rows[[length(rows)+1L]]<-text
    }
    rows
  }
  one<-function(sql){v<-query(sql);stopifnot(length(v)==1L);v[[1]]}
  testCharacterizationRenderMetadata(query)
  columns<-query(paste0("SELECT jsonb_build_object('table',c.relname,'column',a.attname,'type',t.typname,'readable',has_schema_privilege(n.oid,'USAGE') AND has_column_privilege(c.oid,a.attname,'SELECT'))::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid JOIN pg_type t ON t.oid=a.atttypid WHERE n.nspname=",f('.store_literal')(schema)," AND c.relkind IN ('r','p','v','m','f') AND a.attnum>0 AND NOT a.attisdropped"))
  columns<-do.call(rbind,lapply(columns,function(x)as.data.frame(f('.store_decode')(x),stringsAsFactors=FALSE)))
  canonical<-function(rows)sort(vapply(rows,wire,''),method='radix')
  metadataIds<-f('.core_metadata_ids')();ids<-names(f('.v2_assets')()$metrics)
  source_audits<-list()
  for(strategy in c('weighted','reference')) {
    program<-renderCharacterizationSql(schema,sourceId,version,columns,numericStrategy=strategy,
      stagePrefix=paste0('achillesnext_render_',strategy))
    captured<-stats::setNames(lapply(ids,function(mid)list()),ids);seen<-0L;capturedBytes<-0
    before<-f('.stamp')()
    receipt<-executeCharacterizationSql(details,program,function(mid,row) {
      stopifnot(mid%in%ids,identical(row$metric_id,mid),
        setequal(names(row),c('metric_id','row_kind','dimensions','values','state','reason_code')))
      seen<<-seen+1L;capturedBytes<<-capturedBytes+nchar(wire(row),type='bytes')
      stopifnot(seen<=100000L,capturedBytes<=64*1024^2)
      captured[[mid]][[length(captured[[mid]])+1L]]<<-row[c('row_kind','dimensions','values','state','reason_code')]
    },maxAggregateRows=100000L,maxAggregateBytes=64*1024^2,fetchSize=if(strategy=='weighted')1L else 128L)
    testCharacterizationExecuteAudit(receipt)
    source_audits[[strategy]]<-receipt$audit_totals
    after<-f('.stamp')();runtime<-receipt$runtime_facts
    stopifnot(receipt$kind=='characterization_execution_receipt',receipt$state=='succeeded',
      receipt$program_sha256==program$program_sha256,!receipt$canonical_wire,!receipt$publication_changed,
      identical(receipt$cleanup$transaction,'rolled_back'),identical(receipt$cleanup$connection,'disconnected'),
      setequal(names(receipt$inventory),ids),setequal(names(receipt$metric_rows),ids),
      length(receipt$inventory)==142L,receipt$rows==as.character(seen),
      runtime$observed_schema_sha256==snap$schema_sha256,receipt$observed_schema_sha256==snap$schema_sha256,
      identical(wire(runtime$capabilities),wire(receipt$capabilities)),
      runtime$started_at>=before,runtime$started_at<=runtime$ended_at,runtime$ended_at<=after,
      identical(receipt$generation$started_at,runtime$started_at),identical(receipt$generation$ended_at,runtime$ended_at))
    for(mid in ids) {
      inventory<-receipt$inventory[[mid]]
      stopifnot(identical(inventory$rows,as.character(length(captured[[mid]]))),
        identical(receipt$metric_rows[[mid]],inventory$rows))
      if(!mid%in%metadataIds) {
        expected<-snap$datasets[[mid]][names(inventory)]
        if(!identical(wire(inventory),wire(expected)))stop(paste('Executed inventory differs:',mid,strategy),call.=FALSE)
      }
      expected<-lapply(snap$rows[[mid]],function(r)r[c('row_kind','dimensions','values','state','reason_code')])
      if(mid=='core.source.passport')expected[[1]]$values$generation<-o(started_at=runtime$started_at,ended_at=runtime$ended_at)
      if(mid!='core.execution.timing'&&!identical(canonical(captured[[mid]]),canonical(expected)))
        stop(paste('Executed output differs:',mid,strategy),call.=FALSE)
    }
    timing<-captured[['core.execution.timing']]
    stopifnot(length(timing)==length(runtime$timings),!anyDuplicated(vapply(timing,function(r)wire(r$dimensions),'')))
    for(row in timing) {
      matches<-Filter(function(t)identical(t$operation_id,row$dimensions$operation_id)&&identical(t$phase,row$dimensions$phase),runtime$timings)
      stopifnot(length(matches)==1L,identical(row$values$duration_ms,matches[[1]]$duration_ms),
        all(vapply(row$values$telemetry,is.null,TRUE)),row$state=='computed',is.null(row$reason_code))
      if(is.null(row$values$duration_ms))stopifnot(row$values$availability=='unavailable',
        row$values$reason_code=='execution.not_started_at_metadata_capture') else
        stopifnot(grepl('^(0|[1-9][0-9]*)$',row$values$duration_ms),row$values$availability=='measured',is.null(row$values$reason_code))
    }
    telemetry<-receipt$telemetry
    stopifnot(is.null(telemetry$engine$cpu_ms),is.null(telemetry$engine$peak_memory_bytes),
      is.null(telemetry$engine$query_id),telemetry$engine$reason_code=='postgresql.jdbc_not_attributed')
    for(name in c('client_process_cpu_ms','client_decode_visit_wall_ms','jdbc_submit_wait_ms','jdbc_fetch_wait_ms'))
      stopifnot(is.character(telemetry[[name]]),length(telemetry[[name]])==1L,!is.na(telemetry[[name]]),
        grepl('^(0|[1-9][0-9]*)$',telemetry[[name]]),as.numeric(telemetry[[name]])>=0)
    stopifnot(as.numeric(telemetry$statement_count)>=length(program$steps),
      grepl('^(0|[1-9][0-9]*)$',telemetry$stage_peak_bytes),as.numeric(telemetry$stage_peak_bytes)>0,
      grepl('^(0|[1-9][0-9]*)$',receipt$bytes),as.numeric(receipt$bytes)>0)
  }
  cat('EXECUTED_142_PARITY ',version,' BOTH_EXACT_STRATEGIES_ACTUAL_RUNTIME_FACTS\n',sep='')
  invisible(list(columns=columns,source_audits=source_audits))
}
