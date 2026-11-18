# A separate R/JVM is used only for the blocked-query timeout proof.
.executeFixtureSave <- function(value,path) {
  tmp<-paste0(path,'.tmp');writeLines(jsonlite::toJSON(value,auto_unbox=TRUE,null='null',digits=NA),tmp,useBytes=TRUE)
  stopifnot(file.rename(tmp,path))
}
.executeFixtureWorker <- function(contextPath) {
  ctx<-jsonlite::fromJSON(contextPath,simplifyVector=FALSE)
  .executeFixtureSave(as.character(Sys.getpid()),ctx$pid_file)
  library(AchillesNext)
  env<-new.env(parent=globalenv());sys.source(ctx$config,env)
  columns<-do.call(rbind,lapply(ctx$columns,as.data.frame,stringsAsFactors=FALSE))
  base<-env$fixtureConnection()
  details<-DatabaseConnector::createConnectionDetails(dbms=base$dbms,server=base$server(),port=base$port(),
    user=base$user(),password=base$password(),extraSettings=paste0('ApplicationName=',ctx$app))
  program<-renderCharacterizationSql(ctx$schema,ctx$source_id,ctx$version,columns,stagePrefix='achillesnext_timeout')
  visited<-0L;start<-proc.time()[['elapsed']]
  result<-tryCatch({
    executeCharacterizationSql(details,program,function(...){visited<<-visited+1L},
      statementTimeoutMs=500L,maxElapsedSeconds=10)
    list(ok=TRUE)
  },error=function(e)list(ok=FALSE,class=class(e),code=e$reason_code,message=conditionMessage(e)),
    interrupt=function(e)list(ok=FALSE,class=class(e),code=e$reason_code,message=conditionMessage(e)))
  result$visited<-visited;result$elapsed<-proc.time()[['elapsed']]-start
  .executeFixtureSave(result,ctx$result_file)
}

