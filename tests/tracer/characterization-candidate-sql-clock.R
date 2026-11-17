# Real checked capture/import under a client clock independent of store TX time.
testCharacterizationCandidateSqlClock <- function(sourceDetails,storeDetails,results,schema,sourceId,version,columns,out,q,f,qualified) {
  original<-f('.stamp');calls<-character();offsetSeconds<-3600;clockMode<-'ahead';importStarted<-FALSE
  shifted<-function() {
    value<-format(as.POSIXct(original(),format="%Y-%m-%dT%H:%M:%OSZ",tz="UTC")+
      if(clockMode=='backward'&&importStarted)-offsetSeconds else offsetSeconds,
      "%Y-%m-%dT%H:%M:%OS3Z",tz="UTC")
    calls<<-c(calls,value);value
  }
  on.exit(assignInNamespace('.stamp',original,ns='AchillesNext'),add=TRUE)
  assignInNamespace('.stamp',shifted,ns='AchillesNext')
  # Compile after installing the clock seam: no program hash is forged and the
  # actual public executor/capture/import provide every source fact.
  program<-renderCharacterizationSql(schema,paste0(sourceId,':client-clock'),version,columns)
  candidate<-generateCharacterizationCandidateFromSql(sourceDetails,program,storeDetails,results,scratchParent=out)
  run<-q(paste0('SELECT started_at::text,finished_at::text,state,',
    '(finished_at>=started_at)::text AS ordered FROM ',qualified('analysis_run'),
    ' WHERE run_id=',f('.store_uuid')(candidate$run_id)))
  stopifnot(nrow(run)==1L,run$STATE=='succeeded',run$ORDERED=='true',length(calls)>=3L,
    candidate$source_receipt$generation$started_at%in%calls,
    candidate$source_receipt$generation$ended_at%in%calls,
    candidate$source_receipt$publication_changed==FALSE,candidate$publication_changed==FALSE)
  # Compare actual instants rather than server/client timestamp spellings.
  parse<-function(x)as.POSIXct(x,format="%Y-%m-%dT%H:%M:%OS",tz='UTC')
  start<-parse(sub('Z$','',candidate$source_receipt$generation$started_at))
  finish<-parse(sub('Z$','',tail(calls,1L)))
  exact<-q(paste0('SELECT (started_at=',f('.store_literal')(candidate$source_receipt$generation$started_at),
    '::timestamptz)::text AS started, (finished_at=',f('.store_literal')(tail(calls,1L)),
    '::timestamptz)::text AS finished FROM ',qualified('analysis_run'),
    ' WHERE run_id=',f('.store_uuid')(candidate$run_id)))
  stopifnot(exact$STARTED=='true',exact$FINISHED=='true',finish>=start)
  # A clock reversal AFTER the real source end must reject before the success
  # UPDATE, rather than depend on a server CHECK constraint or commit it.
  clockMode<-'backward';calls<-character();successUpdates<-0L;importVisits<-0L
  import<-f('.candidate_import');generate<-generateCharacterizationCandidateFromSql
  scope<-new.env(parent=environment(generate))
  scope$.candidate_import<-function(tx,capture,receipt,program,ids,tick) {
    importVisits<<-importVisits+1L;importStarted<<-TRUE;execute<-tx$execute
    tx$execute<-function(sql) {
      if(grepl('achillesnext_analysis_run SET state=',sql,fixed=TRUE))successUpdates<<-successUpdates+1L
      execute(sql)
    }
    import(tx,capture,receipt,program,ids,tick)
  }
  environment(generate)<-scope
  backwardProgram<-renderCharacterizationSql(schema,paste0(sourceId,':backward-clock'),version,columns)
  failed<-tryCatch({generate(sourceDetails,backwardProgram,storeDetails,results,scratchParent=out);NULL},error=identity)
  stopifnot(inherits(failed,'AchillesCandidateFailure'),failed$reason_code=='candidate.store_failed',
    failed$outcome=='not_committed',failed$publication_changed==FALSE,importVisits==1L,
    length(calls)>=3L,successUpdates==0L)
  absent<-q(paste0('SELECT count(*)::text AS n FROM ',qualified('analysis_run'),
    ' WHERE run_id=',f('.store_uuid')(failed$run_id)))
  stopifnot(absent$N=='0')
  list(candidate_run_id=candidate$run_id,client_ahead_seconds=offsetSeconds,
    backward_clock_rejected_before_success_update=TRUE,
    actual_checked_source_receipt=TRUE,run_bounds_match_client_facts=TRUE)
}
