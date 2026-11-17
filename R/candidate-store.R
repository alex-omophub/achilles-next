.candidate_error <- function(code,ids=NULL,outcome="not_committed",cause=NULL) {
  stop(structure(c(list(message=paste0("Candidate generation failed [",code,"]"),call=NULL,
    reason_code=code,outcome=outcome,publication_changed=FALSE,cause_code=cause),ids),
    class=c("AchillesCandidateFailure","error","condition")))
}
.candidate_need <- function(ok,code="candidate.invalid_capture") {
  if(!isTRUE(ok)).candidate_error(code)
  invisible(NULL)
}
# Own the commit boundary: a lost acknowledgement cannot prove rollback.
.candidate_store_transaction <- function(details,schema,work,limits,tick,ids,readOnly=FALSE,state=NULL,startedClock=NULL) {
  if(is.null(state))state<-new.env(parent=emptyenv())
  state$outcome<-"not_committed"
  connection<-NULL;jdbc<-NULL;rollbackConfirmed<-FALSE;disconnectConfirmed<-FALSE
  commitStarted<-FALSE;commitConfirmed<-FALSE
  cleanup<-function() {
    if(!rollbackConfirmed)rollbackConfirmed<<-is.null(jdbc)||isTRUE(tryCatch({rJava::.jcall(jdbc,"V","rollback");TRUE},error=function(e)FALSE,interrupt=function(e)FALSE))
    if(!disconnectConfirmed)disconnectConfirmed<<-is.null(connection)||isTRUE(tryCatch({DatabaseConnector::disconnect(connection);TRUE},error=function(e)FALSE,interrupt=function(e)FALSE))
    rollbackConfirmed&&disconnectConfirmed
  }
  on.exit(if(!disconnectConfirmed||!rollbackConfirmed)suspendInterrupts(cleanup()))
  wall<-function()proc.time()[["elapsed"]];started<-wall();writes<-0;sqlBytes<-0;writeWait<-0;reads<-0L;transport<-NULL
  if(is.null(startedClock))startedClock<-started
  timeout<-function()as.integer(max(1,min(ceiling(limits$statement_timeout_ms/1000),
    ceiling(limits$max_elapsed_seconds-(wall()-startedClock)))))
  outcome<-function()if(commitConfirmed)"committed" else if(commitStarted)"unknown" else "not_committed"
  captured<-.v2_scratch_capture(function() {
    tick()
    suspendInterrupts({connection<<-DatabaseConnector::connect(details);jdbc<<-connection@jConnection;allowInterrupts(Sys.sleep(0))})
    rJava::.jcall(jdbc,"V","setAutoCommit",FALSE);rJava::.jcall(jdbc,"V","setReadOnly",readOnly)
    rJava::.jcall(jdbc,"V","setTransactionIsolation",4L)
    transport<<-.sql_execution_transport(jdbc,limits,tick,startedClock)
    execute<-function(sql) {
      tick();.candidate_need(is.character(sql)&&length(sql)==1L&&nchar(enc2utf8(sql),type="bytes")<=4*1024^2,"candidate.store_sql_limit")
      statement<-NULL;done<-FALSE
      on.exit(if(!is.null(statement)) {
        if(!done)try(rJava::.jcall(statement,"V","cancel"),silent=TRUE)
        try(rJava::.jcall(statement,"V","close"),silent=TRUE)
      })
      suspendInterrupts({statement<-rJava::.jcall(jdbc,"Ljava/sql/Statement;","createStatement");allowInterrupts(Sys.sleep(0))})
      tick();rJava::.jcall(statement,"V","setQueryTimeout",timeout())
      begin<-wall();rJava::.jcall(statement,"Z","execute",sql);writeWait<<-writeWait+wall()-begin;done<-TRUE
      writes<<-writes+1;sqlBytes<<-sqlBytes+nchar(enc2utf8(sql),type="bytes");tick();invisible(NULL)
    }
    execute(paste0("SET LOCAL statement_timeout=",limits$statement_timeout_ms));execute("SET LOCAL lock_timeout=2000")
    execute("SET LOCAL timezone='UTC'");execute("SET LOCAL datestyle='ISO,YMD'");execute("SET LOCAL standard_conforming_strings=on")
    tx<-list(schema=paste0('"',schema,'"'),execute=execute,
      one=function(sql){reads<<-reads+1L;transport$one(sql,paste0("store.scalar.",reads),"metadata")},
      stream=function(sql,visit){reads<<-reads+1L;transport$stream(sql,visit,paste0("store.catalog.",reads),"metadata",maxRows=4096L,maxBytes=8*1024^2)})
    value<-work(tx);tick()
    if(!readOnly)suspendInterrupts({
      commitStarted<<-TRUE;state$outcome<-"unknown"
      .store_commit(jdbc);commitConfirmed<<-TRUE;state$outcome<-"committed";rollbackConfirmed<<-TRUE
    })
    value
  })
  cleaned<-suspendInterrupts(cleanup())
  if(!captured$ok) {
    failure<-captured$failure
    code<-if(commitStarted&&!commitConfirmed)"candidate.commit_unknown" else if(!cleaned)"candidate.cleanup_failed" else if(inherits(failure,"AchillesCandidateFailure"))failure$reason_code else if(inherits(failure,"interrupt"))"candidate.cancelled" else if(readOnly)"candidate.store_unavailable" else "candidate.store_failed"
    cause<-if(inherits(failure,"AchillesSqlExecutionFailure"))failure$reason_code else NULL
    .candidate_error(code,ids,outcome(),cause)
  }
  if(!cleaned).candidate_error("candidate.cleanup_failed",ids,outcome())
  list(value=captured$value,telemetry=.object(wall_ms=.sql_execution_ms(wall()-started),
    statements=format(writes,scientific=FALSE,trim=TRUE),sql_bytes=format(sqlBytes,scientific=FALSE,trim=TRUE),
    reads=as.character(reads),jdbc_write_wait_ms=.sql_execution_ms(writeWait),
    jdbc_write_scope="Client-observed JDBC write round-trip wall time including driver/network waits; not engine CPU",
    engine=.object(cpu_ms=NULL,peak_memory_bytes=NULL,query_id=NULL,reason_code="postgresql.jdbc_not_attributed"),jdbc=transport$telemetry()))
}
.candidate_readiness <- function(tx,assets) {
  .refresh_readiness(tx)
  .nv_need(tx$one(paste0("SELECT count(*)::text FROM ",tx$schema,".achillesnext_profile_registry WHERE profile_sha256=",.store_literal(assets$hash)))=="1","Install matching core profile first")
  invisible(NULL)
}
.candidate_import <- function(tx,capture,receipt,program,ids,tick) {
  began<-proc.time()[["elapsed"]];tick();assets<-.v2_assets();metrics<-names(assets$metrics);source<-program$batch$source
  .candidate_readiness(tx,assets);capture$verify()
  .nv_need(identical(receipt$observed_schema_sha256,receipt$runtime_facts$observed_schema_sha256)&&
    identical(.json(receipt$capabilities),.json(receipt$runtime_facts$capabilities)),"Source fact mismatch")
  audit<-.sql_execution_audit_totals(.json(receipt$audit_totals));datasets<-list()
  for(mid in metrics) {
    m<-assets$metrics[[mid]]
    d<-c(.object(version=m$version,population=m$population,grain=m$grain,row_schema_id=assets$rows[[mid]]$row_schema_id,
      definition_sha256=.v2_hash(.v2_bytes(m)),required=TRUE),receipt$inventory[[mid]])
    .v2_dataset(d,assets);datasets[[mid]]<-d
  }
  request<-.object(producer_id="compiled_core_candidate",producer_revision="1.0.0",program_sha256=program$program_sha256,
    profile=program$batch$profile,definitions=program$batch$definitions,scope=program$batch$scope,results_schema=gsub('"','',tx$schema,fixed=TRUE),
    source_consistency="single_repeatable_read_capture_separate_store_transaction",reuse="none")
  unknown<-.object(state="unknown",value=NULL,basis=NULL,assertion_id=NULL,reason_code="source.no_verified_release")
  s<-tx$schema;lit<-.store_literal;rid<-.store_uuid(ids$release_id);run<-.store_uuid(ids$run_id)
  tx$execute(paste0("INSERT INTO ",s,".achillesnext_source_release VALUES (",.store_uuid(ids$source_release_id),",",lit(source$source_id),",",lit(.json(unknown)),"::jsonb,",lit(.json(unknown)),"::jsonb,",lit(receipt$observed_schema_sha256),",",lit(source$declared_cdm_version),",now())"))
  tx$execute(paste0("INSERT INTO ",s,".achillesnext_analysis_run(run_id,source_release_id,request_sha256,profile_id,profile_revision,profile_sha256,state,consistency_basis,started_at) VALUES (",
    run,",",.store_uuid(ids$source_release_id),",",lit(.hash(.json(request))),",",lit(assets$profile$profile_id),",",lit(assets$profile$revision),",",lit(assets$hash),",'running','single_repeatable_read',",lit(receipt$generation$started_at),"::timestamptz)"))
  tx$execute(paste0("INSERT INTO ",s,".achillesnext_result_release VALUES (",rid,",",run,",'building',142,0,NULL)"))
  for(mid in metrics) {
    tick();d<-datasets[[mid]]
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_dataset VALUES (",paste(c(rid,vapply(c(mid,d$version,d$population,d$grain,d$row_schema_id,d$definition_sha256,d$state),lit,""),
      if(is.null(d$reason_code))"NULL" else lit(d$reason_code),"true",paste0(lit(.json(d$conditional_support)),"::jsonb"),d$rows,paste0(lit(.json(d$completeness)),"::jsonb")),collapse=","),")"))
  }
  writer<-.store_writer(tx,ids$release_id,assets);ledger<-list();capabilities<-list()
  for(mid in .candidate_order(assets)) {
    tick();count<-"0"
    capture$replay(mid,function(row) {
      tick();spec<-.analysis_denominator(mid,row,assets,forKey=TRUE);target<-NULL
      if(!is.null(spec)&&!row$state%in%c("unsupported","unavailable")) {
        key<-.v2_row_identity(assets$rows[[spec$metric_id]],.object(row_kind="counts",dimensions=spec$dimensions))
        target<-capture$lookup(spec$metric_id,key)
      }
      row$denominator_refs<-.domain_denominators(mid,row,target)
      .v2_row(mid,row,assets);writer$add(mid,row);count<<-.nv_add(count,"1")
      if(mid=="core.source.passport") {
        .v2_passport_check(row$values,.object(source_id=source$source_id,profile_id=assets$profile$profile_id,
          profile_revision=assets$profile$revision,profile_sha256=assets$hash,observed_schema_sha256=receipt$observed_schema_sha256,
          declared_cdm_version=source$declared_cdm_version,consistency_basis="single_repeatable_read"))
        .nv_need(identical(.json(row$values$generation),.json(receipt$generation)),"Source timestamp mismatch")
      }
      if(mid=="core.execution.output_status")ledger[[row$dimensions$metric_id]]<<-row$values
      if(mid=="core.source.capabilities")capabilities[[row$dimensions$probe_id]]<<-row$values
    })
    .nv_need(identical(count,datasets[[mid]]$rows),"Candidate metric count mismatch");writer$flush()
  }
  persistence<-writer$finish();.v2_ledger_check(datasets,ledger);.v2_capability_check(datasets,capabilities)
  .population_reconcile(tx,ids$release_id,datasets,audit$population);.domain_reconcile(tx,ids$release_id,datasets,audit$domains)
  operation<-function(id,dependencies,telemetry) {
    raw<-.v2_bytes(telemetry);.nv_need(length(raw)<=1024^2,"Candidate operation resource limit")
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_operation VALUES (",run,",",lit(id),",",lit(.hash(.json(program$batch$definitions))),",'succeeded',",lit(.json(as.list(dependencies))),"::jsonb,",lit(rawToChar(raw)),"::jsonb)"))
  }
  operation("compiled.source_capture",character(),.object(program_sha256=program$program_sha256,request=request,
    generation=receipt$generation,runtime_facts=receipt$runtime_facts,audit_totals=audit,rows=receipt$rows,bytes=receipt$bytes,reusable=FALSE))
  operation("compiled.candidate_persistence","compiled.source_capture",.object(persistence=persistence,
    client_import_wall_ms=.sql_execution_ms(proc.time()[["elapsed"]]-began),
    source_capture_transaction="separate_completed_repeatable_read",publication_changed=FALSE,reusable=FALSE))
  # Source generation uses the client clock; store transaction-start time is
  # neither that clock nor the completion of this separate import.
  finished<-.stamp()
  .nv_need(.nv_date(finished,TRUE)&&finished>=receipt$generation$ended_at,"Invalid candidate completion timestamp")
  tx$execute(paste0("UPDATE ",s,".achillesnext_analysis_run SET state='succeeded',finished_at=",lit(finished),"::timestamptz WHERE run_id=",run))
  tick();persistence
}
