# Failure injection wraps real source capture/store transactions. Every injected
# exception carries a private sentinel that public diagnostics must discard.
testCharacterizationCandidateSqlFailures<-function(sourceDetails,program,storeDetails,results,out,
  f,patch,ex,q,qualified,tableCounts,prior,sourceRole,sourceSchema) {
  wire<-f('.json');lit<-f('.store_literal');codes<-list();partial<-0L;flushed<-FALSE
  baseline<-sort(list.files(out,all.files=TRUE,no..=TRUE));tempBefore<-q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N
  # Fault bindings are part of the compiler's runtime identity. Recompile under
  # each installed mock, so the normal reconstruction guard remains enabled.
  columns<-do.call(rbind,lapply(program$declarations$columns,function(x)as.data.frame(x,stringsAsFactors=FALSE)))
  invoke<-function(...) {
    current<-renderCharacterizationSql(sourceSchema,program$batch$source$source_id,program$batch$source$declared_cdm_version,
      columns,numericStrategy=program$declarations$numeric_strategy,stagePrefix=program$declarations$stage_prefix)
    generateCharacterizationCandidateFromSql(sourceDetails,current,storeDetails,results,scratchParent=out,...)
  }
  expect<-function(name,work,allowed,committed=FALSE) {
    before<-tableCounts();error<-tryCatch({work();NULL},error=identity,interrupt=identity)
    stopifnot(inherits(error,'AchillesCandidateFailure'),error$reason_code%in%allowed,
      is.null(error$call),is.null(error$parent),!grepl('private_',conditionMessage(error),fixed=TRUE),
      identical(error$publication_changed,FALSE))
    diagnostic<-wire(unclass(error))
    for(secret in c(sourceDetails$password(),storeDetails$password()))
      stopifnot(!grepl(secret,diagnostic,fixed=TRUE))
    if(!committed)stopifnot(identical(before,tableCounts()),error$outcome=='not_committed')
    stopifnot(identical(baseline,sort(list.files(out,all.files=TRUE,no..=TRUE))),
      q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==tempBefore)
    prior();codes[[name]]<<-error$reason_code;error
  }
  execute<-get('executeCharacterizationSql',asNamespace('AchillesNext'))
  # Early readiness failure must not run any source query.
  calls<-0L
  ex(paste0('REVOKE INSERT ON ',qualified('source_release'),' FROM ',storeDetails$user()))
  expect('store_readiness',function()patch('executeCharacterizationSql',function(...){calls<<-calls+1L;stop('private_source_called')},
    function()invoke()),'candidate.store_unavailable')
  ex(paste0('GRANT INSERT ON ',qualified('source_release'),' TO ',storeDetails$user()));stopifnot(calls==0L)
  expect('scratch_bytes',function()invoke(maxScratchBytes=0),'candidate.scratch_byte_limit')
  expect('source_stage_limit',function()invoke(maxStageBytes=0),c('candidate.invalid_capture','candidate.source_failed'))
  expect('before_capture_cancel',function()invoke(check=function()FALSE),'candidate.cancelled')
  # Fail inside the actual source callback only after rows reached the capture.
  expect('partial_capture',function()patch('executeCharacterizationSql',function(sourceConnectionDetails,program,visit,...) {
    execute(sourceConnectionDetails,program,function(mid,row) {
      visit(mid,row);partial<<-partial+1L
      if(partial==3L)stop('private_partial_capture_sentinel')
    },...)
  },function()invoke()),c('candidate.invalid_capture','candidate.source_failed'))
  stopifnot(partial==3L)
  # The executor's real blocked-query timeout is already covered by its own
  # harness. Here prove exact forwarding and bridge cleanup of that failure.
  forwarded<-NULL
  timeoutError<-expect('query_timeout_forwarding',function()patch('executeCharacterizationSql',function(...) {
    forwarded<<-list(...)
    stop(structure(list(message='private_timeout_query_sentinel',call=NULL,reason_code='execution.query_failed'),
      class=c('AchillesSqlExecutionFailure','error','condition')))
  },function()invoke(maxStageBytes=32*1024^2,maxAggregateRows=9999L,maxAggregateBytes=16*1024^2,
    maxRowBytes=8192L,fetchSize=17L,statementTimeoutMs=1234L,maxElapsedSeconds=1200)), 'candidate.source_failed')
  stopifnot(identical(timeoutError$cause_code,'execution.query_failed'),forwarded$maxStageBytes==32*1024^2,
    forwarded$maxAggregateRows==9999L,forwarded$maxAggregateBytes==16*1024^2,forwarded$maxRowBytes==8192L,
    forwarded$fetchSize==17L,forwarded$statementTimeoutMs==1234L,forwarded$maxElapsedSeconds>0,
    forwarded$maxElapsedSeconds<=1200,is.function(forwarded$check))
  disconnect<-get('disconnect',asNamespace('DatabaseConnector'));disconnects<-0L
  cleanupError<-expect('source_cleanup_failure',function()patch('executeCharacterizationSql',function(...) {
    arguments<-list(...)
    patch('disconnect',function(connection) {
      disconnect(connection);disconnects<<-disconnects+1L;stop('private_source_disconnect_sentinel')
    },function()do.call(execute,arguments),namespace='DatabaseConnector')
  },function()invoke()),'candidate.source_failed')
  stopifnot(disconnects>=2L,identical(cleanupError$cause_code,'execution.cleanup_failed'))
  capture<-f('.candidate_capture')
  # Missing targets and replay cancellation happen after successful source
  # cleanup and after entering the result-store transaction.
  expect('missing_denominator',function()patch('.candidate_capture',function(...) {
    value<-capture(...);value$lookup<-function(...)stop('private_missing_target_sentinel');value
  },function()invoke()),c('candidate.invalid_capture','candidate.store_failed'))
  replayed<-0L
  expect('replay_cancel',function()patch('.candidate_capture',function(...) {
    value<-capture(...);replay<-value$replay
    value$replay<-function(mid,visit)replay(mid,function(row) {
      visit(row);replayed<<-replayed+1L
      if(replayed==3L)stop(structure(list(message='private_replay_interrupt'),class=c('interrupt','condition')))
    });value
  },function()invoke()),'candidate.cancelled')
  stopifnot(replayed==3L)
  # A fixed-size audit disagreement is independent of report agreement and must
  # fail the same conservation checks as the old producer, before commit.
  expect('source_audit_mismatch',function()patch('executeCharacterizationSql',function(...) {
    value<-execute(...);value$audit_totals$domains$measurement$raw<-f('.nv_add')(value$audit_totals$domains$measurement$raw,'1');value
  },function()invoke()),c('candidate.invalid_capture','candidate.store_failed'))
  expect('receipt_count_mismatch',function()patch('executeCharacterizationSql',function(...) {
    value<-execute(...);value$metric_rows[['core.person.count']]<-'2';value
  },function()invoke()),'candidate.invalid_capture')
  writeFile<-f('.v2_scratch_file');ioInjected<-FALSE
  expect('control_disk_io',function()patch('.v2_scratch_file',function(...) {
    if(!ioInjected){ioInjected<<-TRUE;f('.v2_scratch_error')('io_failure')};writeFile(...)
  },function()invoke()),'candidate.scratch_io_failure');stopifnot(ioInjected)
  writer<-f('.store_writer')
  expect('partial_store_write',function()patch('.store_writer',function(...) {
    value<-writer(...);flush<-value$flush
    value$flush<-function() {flush();flushed<<-TRUE;stop('private_store_flush_sentinel')};value
  },function()invoke()),'candidate.store_failed');stopifnot(flushed)
  cleaned<-FALSE
  expect('required_scratch_cleanup',function()patch('.candidate_capture',function(...) {
    value<-capture(...);cleanup<-value$cleanup
    value$cleanup<-function(){cleanup();if(!cleaned){cleaned<<-TRUE;stop('private_cleanup_sentinel')}};value
  },function()invoke()),'candidate.cleanup_failed');stopifnot(cleaned)
  # A commit may succeed while its acknowledgement is lost. The public error
  # identifies the resulting unpublished candidate; it cannot promise rollback.
  commit<-f('.store_commit');ackInjected<-FALSE
  error<-expect('commit_acknowledgement_lost',function()patch('.store_commit',function(jdbc) {
    commit(jdbc);ackInjected<<-TRUE;stop('private_commit_ack_sentinel')
  },function()invoke()),'candidate.commit_unknown',committed=TRUE)
  stopifnot(ackInjected,error$outcome=='unknown')
  for(key in c('attempt_id','run_id','source_release_id','release_id'))
    stopifnot(is.character(error[[key]]),grepl('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',error[[key]]))
  diagnostic<-q(paste0('SELECT r.state,a.state AS run_state, (a.reusable_input_identity IS NULL)::text AS unknown FROM ',qualified('result_release'),
    ' r JOIN ',qualified('analysis_run'),' a USING(run_id) WHERE r.release_id=',lit(error$release_id),' AND a.run_id=',lit(error$run_id),
    ' AND a.source_release_id=',lit(error$source_release_id)))
  stopifnot(nrow(diagnostic)==1L,diagnostic$STATE=='building',diagnostic$RUN_STATE=='succeeded',diagnostic$UNKNOWN=='true')
  prior()
  result<-list(status='passed',cases=codes,partial_capture_rows=partial,partial_store_flush=flushed,
    source_cleanup=TRUE,scratch_cleanup=TRUE,previous_publication_preserved=TRUE,
    commit_acknowledgement=list(reason_code=error$reason_code,outcome=error$outcome,release_id=error$release_id,
      diagnostic_candidate_state='building',automatic_promotion=FALSE))
  writeLines(wire(result),file.path(out,'bridge-failures.json'),useBytes=TRUE)
  cat('CANDIDATE_SQL_FAILURES_ROLLBACK_PRIOR_PUBLICATION_AND_COMMIT_UNKNOWN_OK\n');result
}
