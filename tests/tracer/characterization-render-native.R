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
# The test driver owns its JDBC transaction; it is not a production execution API.
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
  passport<-snap$rows[['core.source.passport']][[1]]$values
  caps<-snap$rows[['core.source.capabilities']]
  # Identical actual reference-run inputs prove metadata formatting/value parity.
  # They are not a measurement of this test driver's subsequent execution time.
  facts<-o(observed_schema_sha256=snap$schema_sha256,
    capabilities=stats::setNames(lapply(caps,function(r)r$values),vapply(caps,function(r)r$dimensions$probe_id,'')),
    started_at=passport$generation$started_at,ended_at=passport$generation$ended_at,
    timings=lapply(snap$rows[['core.execution.timing']],function(r)c(r$dimensions,o(duration_ms=r$values$duration_ms))))
  canonical<-function(rows)sort(vapply(rows,wire,''),method='radix')
  for(strategy in c('weighted','reference')) {
    program<-renderCharacterizationSql(schema,sourceId,version,columns,numericStrategy=strategy,stagePrefix=paste0('achillesnext_render_',strategy))
    for(step in program$steps) {
      if(step$kind=='assert_scalar')stopifnot(identical(one(step$sql),step$expected)) else execute(step$sql)
    }
    inventory<-lapply(query(paste0("SELECT row_to_json(i)::text FROM (",program$inventory_sql,") i"),facts),f('.store_decode'))
    stopifnot(length(inventory)==142L)
    for(d in inventory) {
      expected<-snap$datasets[[d$metric_id]][names(d)]
      if(!identical(wire(d),wire(expected)))stop(paste('Rendered inventory differs:',d$metric_id,strategy),call.=FALSE)
    }
    for(mid in names(program$outputs)) {
      spec<-program$outputs[[mid]];metadata<-spec$kind=='runtime_metadata'
      sql<-paste0("SELECT jsonb_build_object('row_kind',row_kind,'dimensions',dimensions,'values',values,'state',",
        if(metadata)"'computed'::text" else 'state',",'reason_code',",if(metadata)'NULL::text' else 'reason_code',")::text FROM (",spec$sql,") report")
      got<-lapply(query(sql,if(metadata)facts else NULL),function(text) {
        row<-f('.store_decode')(text)
        if(!metadata&&!is.null(row$values))row$values<-lapply(row$values,f('.baseline_normalize'))
        row
      })
      expected<-lapply(snap$rows[[mid]],function(r)r[c('row_kind','dimensions','values','state','reason_code')])
      if(!identical(canonical(got),canonical(expected)))stop(paste('Rendered output differs:',mid,strategy),call.=FALSE)
    }
    # A changed declaration fails before materialization in a future executor.
    declaration<-program$steps[[which(vapply(program$steps,function(s)s$id=='source.declaration',TRUE))]]
    stopifnot(identical(one(declaration$sql),'true'))
    if(any(columns$table=='care_site'&columns$column=='place_of_service_concept_id')) {
      stale<-columns[!(columns$table=='care_site'&columns$column=='place_of_service_concept_id'),,drop=FALSE]
      staleProgram<-renderCharacterizationSql(schema,sourceId,version,stale)
      staleGuard<-Filter(function(s)s$id=='source.declaration',staleProgram$steps)[[1]]
      stopifnot(identical(one(staleGuard$sql),'false'))
    }
  }
  cat('RENDERED_142_PARITY ',version,' BOTH_EXACT_STRATEGIES\n',sep='')
  invisible(TRUE)
}
