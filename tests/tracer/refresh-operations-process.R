# Bounded process/barrier helpers, shared only by the synthetic operations proof.
operationProcesses<-function(folder,config,source,sourceId,results,serving) {
  jobs<-list();script<-normalizePath('tests/tracer/refresh-operations-worker.R',mustWork=TRUE)
  atomic<-function(value,path) {
    tmp<-paste0(path,'.tmp');writeLines(jsonlite::toJSON(value,auto_unbox=TRUE,null='null'),tmp,useBytes=TRUE)
    stopifnot(file.rename(tmp,path))
  }
  ownedPid<-function(ctx) {
    if(!file.exists(ctx$pid_file))return(NULL)
    pid<-jsonlite::fromJSON(ctx$pid_file)
    stopifnot(is.character(pid),length(pid)==1L,grepl('^[1-9][0-9]*$',pid))
    command<-suppressWarnings(system2('ps',c('-p',pid,'-o','args='),stdout=TRUE,stderr=FALSE))
    # A dead child PID might have been reused. Signal only our exact script and
    # context path, never an arbitrary process sharing that number.
    if(!any(grepl(script,command,fixed=TRUE)&grepl(ctx$context_file,command,fixed=TRUE)))return(NULL)
    as.integer(pid)
  }
  stopAll<-function() {
    # Give cooperative cleanup time, then terminate only exact owned children.
    for(phase in list(c(2L,10),c(15L,5),c(9L,5))) {
      live<-Filter(function(ctx)!is.null(ownedPid(ctx)),jobs)
      if(!length(live))return(invisible(NULL))
      for(ctx in live){pid<-ownedPid(ctx);if(!is.null(pid))try(tools::pskill(pid,signal=phase[1]),silent=TRUE)}
      start<-proc.time()[['elapsed']]
      repeat {
        live<-Filter(function(ctx)!is.null(ownedPid(ctx)),jobs)
        if(!length(live))return(invisible(NULL))
        if(proc.time()[['elapsed']]-start>phase[2])break
        Sys.sleep(0.05)
      }
    }
    stop('Fixture children did not stop')
  }
  waitFile<-function(path,seconds=180) {
    start<-proc.time()[['elapsed']]
    while(!file.exists(path)) {
      if(proc.time()[['elapsed']]-start>seconds)stop(paste('Fixture process timed out waiting for',basename(path)))
      Sys.sleep(0.02)
    }
    jsonlite::fromJSON(path,simplifyVector=FALSE)
  }
  start<-function(id,action='refresh',pauseAt=3L,publicationId=NULL,expectedRevision=NULL) {
    stopifnot(grepl('^[a-z][a-z0-9-]+$',id));dir<-file.path(folder,id);stopifnot(dir.create(dir,mode='0700'))
    ctx<-list(config=normalizePath(config,mustWork=TRUE),source=source,source_id=sourceId,results=results,serving=serving,
      app=paste0('achilles_ops_',Sys.getpid(),'_',gsub('-','_',id)),action=action,pause_at=pauseAt,
      publication_id=publicationId,expected_revision=expectedRevision,context_file=file.path(dir,'context.json'),
      pid_file=file.path(dir,'pid.json'),ready_file=file.path(dir,'ready.json'),release_file=file.path(dir,'release.json'),result_file=file.path(dir,'result.json'))
    atomic(ctx,ctx$context_file);jobs[[id]]<<-ctx
    status<-system2(file.path(R.home('bin'),'Rscript'),c('--vanilla',shQuote(script),shQuote(ctx$context_file)),
      stdout=file.path(dir,'stdout.log'),stderr=file.path(dir,'stderr.log'),wait=FALSE)
    stopifnot(status==0L);ctx
  }
  list(start=start,ready=function(ctx)waitFile(ctx$ready_file,90),release=function(ctx)atomic(TRUE,ctx$release_file),
    result=function(ctx)waitFile(ctx$result_file),stop=stopAll,
    assertStopped=function(){stopAll();stopifnot(all(vapply(jobs,function(ctx)is.null(ownedPid(ctx)),TRUE)))})
}
