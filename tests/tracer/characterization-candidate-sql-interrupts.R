# Self-SIGINT reaches ordinary R ownership boundaries without any database.
# Cooperative callbacks alone would miss interruption after a resource returns.
testCharacterizationCandidateInterrupts<-function(program,details) {
  if(.Platform$OS.type=='windows')return(invisible(NULL))
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object')
  root<-tempfile('candidate-interrupt-proof-');stopifnot(dir.create(root,mode='0700'))
  on.exit(unlink(root,recursive=TRUE),add=TRUE)
  signal<-function(){stopifnot(tools::pskill(Sys.getpid(),2L));invisible(NULL)}
  baseCapture<-f('.candidate_capture');baseSpool<-f('.v2_spool')
  originalConnections<-nrow(showConnections(all=TRUE))
  person<-o(metric_id='core.person.count',row_kind='counts',dimensions=o(),values=o(person_count='1'),state='computed',reason_code=NULL)
  for(seam in c('capture_return','spool_return','row_file_open','committed_return')) {
    execute<-generateCharacterizationCandidateFromSql;scope<-new.env(parent=environment(execute))
    scope$.candidate_store_transaction<-function(details,schema,work,limits,tick,ids,readOnly=FALSE,state=NULL) {
      if(readOnly)return(list(value=NULL,telemetry=o()))
      stopifnot(seam=='committed_return',is.environment(state));state$outcome<-'committed'
      signal();Sys.sleep(0.1);stop('private_interrupt_not_delivered')
    }
    scope$executeCharacterizationSql<-function(connectionDetails,program,visit,...) {
      if(seam=='committed_return')return(list())
      visit(person$metric_id,person);stop('private_capture_interrupt_not_delivered')
    }
    if(seam=='capture_return')scope$.candidate_capture<-function(...) {value<-baseCapture(...);signal();value}
    if(seam=='spool_return') {
      capture<-baseCapture;spoolScope<-new.env(parent=environment(capture))
      spoolScope$.v2_spool<-function(...) {value<-baseSpool(...);signal();value}
      environment(capture)<-spoolScope;scope$.candidate_capture<-capture
    }
    if(seam=='row_file_open') {
      capture<-baseCapture;fileScope<-new.env(parent=environment(capture))
      fileScope$file<-function(description='',open='',...) {
        value<-base::file(description,open,...)
        if(identical(open,'ab'))signal()
        value
      }
      environment(capture)<-fileScope;scope$.candidate_capture<-capture
    }
    if(seam=='committed_return')scope$.candidate_capture<-function(...)list(visit=function(...)NULL,complete=function(...)NULL,cleanup=function()NULL)
    environment(execute)<-scope
    error<-tryCatch({execute(details,program,details,'results',scratchParent=root);NULL},error=identity,interrupt=identity)
    cat('CANDIDATE_SELF_SIGINT_SEAM ',seam,' ',error$reason_code,' ',error$outcome,'\n',sep='')
    stopifnot(inherits(error,'AchillesCandidateFailure'),error$reason_code=='candidate.cancelled',
      identical(error$outcome,if(seam=='committed_return')'committed' else 'not_committed'),
      !grepl('private_',conditionMessage(error),fixed=TRUE),is.null(error$call),is.null(error$parent),
      identical(error$publication_changed,FALSE),length(list.files(root,all.files=TRUE,no..=TRUE))==0L,
      nrow(showConnections(all=TRUE))==originalConnections)
    if(seam=='committed_return')for(key in c('attempt_id','run_id','source_release_id','release_id'))
      stopifnot(is.character(error[[key]]),grepl('^[0-9a-f-]{36}$',error[[key]]))
  }
  cat('CANDIDATE_SELF_SIGINT_CONSTRUCTOR_FILE_OWNERSHIP_AND_COMMITTED_OUTCOME_OK\n')
}
