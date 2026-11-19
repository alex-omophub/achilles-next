# Executable programs are closed compiler artifacts, not arbitrary trusted SQL.
library(AchillesNext)
local({
  args<-commandArgs(TRUE);stopifnot(length(args)==1L)
  input<-jsonlite::fromJSON(args[1],simplifyVector=FALSE)[[1]]
  columns<-do.call(rbind,lapply(names(input$columns),function(table) {
    x<-input$columns[[table]]
    data.frame(table=table,column=names(x),type=vapply(x,function(t)switch(t,bigint='int8',integer='int4',t),''),
      readable=!table%in%unlist(input$denied_tables),stringsAsFactors=FALSE)
  }))
  f<-function(n)get(n,asNamespace('AchillesNext'));wire<-f('.json')
  program<-renderCharacterizationSql('cdm','fixture:execute-offline',input$version,columns)
  attempts<-0L;connect<-get('connect',asNamespace('DatabaseConnector'))
  on.exit(assignInNamespace('connect',connect,ns='DatabaseConnector'),add=TRUE)
  assignInNamespace('connect',function(...){attempts<<-attempts+1L;stop('private connection sentinel')},ns='DatabaseConnector')
  expect<-function(work,code) {
    e<-tryCatch({work();NULL},error=identity,interrupt=identity)
    if(!identical(e$reason_code,code))stop(paste('Expected executor reason',code,'received',e$reason_code),call.=FALSE)
    stopifnot(inherits(e,'AchillesSqlExecutionFailure'),identical(e$reason_code,code),
      !grepl('private connection sentinel',conditionMessage(e),fixed=TRUE),is.null(e$call),is.null(e$parent),attempts==0L)
  }
  rehash<-function(p){p$program_sha256<-NULL;p$program_sha256<-f('.hash')(wire(p));p}
  changes<-list(
    function(p){p$kind<-'arbitrary_sql';p},
    function(p){p$dialect<-'snowflake';p},
    function(p){p$extra<-TRUE;p},
    function(p){p$execution$state<-'executed';p},
    function(p){p$outputs<-p$outputs[-1L];p},
    function(p){p$steps[[2]]$id<-p$steps[[1]]$id;p},
    function(p){p$steps[[1]]$sql<-'SELECT pg_sleep(100)';p},
    function(p){p$steps[[1]]$expected<-'false';p},
    function(p){p$outputs[['core.source.passport']]$parameters<-list();p},
    function(p){p$declarations$columns_sha256<-strrep('0',64);p},
    function(p){p$source_audit$sql<-'SELECT pg_sleep(100)';p},
    function(p){p$source_audit$kind<-'derived_report_totals';p},
    function(p){p$source_audit<-NULL;p})
  for(change in changes) {
    bad<-rehash(change(program))
    expect(function()executeCharacterizationSql(NULL,bad,function(...)NULL),'execution.invalid_program')
  }
  bad<-program;bad$program_sha256<-strrep('0',64)
  expect(function()executeCharacterizationSql(NULL,bad,function(...)NULL),'execution.invalid_program')
  invalid<-list(maxStageBytes=-1,maxAggregateRows=-1,maxAggregateBytes=-1,maxRowBytes=0,
    fetchSize=0,statementTimeoutMs=0,maxElapsedSeconds=0)
  for(name in names(invalid)) {
    options<-stats::setNames(list(invalid[[name]]),name)
    expect(function()do.call(executeCharacterizationSql,c(list(NULL,program,function(...)NULL),options)),'execution.invalid_limits')
  }
  for(value in list(NA_real_,Inf,'1',c(1,2)))
    expect(function()executeCharacterizationSql(NULL,program,function(...)NULL,maxAggregateRows=value),'execution.invalid_limits')
  expect(function()executeCharacterizationSql(NULL,program,NULL),'execution.invalid_limits')
  expect(function()executeCharacterizationSql(NULL,program,function(...)NULL,check=TRUE),'execution.invalid_limits')
  # A minimal preconnect type stub avoids JDBC discovery entirely. The sentinel
  # would reject any accidental attempt to use it as real connection details.
  details<-structure(list(dbms='postgresql'),class='ConnectionDetails')
  expect(function()executeCharacterizationSql(details,program,function(...)NULL,check=function()FALSE),'execution.cancelled')
  expect(function()executeCharacterizationSql(details,program,function(...)NULL,check=function()
    stop(structure(list(message='private cancellation sentinel',call=NULL),class=c('interrupt','condition')))),'execution.cancelled')
  # A deterministic elapsed clock verifies the whole-call budget without a
  # timing-sensitive sleep or an actual connection. Namespace bindings stay intact.
  execute<-executeCharacterizationSql;scope<-new.env(parent=environment(execute));ticks<-0L
  scope$proc.time<-function() {
    ticks<<-ticks+1L
    structure(c(user.self=0,sys.self=0,elapsed=ticks*2,user.child=0,sys.child=0),class='proc_time')
  }
  environment(execute)<-scope
  expect(function()execute(details,program,function(...)NULL,maxElapsedSeconds=1),'execution.elapsed_limit')
  stopifnot(attempts==0L)
  cat('EXECUTOR_REHASHED_TAMPERING_LIMITS_PRECONNECT_CANCELLATION_AND_DEADLINE_OK\n')

  # Fixed-shape conservation metadata preserves exact count strings above 2^53.
  o<-f('.object');audit<-o(population=o(person_count='9007199254740993',nonnull='9007199254740993',
    distinct='9007199254740993',raw_observation_count='7',merged_interval_count='3'),
    domains=stats::setNames(lapply(f('.domain_names')(TRUE),function(domain)
      o(raw='8',linked='6',observed='4',start='0001-01-01',end='9999-12-31')),f('.domain_names')(TRUE)))
  checked<-f('.sql_execution_audit_totals')
  stopifnot(identical(wire(checked(wire(audit))),wire(audit)))
  zero<-audit;zero$population<-o(person_count='0',nonnull='0',distinct='0',raw_observation_count='0',merged_interval_count='0')
  zero$domains<-lapply(zero$domains,function(d)o(raw='0',linked='0',observed='0',start=NULL,end=NULL))
  stopifnot(identical(wire(checked(wire(zero))),wire(zero)))
  mutations<-list(
    function(a){a$extra<-'x';a},function(a){a$population$person_count<-'01';a},
    function(a){a$population$nonnull<-'0';a},function(a){a$population$distinct<-NULL;a},
    function(a){a$population$merged_interval_count<-'8';a},function(a){a$domains<-a$domains[-1];a},
    function(a){a$domains$other<-a$domains[[1]];a},function(a){a$domains[[1]]$raw<-8;a},
    function(a){a$domains[[1]]$linked<-'9';a},function(a){a$domains[[1]]$observed<-'7';a},
    function(a){a$domains[[1]]$raw<-'0';a},function(a){a$domains[[1]]$start<-NULL;a},
    function(a){a$domains[[1]]$end<-'0000-01-01';a},
    function(a){a$domains[[1]]$start<-'2025-02-01';a$domains[[1]]$end<-'2025-01-31';a},
    function(a){a$population$person_count<-'0';a$population$nonnull<-'0';a$population$distinct<-'0';a})
  for(change in mutations)expect(function()checked(wire(change(audit))),'execution.invalid_metadata')
  for(text in c('not JSON','null','[]'))expect(function()checked(text),'execution.invalid_metadata')
  cat('EXECUTOR_INDEPENDENT_SOURCE_AUDIT_FIXED_SHAPE_EXACT_COUNTS_AND_REJECTIONS_OK\n')

  # Faults at the public executor's cleanup seam need no server or JVM. The
  # actual failure path submits its first SQL through the real transport, while
  # a lexical dependency stub reaches successful work without a fabricated142-row
  # database. The executor body and its cleanup/on.exit lifecycle stay unchanged.
  if(!methods::isClass('AchillesCleanupTestConnection'))
    methods::setClass('AchillesCleanupTestConnection',slots=c(jConnection='environment'))
  cleanupTrial<-function(workSucceeds,rollbackFailures,disconnectFailures,code,sequence) {
    previous<-list(connect=get('connect',asNamespace('DatabaseConnector')),
      disconnect=get('disconnect',asNamespace('DatabaseConnector')),jcall=get('.jcall',asNamespace('rJava')))
    on.exit({assignInNamespace('connect',previous$connect,ns='DatabaseConnector')
      assignInNamespace('disconnect',previous$disconnect,ns='DatabaseConnector')
      assignInNamespace('.jcall',previous$jcall,ns='rJava')},add=TRUE)
    jdbc<-new.env(parent=emptyenv());statement<-new.env(parent=emptyenv())
    connection<-methods::new('AchillesCleanupTestConnection',jConnection=jdbc)
    submitted<-NULL;events<-character();rollbacks<-0L;disconnects<-0L;connections<-0L;workCalls<-0L;visits<-0L
    assignInNamespace('connect',function(...) {connections<<-connections+1L;connection},ns='DatabaseConnector')
    assignInNamespace('disconnect',function(con,...) {
      stopifnot(identical(con,connection));disconnects<<-disconnects+1L
      events<<-c(events,paste0('disconnect',disconnects))
      if(disconnects<=disconnectFailures)stop('private disconnect credential sentinel')
      invisible(NULL)
    },ns='DatabaseConnector')
    assignInNamespace('.jcall',function(obj,returnSig='V',method,...) {
      if(identical(method,'rollback')) {
        stopifnot(identical(obj,jdbc));rollbacks<<-rollbacks+1L
        events<<-c(events,paste0('rollback',rollbacks))
        if(rollbacks<=rollbackFailures)stop('private rollback credential sentinel')
        return(invisible(NULL))
      }
      if(method%in%c('setAutoCommit','setReadOnly','setTransactionIsolation'))return(invisible(NULL))
      if(identical(method,'createStatement'))return(statement)
      if(method%in%c('setQueryTimeout','cancel','close'))return(invisible(NULL))
      if(identical(method,'execute')) {
        submitted<<-list(...)[[1L]]
        workCalls<<-workCalls+1L
        stop('private SQL credential sentinel')
      }
      stop('private unexpected JDBC sentinel')
    },ns='rJava')
    execute<-executeCharacterizationSql
    if(workSucceeds) {
      scope<-new.env(parent=environment(execute));tiny<-program;tiny$steps<-list();tiny$outputs<-list()
      scope$.sql_execution_program<-function(...)tiny
      scope$.core_metadata_ids<-function()character()
      scope$.core_probes<-function()character()
      scope$.core_capabilities<-function(...)list(schema_sha256=strrep('0',64),values=list())
      scope$.sql_execution_transport<-function(...)list(
        execute=function(...){workCalls<<-workCalls+1L;invisible(NULL)},
        one=function(...)wire(zero),stream=function(...)invisible(NULL),telemetry=function()f('.object')())
      environment(execute)<-scope
    }
    result<-tryCatch(execute(details,program,function(...){visits<<-visits+1L}),error=identity,interrupt=identity)
    stopifnot(connections==1L,workCalls>=1L,visits==0L,identical(events,sequence))
    if(!workSucceeds)stopifnot(startsWith(submitted,"/* AchillesNext executor.statement_timeout */ SET LOCAL statement_timeout="))
    if(is.null(code))stopifnot(is.list(result),!inherits(result,'condition'),result$state=='succeeded',
      result$cleanup$transaction=='rolled_back',result$cleanup$connection=='disconnected') else {
      stopifnot(inherits(result,'AchillesSqlExecutionFailure'),identical(result$reason_code,code),
        is.null(result$call),is.null(result$parent))
      diagnostic<-as.character(jsonlite::toJSON(unclass(result),auto_unbox=TRUE,null='null'))
      for(sentinel in c('private disconnect credential sentinel','private rollback credential sentinel',
        'private SQL credential sentinel','private unexpected JDBC sentinel'))
        stopifnot(!grepl(sentinel,diagnostic,fixed=TRUE))
    }
    invisible(TRUE)
  }
  cleanupTrial(FALSE,0,0,'execution.query_failed',c('rollback1','disconnect1'))
  cleanupTrial(FALSE,0,1,'execution.cleanup_failed',c('rollback1','disconnect1','disconnect2'))
  cleanupTrial(FALSE,1,1,'execution.cleanup_failed',c('rollback1','disconnect1','rollback2','disconnect2'))
  cleanupTrial(FALSE,Inf,0,'execution.cleanup_failed',c('rollback1','disconnect1','rollback2'))
  cleanupTrial(FALSE,Inf,Inf,'execution.cleanup_failed',c('rollback1','disconnect1','rollback2','disconnect2'))
  cleanupTrial(TRUE,0,0,NULL,c('rollback1','disconnect1'))
  cleanupTrial(TRUE,0,1,'execution.cleanup_failed',c('rollback1','disconnect1','disconnect2'))
  cleanupTrial(TRUE,0,Inf,'execution.cleanup_failed',c('rollback1','disconnect1','disconnect2'))
  stopifnot(attempts==0L)
  cat('EXECUTOR_PUBLIC_CLEANUP_TRANSIENT_PERMANENT_RETRY_BOTH_ACTIONS_AND_SANITIZATION_OK\n')
})
