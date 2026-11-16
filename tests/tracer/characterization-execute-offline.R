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
    function(p){p$declarations$columns_sha256<-strrep('0',64);p})
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
})
