# Separate R/JVM processes: never fork a live JDBC connection.
args<-commandArgs(TRUE);stopifnot(length(args)==1L)
ctx<-jsonlite::fromJSON(args[1],simplifyVector=FALSE)
save<-function(value,path) {
  tmp<-paste0(path,'.tmp');writeLines(jsonlite::toJSON(value,auto_unbox=TRUE,null='null',digits=NA),tmp,useBytes=TRUE)
  stopifnot(file.rename(tmp,path))
}
save(as.character(Sys.getpid()),ctx$pid_file)
library(AchillesNext)
e<-new.env();sys.source(ctx$config,e)
base<-e$fixtureConnection(if(ctx$action=='promote')'owner' else 'runner')
details<-DatabaseConnector::createConnectionDetails(dbms=base$dbms,server=base$server(),port=base$port(),
  user=base$user(),password=base$password(),extraSettings=paste0('ApplicationName=',ctx$app))
barrier<-function(ticks) {
  save(list(ticks=ticks,pid=as.character(Sys.getpid())),ctx$ready_file)
  start<-proc.time()[['elapsed']]
  while(!file.exists(ctx$release_file)) {
    if(proc.time()[['elapsed']]-start>120)stop('Fixture barrier timed out')
    Sys.sleep(0.02)
  }
}
outcome<-tryCatch({
  if(ctx$action=='refresh') {
    p<-planCharacterizationRefresh(ctx$source,ctx$source_id,ctx$results,ctx$serving,'5.5')
    ticks<-0L
    value<-executeCharacterizationRefresh(details,p,check=function(){ticks<<-ticks+1L;if(ticks==ctx$pause_at)barrier(ticks)})
    list(ok=TRUE,value=value,ticks=ticks)
  } else {
    stopifnot(ctx$action=='promote');barrier(0L)
    list(ok=TRUE,revision=promoteResultPublication(details,ctx$results,ctx$publication_id,ctx$expected_revision))
  }
},error=function(e)list(ok=FALSE,kind='error',message=conditionMessage(e)),
  interrupt=function(e)list(ok=FALSE,kind='interrupt',message=conditionMessage(e)))
save(outcome,ctx$result_file)