# Unicode payloads cross the actual JDBC seam only after engine-side byte guards.
testCharacterizationExecuteUtf8Transport <- function(details) {
  f<-function(n)get(n,asNamespace('AchillesNext'));original<-get('.jcall',asNamespace('rJava'))
  trial<-function(name,sql,maxRowBytes,maxBytes,code,payloadReads,guards,maxRows=2L) {
    con<-DatabaseConnector::connect(details);jdbc<-con@jConnection
    on.exit(DatabaseConnector::disconnect(con),add=TRUE)
    rJava::.jcall(jdbc,'V','setAutoCommit',FALSE)
    on.exit(try(rJava::.jcall(jdbc,'V','rollback'),silent=TRUE),add=TRUE,after=FALSE)
    prepared<-character();reads<-0L;visited<-list()
    spy<-function(obj,returnSig='V',method,...,evalArray=TRUE,evalString=TRUE,check=TRUE,
      interface='RcallMethod',simplify=FALSE,use.true.class=FALSE) {
      args<-list(...)
      if(identical(method,'prepareStatement'))prepared<<-c(prepared,args[[1]])
      if(identical(method,'getString')&&identical(args[[1]],1L))reads<<-reads+1L
      original(obj,returnSig,method,...,evalArray=evalArray,evalString=evalString,check=check,
        interface=interface,simplify=simplify,use.true.class=use.true.class)
    }
    assignInNamespace('.jcall',spy,ns='rJava')
    on.exit(assignInNamespace('.jcall',original,ns='rJava'),add=TRUE)
    limits<-f('.sql_execution_limits')(64*1024^2,maxRows,maxBytes,maxRowBytes,1L,5000L,10,function(...)NULL,NULL)
    transport<-f('.sql_execution_transport')(jdbc,limits,function()NULL,proc.time()[['elapsed']])
    error<-tryCatch({transport$stream(sql,function(text){visited[[length(visited)+1L]]<<-text},
      paste0('fixture.',name),'aggregate',maxRows=maxRows,maxBytes=maxBytes);NULL},error=identity)
    assignInNamespace('.jcall',original,ns='rJava')
    if(is.null(code))stopifnot(is.null(error)) else
      stopifnot(inherits(error,'AchillesSqlExecutionFailure'),identical(error$reason_code,code))
    stopifnot(length(prepared)==1L,reads==payloadReads,length(visited)==payloadReads)
    for(text in visited)stopifnot(nchar(text,type='bytes')<=maxRowBytes)
    # Independently inspect what the engine returned, not just callback behavior.
    # Rollback acknowledges any cancellation before issuing a fresh audit query.
    rJava::.jcall(jdbc,'V','rollback')
    statement<-rJava::.jcall(jdbc,'Ljava/sql/PreparedStatement;','prepareStatement',prepared[[1]])
    on.exit(rJava::.jcall(statement,'V','close'),add=TRUE,after=FALSE)
    rs<-rJava::.jcall(statement,'Ljava/sql/ResultSet;','executeQuery')
    on.exit(rJava::.jcall(rs,'V','close'),add=TRUE,after=FALSE)
    actual<-character()
    while(rJava::.jcall(rs,'Z','next')) {
      payload<-rJava::.jcall(rs,'S','getString',1L);guard<-rJava::.jcall(rs,'S','getString',2L)
      actual<-c(actual,guard)
      if(guard=='ok')stopifnot(is.character(payload),nchar(payload,type='bytes')<=maxRowBytes) else
        stopifnot(is.null(payload))
    }
    stopifnot(identical(actual,guards))
    invisible(TRUE)
  }
  # Multiple one-row fetches with a large total budget; the sentinel limit
  # must also be representable one row beyond the maximum accepted budget.
  trial('large_budget',"SELECT * FROM (VALUES ('0'),('1'),('0')) z(doc)",
    16L,64L,NULL,3L,rep('ok',3L),maxRows=.Machine$integer.max)
  # JSONB adds13ASCII bytes around this value. The exact row is64UTF8 bytes,
  # while the overflow row has only47characters but80UTF8 bytes.
  exact<-paste0('{"value": "',strrep('λ',25),'x"}')
  overflow<-paste0('{"value": "',strrep('λ',33),'x"}')
  stopifnot(nchar(exact,type='bytes')==64L,nchar(overflow,type='chars')==47L,nchar(overflow,type='bytes')==80L)
  sql<-function(n,rows=1L)paste0("SELECT jsonb_build_object('value',repeat('λ',",n,")||'x')::text FROM generate_series(1,",rows,")")
  trial('utf8_exact',sql(25L),64L,64L,NULL,1L,'ok')
  trial('utf8_row_overflow',sql(33L),64L,256L,'execution.row_byte_limit',0L,'row_bytes')
  trial('utf8_total_overflow',sql(25L,2L),64L,100L,'execution.byte_limit',1L,c('ok','bytes'))
  cat('EXECUTOR_UTF8_EXACT_ROW_AND_TOTAL_LIMITS_NULL_SENTINELS_NO_OVERFLOW_PAYLOAD_READ_OK\n')
  invisible(TRUE)
}

