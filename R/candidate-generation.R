#' Build a complete restricted candidate from a checked source SQL program
#' @export
generateCharacterizationCandidateFromSql <- function(sourceConnectionDetails,program,storeConnectionDetails,resultsSchema,
  maxScratchBytes=1024^3,scratchParent=tempdir(),maxStageBytes=64*1024^2,maxAggregateRows=1000000L,
  maxAggregateBytes=256*1024^2,maxRowBytes=131072L,fetchSize=128L,statementTimeoutMs=30000L,
  maxElapsedSeconds=3600,check=NULL) {
  clock<-proc.time();wall<-function()proc.time()[["elapsed"]];started<-wall();ids<-NULL;capture<-NULL;captureFailure<-NULL
  validation<-.v2_scratch_capture(function() {
    program<-.sql_execution_program(program)
    limits<-.sql_execution_limits(maxStageBytes,maxAggregateRows,maxAggregateBytes,maxRowBytes,fetchSize,
      statementTimeoutMs,maxElapsedSeconds,function(...)NULL,check)
    .v2_scratch_limit(maxScratchBytes)
    .candidate_need(inherits(sourceConnectionDetails,"ConnectionDetails")&&identical(sourceConnectionDetails$dbms,"postgresql")&&
      inherits(storeConnectionDetails,"ConnectionDetails")&&identical(storeConnectionDetails$dbms,"postgresql"),"candidate.invalid_limits")
    .candidate_need(.batch_identifier(resultsSchema)&&!resultsSchema%in%c("public","information_schema")&&
      !startsWith(resultsSchema,"pg_")&&resultsSchema!=program$batch$source$cdm_schema,"candidate.invalid_limits")
    .candidate_need(.string(scratchParent)&&dir.exists(scratchParent),"candidate.invalid_limits")
    list(program=program,limits=limits,parent=normalizePath(scratchParent,mustWork=TRUE))
  })
  if(!validation$ok) {
    cause<-validation$failure
    if(inherits(cause,"interrupt")).candidate_error("candidate.cancelled")
    .candidate_error(if(inherits(cause,"AchillesSqlExecutionFailure")&&cause$reason_code=="execution.invalid_program")
      "candidate.invalid_program" else "candidate.invalid_limits")
  }
  program<-validation$value$program;limits<-validation$value$limits
  storeOutcome<-new.env(parent=emptyenv());storeOutcome$outcome<-"not_committed"
  ids<-.object(attempt_id=.store_new_uuid(),run_id=.store_new_uuid(),source_release_id=.store_new_uuid(),release_id=.store_new_uuid())
  tick<-function() {
    .candidate_need(wall()-started<=maxElapsedSeconds,"candidate.elapsed_limit")
    if(!is.null(check)) {
      out<-.v2_scratch_capture(check)
      .candidate_need(out$ok&&!identical(out$value,FALSE),"candidate.cancelled")
      .candidate_need(wall()-started<=maxElapsedSeconds,"candidate.elapsed_limit")
    }
    invisible(TRUE)
  }
  cleanup<-function() {
    if(is.null(capture))return(TRUE)
    out<-.v2_scratch_capture(capture$cleanup);out$ok
  }
  on.exit(suspendInterrupts(cleanup()))
  result<-.v2_scratch_capture(function() {
    tick();assets<-.v2_assets()
    preflight<-.candidate_store_transaction(storeConnectionDetails,resultsSchema,function(tx).candidate_readiness(tx,assets),limits,tick,ids,TRUE,startedClock=started)
    budget<-.v2_scratch_budget(maxScratchBytes,maxFiles=512L)
    directory<-tempfile("achillesnext-candidate-",tmpdir=validation$value$parent)
    suspendInterrupts({capture<<-.candidate_capture(directory,assets,budget,tick);allowInterrupts(Sys.sleep(0))})
    receipt<-executeCharacterizationSql(sourceConnectionDetails,program,function(mid,item) {
      out<-.v2_scratch_capture(function()capture$visit(mid,item))
      if(!out$ok){captureFailure<<-out$failure;stop(out$failure)}
    },maxStageBytes=maxStageBytes,maxAggregateRows=maxAggregateRows,maxAggregateBytes=maxAggregateBytes,
      maxRowBytes=maxRowBytes,fetchSize=fetchSize,statementTimeoutMs=statementTimeoutMs,
      maxElapsedSeconds=max(0.001,maxElapsedSeconds-(wall()-started)),check=tick)
    tick();capture$complete(receipt,program)
    store<-.candidate_store_transaction(storeConnectionDetails,resultsSchema,function(tx) {
      persistence<-.candidate_import(tx,capture,receipt,program,ids,tick)
      stats<-capture$stats();.candidate_need(cleanup(),"candidate.cleanup_failed");tick()
      list(persistence=persistence,scratch=stats)
    },limits,tick,ids,state=storeOutcome,startedClock=started)
    tick()
    c(ids,.object(profile_id=assets$profile$profile_id,profile_sha256=assets$hash,state="building",
      generated_metrics=as.list(names(assets$metrics)),expected_metric_count="142",generated_metric_count="142",
      publishable=FALSE,profile_complete=TRUE,publication_changed=FALSE,source_store_separate=TRUE,
      source_receipt=receipt,persistence=store$value$persistence,scratch=store$value$scratch,
      telemetry=.object(client_call_wall_ms=.sql_execution_ms(wall()-started),
        client_process_cpu_ms=.sql_execution_ms(sum((proc.time()-clock)[c("user.self","sys.self")])),store_preflight=preflight$telemetry,
        store_persistence=store$telemetry,source_capture=receipt$telemetry)))
  })
  if(!result$ok) {
    failure<-if(!is.null(captureFailure))captureFailure else result$failure
    cleaned<-suspendInterrupts(cleanup())
    if(storeOutcome$outcome%in%c("unknown","committed")) {
      code<-if(storeOutcome$outcome=="unknown")"candidate.commit_unknown" else
        if(inherits(result$failure,"AchillesCandidateFailure"))result$failure$reason_code else
        if(inherits(result$failure,"interrupt"))"candidate.cancelled" else "candidate.post_commit_failed"
      .candidate_error(code,ids,storeOutcome$outcome)
    }
    if(inherits(result$failure,"AchillesCandidateFailure")&&result$failure$outcome%in%c("unknown","committed"))
      .candidate_error(result$failure$reason_code,ids,result$failure$outcome,result$failure$cause_code)
    code<-if(!cleaned)"candidate.cleanup_failed" else if(inherits(failure,"AchillesCandidateFailure"))failure$reason_code else
      if(inherits(failure,"achillesnext_scratch_error"))paste0("candidate.scratch_",failure$code) else
      if(inherits(failure,"interrupt"))"candidate.cancelled" else if(inherits(failure,"AchillesSqlExecutionFailure"))
        switch(failure$reason_code,execution.cancelled="candidate.cancelled",execution.elapsed_limit="candidate.elapsed_limit","candidate.source_failed") else "candidate.invalid_capture"
    cause<-if(inherits(failure,"AchillesSqlExecutionFailure"))failure$reason_code else NULL
    .candidate_error(code,ids,cause=cause)
  }
  result$value
}
