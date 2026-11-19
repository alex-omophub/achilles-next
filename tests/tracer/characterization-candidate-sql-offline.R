# The optional bridge must reject bad requests before touching either endpoint.
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
  program<-renderCharacterizationSql('cdm','fixture:bridge-offline',input$version,columns)
  details<-structure(list(dbms='postgresql'),class='ConnectionDetails')
  connections<-0L;connect<-get('connect',asNamespace('DatabaseConnector'))
  on.exit(assignInNamespace('connect',connect,ns='DatabaseConnector'),add=TRUE)
  assignInNamespace('connect',function(...){connections<<-connections+1L;stop('private bridge connection sentinel')},ns='DatabaseConnector')
  call<-function(p=program,target='results',...)generateCharacterizationCandidateFromSql(details,p,details,target,...)
  expect<-function(work,codes) {
    error<-tryCatch({work();NULL},error=identity,interrupt=identity)
    stopifnot(inherits(error,'error'),error$reason_code%in%codes,connections==0L,
      !grepl('private bridge connection sentinel',conditionMessage(error),fixed=TRUE),
      is.null(error$call),is.null(error$parent))
  }
  rehash<-function(p){p$program_sha256<-NULL;p$program_sha256<-f('.hash')(wire(p));p}
  bad<-program;bad$program_sha256<-strrep('0',64)
  expect(function()call(bad),'candidate.invalid_program')
  bad<-program;bad$steps[[1]]$sql<-'SELECT private_query_sentinel'
  expect(function()call(rehash(bad)),'candidate.invalid_program')
  for(target in c('cdm','public','pg_catalog','bad.schema','bad-name',''))
    expect(function()call(target=target),'candidate.invalid_limits')
  invalid<-list(transferStrategy='unknown',maxScratchBytes=-1,scratchParent=NA_character_,maxStageBytes=-1,maxAggregateRows=-1,
    maxAggregateBytes=-1,maxRowBytes=0,fetchSize=0,statementTimeoutMs=0,maxElapsedSeconds=0,check=TRUE)
  for(name in names(invalid)) {
    values<-stats::setNames(list(invalid[[name]]),name)
    expect(function()do.call(call,values),c('candidate.invalid_limits','execution.invalid_limits'))
  }
  for(value in list(NA_real_,Inf,'1',c(1,2)))
    expect(function()call(maxScratchBytes=value),'candidate.invalid_limits')
  expect(function()call(check=function()FALSE),'candidate.cancelled')
  expect(function()call(check=function()stop('private cancellation sentinel')),'candidate.cancelled')
  # A deterministic client clock exercises the whole-call deadline before JDBC.
  generate<-generateCharacterizationCandidateFromSql;scope<-new.env(parent=environment(generate));clock<-0L
  scope$proc.time<-function(){clock<<-clock+2L;structure(c(user.self=0,sys.self=0,elapsed=clock,user.child=0,sys.child=0),class='proc_time')}
  environment(generate)<-scope
  expect(function()generate(details,program,details,'results',maxElapsedSeconds=1),'candidate.elapsed_limit')
  stopifnot(connections==0L)
  # Local cleanup releases its own files even when the live store has a
  # separate temporary allocation charged against the same scratch limit.
  parent <- get(".v2_scratch_budget",asNamespace("AchillesNext"))(100,2)
  files <- get(".candidate_copy_file_budget",asNamespace("AchillesNext"))(parent)
  parent$acquire(60)
  files$acquire(40,1)
  overflow <- tryCatch(files$acquire(1),error=identity)
  stopifnot(inherits(overflow,"achillesnext_scratch_error"),overflow$code=="byte_limit",
    parent$inspect()$bytes==100,files$inspect()$bytes==40)
  files$release(40,1)
  stopifnot(parent$inspect()$bytes==60,parent$inspect()$files==0,files$inspect()$bytes==0,
    parent$inspect()$peak_bytes==100)
  copyQuery <- get(".pg_count_copy_query",asNamespace("AchillesNext"))
  for (count in c(1L,7L,128L)) {
    query <- copyQuery("core.person.count",NULL,TRUE,65536L,count)
    stopifnot(grepl(paste0("(pos-1)/",count,","),query,fixed=TRUE))
  }
  source('tests/tracer/characterization-candidate-sql-capture.R')
  testCharacterizationCandidateCapture(program)
  source('tests/tracer/characterization-candidate-sql-interrupts.R')
  testCharacterizationCandidateInterrupts(program,details)
  testCharacterizationCandidateCompletionLimits(program,details)
  testCharacterizationCandidateValidationInterrupt(program,details)
  testCharacterizationCandidateGlobalClock(program,details)
  testCharacterizationCandidateSourceConditions(program,details)
  testCharacterizationCandidateSourceWrappedCheck(program,details)
  testCharacterizationCandidateStoreTimeouts(details)
  cat('CANDIDATE_SQL_INVALID_PROGRAM_TARGET_LIMITS_AND_CANCEL_ZERO_CONNECTIONS_OK\n')
})