# This receipt is separate from the142report/wire outputs. Python compares its
# actual values with raw physical fixture rows; these checks also bound its shape.
testCharacterizationExecuteAudit <- function(receipt) {
  f<-function(n)get(n,asNamespace('AchillesNext'));audit<-receipt$audit_totals
  stopifnot(is.list(audit),setequal(names(audit),c('population','domains')),
    nchar(f('.json')(audit),type='bytes')<=16384L,length(receipt$inventory)==142L,
    !'audit_totals'%in%names(receipt$runtime_facts))
  population<-audit$population
  stopifnot(setequal(names(population),c('person_count','nonnull','distinct','raw_observation_count','merged_interval_count')))
  count<-function(x)is.character(x)&&length(x)==1L&&!is.na(x)&&grepl('^(0|[1-9][0-9]*)$',x)
  stopifnot(all(vapply(population,count,TRUE)),
    identical(population$person_count,population$nonnull),identical(population$person_count,population$distinct),
    f('.nv_unsigned_cmp')(population$merged_interval_count,population$raw_observation_count)<=0L)
  domains<-c('condition','drug','procedure','visit','device','observation','death','specimen','measurement')
  stopifnot(setequal(names(audit$domains),domains),length(audit$domains)==9L)
  for(domain in domains) {
    totals<-audit$domains[[domain]]
    stopifnot(setequal(names(totals),c('raw','linked','observed','start','end')),
      all(vapply(totals[c('raw','linked','observed')],count,TRUE)),
      f('.nv_unsigned_cmp')(totals$observed,totals$linked)<=0L,
      f('.nv_unsigned_cmp')(totals$linked,totals$raw)<=0L,
      identical(is.null(totals$start),is.null(totals$end)))
    if(is.null(totals$start))stopifnot(totals$observed=='0') else
      stopifnot(f('.nv_date')(totals$start,FALSE),f('.nv_date')(totals$end,FALSE),totals$start<=totals$end)
    if(totals$raw=='0')stopifnot(totals$linked=='0',totals$observed=='0',is.null(totals$start),is.null(totals$end))
    if(population$person_count=='0')stopifnot(totals$linked=='0',totals$observed=='0')
  }
  statements<-receipt$telemetry$statements
  auditAt<-which(vapply(statements,function(x)identical(x$id,'source.audit_totals'),TRUE))
  outputAt<-which(vapply(statements,function(x)startsWith(x$id,'output.'),TRUE))
  stopifnot(length(auditAt)==1L,length(outputAt)==142L,all(auditAt<outputAt),
    statements[[auditAt]]$phase=='metadata',statements[[auditAt]]$kind=='query',
    identical(statements[[auditAt]]$rows,'1'))
  invisible(TRUE)
}

