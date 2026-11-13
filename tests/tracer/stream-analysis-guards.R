# Fast regression checks for the exact guards used by the compact R proof.
source('tools/benchmark/stream_analysis_guards.R')
local({
  refuses<-function(work,pattern=NULL) {
    error<-tryCatch({work();NULL},error=identity)
    stopifnot(inherits(error,'error'))
    if(!is.null(pattern))stopifnot(grepl(pattern,conditionMessage(error),fixed=TRUE))
  }
  root<-tempfile();dir.create(root);on.exit(unlink(root,recursive=TRUE),add=TRUE)
  streamCheckSource(root)
  for(name in c('STOP','dropped.json','active','active.json')) {
    control<-file.path(root,name)
    stopifnot(file.symlink(file.path(root,'missing'),control),!file.exists(control))
    refuses(function()streamCheckSource(root));unlink(control)
    stopifnot(file.create(control));refuses(function()streamCheckSource(root));unlink(control)
  }
  streamCheckSource(root)
  handoff<-list(source_schema=paste0('cdm_stream_',paste(rep('a',16),collapse='')),table_rows=list(person=2L,measurement=0L))
  observed<-list(usage='true',create='false',select='true',person='2',measurement='0')
  query<-function(sql) {
    if(grepl('has_schema_privilege',sql,fixed=TRUE))return(list(CAN_READ=observed$usage,CAN_CREATE=observed$create))
    table<-if(grepl('"person"',sql,fixed=TRUE))'person' else 'measurement'
    list(N=observed[[table]],CAN_READ=observed$select)
  }
  facts<-streamVerifySource(handoff,query)
  stopifnot(identical(facts$table_rows,list(person='2',measurement='0')))
  patterns<-c(usage='identical(grants$CAN_READ, "true")',create='identical(grants$CAN_CREATE, "false")',
    select='identical(facts$CAN_READ, "true")',person='identical(facts$N, as.character(handoff$table_rows[[table]]))',
    measurement='identical(facts$N, as.character(handoff$table_rows[[table]]))')
  for(field in names(observed)) {
    original<-observed[[field]];observed[[field]]<-switch(field,usage='false',create='true',select='false',person='3',measurement='1')
    refuses(function()streamVerifySource(handoff,query),patterns[[field]]);observed[[field]]<-original
  }
  invalid<-handoff;invalid$source_schema<-'public; SELECT 1'
  refuses(function()streamVerifySource(invalid,function(sql)stop('Unexpected query before schema validation')),
    'grepl("^cdm_stream_[0-9a-f]{16}$", schema)')
  invalid<-handoff;names(invalid$table_rows)[1]<-'person; SELECT 1';queries<-character()
  recordingQuery<-function(sql){queries<<-c(queries,sql);query(sql)}
  refuses(function()streamVerifySource(invalid,recordingQuery),'grepl("^[a-z][a-z0-9_]*$", table)')
  stopifnot(length(queries)==1L,grepl('has_schema_privilege',queries[[1]],fixed=TRUE))
  calls<-character()
  actions<-list(function(){calls<<-c(calls,'rollback');stop('rollback denied')},
    function(){calls<<-c(calls,'disconnect')},function(){calls<<-c(calls,'revoke');stop('revoke denied')})
  # Even warn=2 must not replace the original analysis failure.
  previous<-options(warn=2);on.exit(options(previous),add=TRUE)
  fail<-function() {
    on.exit(streamCleanup(actions,FALSE),add=TRUE)
    stop('original analysis failure')
  }
  log<-capture.output(refuses(fail,'original analysis failure'),type='message')
  stopifnot(identical(calls,c('rollback','disconnect','revoke')),any(grepl('rollback denied; revoke denied',log,fixed=TRUE)))
  calls<-character();refuses(function()streamCleanup(actions,TRUE),'rollback denied; revoke denied')
  stopifnot(identical(calls,c('rollback','disconnect','revoke')))
  streamCleanup(list(function()NULL),TRUE)
  cat('STREAM_ANALYSIS_GUARDS_PASS\n')
})