# Called once by the core driver while its marked source fixture is readable.
testCharacterizationExecuteFailures <- function(details,owner,schema,sourceId,version,columns,fixtureConfig,out) {
  f<-function(n)get(n,asNamespace('AchillesNext'));wire<-f('.json');lit<-f('.store_literal')
  jdbc<-owner@jConnection
  q<-function(sql)DatabaseConnector::querySql(owner,sql,integer64AsNumeric=FALSE,
    errorReportFile=file.path(out,'execute-owner-query-error.txt'))
  marker<-q("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(marker$DB=='achilles_next_fixtures',marker$MARKER=='AchillesNext synthetic fixture sandbox v1',
    grepl('^cdm_tiny_domain_[0-9]+_[0-9]+$',schema))
  testCharacterizationExecuteUtf8Transport(details)
  tables<-unique(c('person','observation_period','concept',vapply(f('.v2_assets')()$profile$domains,function(d)d$table,'')))
  fingerprint<-function()vapply(tables,function(table) {
    q(paste0("SELECT md5(COALESCE(string_agg(digest,',' ORDER BY digest),'')) AS fingerprint FROM (SELECT md5(row_to_json(t)::text) AS digest FROM \"",
      schema,'"."',table,'" t) hashed'))$FINGERPRINT
  },'')
  temporary<-function()q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname LIKE 'achillesnext_%'")$N
  original<-fingerprint();baselineTemp<-temporary();failures<-list()
  expect<-function(name,work,code) {
    e<-tryCatch({work();NULL},error=identity,interrupt=identity)
    stopifnot(inherits(e,'AchillesSqlExecutionFailure'),identical(e$reason_code,code),is.null(e$call),is.null(e$parent),
      !grepl('private executor consumer sentinel',conditionMessage(e),fixed=TRUE),
      !grepl('private executor cancellation sentinel',conditionMessage(e),fixed=TRUE),
      identical(temporary(),baselineTemp),identical(fingerprint(),original))
    failures[[name]]<<-code
  }
  program<-renderCharacterizationSql(schema,sourceId,version,columns,stagePrefix='achillesnext_failure')
  visited<-0L;visit<-function(...){visited<<-visited+1L}
  stale<-columns;at<-which(stale$table=='person'&stale$column=='year_of_birth');stopifnot(length(at)==1L)
  stale$type[at]<-if(stale$type[at]=='int4')'int8' else 'int4'
  staleProgram<-renderCharacterizationSql(schema,sourceId,version,stale,stagePrefix='achillesnext_stale')
  expect('stale_declaration',function()executeCharacterizationSql(details,staleProgram,visit),'execution.assertion_failed')
  stopifnot(visited==0L)
  for(limit in list(list(name='stage',options=list(maxStageBytes=0),code='execution.stage_limit'),
    list(name='aggregate_rows',options=list(maxAggregateRows=0),code='execution.row_limit'),
    list(name='aggregate_bytes',options=list(maxAggregateBytes=0),code='execution.byte_limit'),
    list(name='row_bytes',options=list(maxRowBytes=1L),code='execution.row_byte_limit'))) {
    visited<-0L
    expect(limit$name,function()do.call(executeCharacterizationSql,c(list(details,program,visit),limit$options)),limit$code)
    stopifnot(visited==0L)
  }
  visited<-0L
  expect('consumer_error',function()executeCharacterizationSql(details,program,function(...) {
    visited<<-visited+1L;stop('private executor consumer sentinel')
  }),'execution.consumer_failed')
  # A consumer may already have seen a staged row. The executor cannot undo its
  # external effects; it must still roll back/disconnect and return no success.
  stopifnot(visited==1L)
  cancelled<-FALSE;visited<-0L
  expect('late_cancellation',function()executeCharacterizationSql(details,program,function(...) {
    visited<<-visited+1L;cancelled<<-TRUE
  },check=function(){if(cancelled)stop(structure(list(message='private executor cancellation sentinel',call=NULL),class=c('interrupt','condition')))}),
    'execution.cancelled')
  stopifnot(visited>=1L)

  # The owner lock makes a real source query wait. The worker has its own JVM,
  # while this parent can release the lock even if timeout enforcement regresses.
  folder<-file.path(out,'execute-blocked-timeout');stopifnot(dir.create(folder,mode='0700'))
  script<-normalizePath('tests/tracer/characterization-execute-native.R',mustWork=TRUE)
  contextPath<-file.path(folder,'context.json');pidFile<-file.path(folder,'pid.json');resultFile<-file.path(folder,'result.json')
  control<-DatabaseConnector::connect(details);controlSession<-f('.tracer_session')(control)
  on.exit({try(controlSession$rollback(),silent=TRUE);try(DatabaseConnector::disconnect(control),silent=TRUE)},add=TRUE)
  ctx<-list(config=normalizePath(fixtureConfig,mustWork=TRUE),app=paste0('achilles_execute_timeout_',Sys.getpid()),schema=schema,source_id=sourceId,version=version,
    columns=lapply(seq_len(nrow(columns)),function(i)as.list(columns[i,,drop=FALSE])),pid_file=pidFile,result_file=resultFile)
  .executeFixtureSave(ctx,contextPath)
  auto<-rJava::.jcall(jdbc,'Z','getAutoCommit');readOnly<-rJava::.jcall(jdbc,'Z','isReadOnly');isolation<-rJava::.jcall(jdbc,'I','getTransactionIsolation')
  restored<-FALSE
  restore<-function() {
    if(restored)return(invisible(NULL))
    try(rJava::.jcall(jdbc,'V','rollback'),silent=TRUE)
    rJava::.jcall(jdbc,'V','setReadOnly',readOnly);rJava::.jcall(jdbc,'V','setTransactionIsolation',isolation)
    rJava::.jcall(jdbc,'V','setAutoCommit',auto);restored<<-TRUE
    invisible(NULL)
  }
  stopChild<-function() {
    if(!file.exists(pidFile))return(invisible(NULL))
    pid<-jsonlite::fromJSON(pidFile);stopifnot(is.character(pid),length(pid)==1L,grepl('^[1-9][0-9]*$',pid))
    owned<-function() {
      command<-suppressWarnings(system2('ps',c('-p',pid,'-o','args='),stdout=TRUE,stderr=FALSE))
      any(grepl(script,command,fixed=TRUE)&grepl(contextPath,command,fixed=TRUE))
    }
    start<-proc.time()[['elapsed']]
    while(owned()&&proc.time()[['elapsed']]-start<2)Sys.sleep(.02)
    for(signal in c(2L,15L,9L)) {
      if(!owned())return(invisible(NULL))
      try(tools::pskill(as.integer(pid),signal=signal),silent=TRUE)
      start<-proc.time()[['elapsed']]
      while(owned()&&proc.time()[['elapsed']]-start<2)Sys.sleep(.02)
    }
    stopifnot(!owned())
  }
  # Release owner locks before stopping a child or outer schema cleanup.
  on.exit({restore();stopChild()},add=TRUE)
  rJava::.jcall(jdbc,'V','setAutoCommit',FALSE);rJava::.jcall(jdbc,'V','setReadOnly',FALSE)
  statement<-rJava::.jcall(jdbc,'Ljava/sql/Statement;','createStatement')
  tryCatch({rJava::.jcall(statement,'V','setQueryTimeout',5L)
    rJava::.jcall(statement,'Z','execute',paste0('LOCK TABLE "',schema,'".person IN ACCESS EXCLUSIVE MODE'))
  },finally=rJava::.jcall(statement,'V','close'))
  launched<-system2(file.path(R.home('bin'),'Rscript'),c('--vanilla',shQuote(script),'blocked-worker',shQuote(contextPath)),
    stdout=file.path(folder,'worker.log'),stderr=file.path(folder,'worker-error.log'),wait=FALSE)
  stopifnot(launched==0L);start<-proc.time()[['elapsed']]
  blocked<-FALSE
  while(!file.exists(resultFile)&&proc.time()[['elapsed']]-start<20) {
    controlSession$execute('SELECT pg_stat_clear_snapshot()')
    wait<-controlSession$query(paste0("SELECT count(*)::text AS waiting FROM pg_stat_activity WHERE datname=current_database() AND usename=current_user AND application_name=",
      lit(ctx$app)," AND wait_event_type='Lock'"))
    if(identical(wait$WAITING,'1'))blocked<-TRUE
    Sys.sleep(.02)
  }
  timedOut<-!file.exists(resultFile);restore()
  if(timedOut)stopChild()
  stopifnot(!timedOut)
  result<-jsonlite::fromJSON(resultFile,simplifyVector=FALSE)
  stopifnot(!isTRUE(result$ok),'AchillesSqlExecutionFailure'%in%unlist(result$class),
    identical(result$code,'execution.query_failed'),blocked,result$visited==0L,result$elapsed<10,
    identical(temporary(),baselineTemp),identical(fingerprint(),original))
  stopChild();failures$blocked_query_timeout<-'execution.query_failed'
  .executeFixtureSave(list(status='passed',failures=failures,source_unchanged=TRUE,temporary_cleanup=TRUE,
    callback_side_effects='staging consumer responsibility; not rolled back by source transaction',
    timeout='real source lock wait observed on uniquely named worker; bounded worker watchdog, no database process signaled'),file.path(out,'execute-failures.json'))
  cat('EXECUTOR_ASSERTIONS_BUDGETS_CALLBACKS_CANCELLATION_AND_BLOCKED_QUERY_TIMEOUT_OK\n')
  invisible(TRUE)
}

.executeFixtureArgs<-commandArgs(TRUE)
if(length(.executeFixtureArgs)==2L&&identical(.executeFixtureArgs[1],'blocked-worker'))
  .executeFixtureWorker(.executeFixtureArgs[2])
