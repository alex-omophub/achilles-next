# Installed producer/readback integration; source fixtures are tiny/disposable.
library(AchillesNext)
source('tools/benchmark/implementation_identity.R')
main<-function() {
  args<-commandArgs(TRUE);stopifnot(length(args)==2L)
  implementation<-implementationIdentity(getwd())
  env<-new.env(parent=globalenv());sys.source(args[1],env);out<-normalizePath(args[2],mustWork=TRUE)
  input<-jsonlite::fromJSON(file.path(out,'input.json'),simplifyVector=FALSE)
  owner<-DatabaseConnector::connect(env$fixtureConnection('owner'))
  on.exit(DatabaseConnector::disconnect(owner),add=TRUE)
  ex<-function(sql)DatabaseConnector::executeSql(owner,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,'error.txt'))
  q<-function(sql)DatabaseConnector::querySql(owner,sql,integer64AsNumeric=FALSE,errorReportFile=file.path(out,'owner-query-error.txt'))
  guard<-q("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB=='achilles_next_fixtures',guard$MARKER=='AchillesNext synthetic fixture sandbox v1')
  f<-function(n)get(n,asNamespace('AchillesNext'));lit<-f('.store_literal');wire<-f('.json')
  results<-paste0('achillesnext_domain_',Sys.getpid());serving<-paste0('achillesnext_popserve_',Sys.getpid())
  sources<-character();installed<-FALSE
  hadTemp<-q("SELECT has_database_privilege('achilles_next_runner',current_database(),'TEMPORARY')::text AS allowed")$ALLOWED=='true'
  on.exit({
    for(s in sources)ex(paste0('DROP SCHEMA "',s,'" CASCADE'))
    if(installed)ex(paste0('DROP SCHEMA "',serving,'","',results,'" CASCADE'))
    if(!hadTemp)ex('REVOKE TEMPORARY ON DATABASE achilles_next_fixtures FROM achilles_next_runner')
  },add=TRUE,after=FALSE)
  if(!hadTemp)ex('GRANT TEMPORARY ON DATABASE achilles_next_fixtures TO achilles_next_runner')
  initializeResultStore(env$fixtureConnection('owner'),results,serving,'cdm_tiny_a_55');installed<-TRUE
  producerTables<-c('source_release','analysis_run','operation','result_release','dataset','aggregate_cell','denominator_edge')
  qualified<-function(names)paste0('"',results,'".achillesnext_',names)
  ex(paste0('GRANT USAGE ON SCHEMA "',results,'" TO achilles_next_runner; GRANT SELECT ON ',paste(qualified(c('storage_version','profile_registry','validation_receipt',producerTables)),collapse=','),' TO achilles_next_runner; GRANT INSERT ON ',paste(qualified(producerTables),collapse=','),' TO achilles_next_runner; GRANT UPDATE ON ',paste(qualified(c('analysis_run','result_release')),collapse=','),' TO achilles_next_runner'))
  baselineTemp<-q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N
  makeSource<-function(case,index) {
    schema<-paste0('cdm_tiny_domain_',Sys.getpid(),'_',index);sources<<-c(sources,schema)
    ex(paste0('CREATE SCHEMA "',schema,'"; COMMENT ON SCHEMA "',schema,'" IS \'AchillesNext synthetic fixture sandbox v1: domain\''))
    for(n in names(case$columns)) {
      definitions<-paste(paste0('"',names(case$columns[[n]]),'" ',unlist(case$columns[[n]])),collapse=',')
      ex(paste0('CREATE TABLE "',schema,'"."',n,'" (',definitions,')'))
      if(length(case$tables[[n]]))ex(paste0('INSERT INTO "',schema,'"."',n,'" SELECT * FROM jsonb_to_recordset(',lit(wire(case$tables[[n]])),'::jsonb) x(',definitions,')'))
    }
    ex(paste0('GRANT USAGE ON SCHEMA "',schema,'" TO achilles_next_runner; GRANT SELECT ON ALL TABLES IN SCHEMA "',schema,'" TO achilles_next_runner'))
    for(table in unlist(case$denied_tables))ex(paste0('REVOKE SELECT ON "',schema,'"."',table,'" FROM achilles_next_runner'))
    schema
  }
  schema<-makeSource(input,1L);sourceId<-'fixture:refresh-operations'
  plan<-function()planCharacterizationRefresh(schema,sourceId,results,serving,'5.5')
  request<-plan();worker<-env$fixtureConnection();operator<-env$fixtureConnection('owner')
  tableCount<-function(table)q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_',table))$N
  counts<-function()vapply(producerTables,tableCount,'')
  source('tests/tracer/refresh-operations-process.R',local=TRUE)
  processes<-operationProcesses(out,args[1],schema,sourceId,results,serving)
  on.exit(processes$stop(),add=TRUE,after=FALSE)
  control<-DatabaseConnector::connect(worker);on.exit(DatabaseConnector::disconnect(control),add=TRUE)
  cq<-function(sql)DatabaseConnector::querySql(control,sql,integer64AsNumeric=FALSE,errorReportFile=file.path(out,'control-query-error.txt'))
  backend<-function(ctx) {
    row<-cq(paste0("SELECT pid::text AS pid,state,backend_xmin::text AS xmin FROM pg_stat_activity WHERE datname=current_database() AND usename=current_user AND application_name=",lit(ctx$app)," AND pid<>pg_backend_pid()"))
    stopifnot(nrow(row)==1L,row$STATE=='idle in transaction',!is.na(row$XMIN));row$PID
  }
  seed<-executeCharacterizationRefresh(worker,request)
  sealResultRelease(operator,results,seed$release_id);validateResultRelease(operator,results,seed$release_id)
  policy<-list(id='fixture-operations',revision='1',scope_kind='restricted',allow_metrics=list('core.person.count'))
  scope<-'fixture-operations'
  priorPub<-publishResultRelease(operator,results,seed$release_id,file.path(out,'prior-publication'),scope,'ops-seed',policy,function(candidate)TRUE,'0')
  stopifnot(priorPub$revision=='1')
  reader<-jsonlite::fromJSON(Sys.getenv('ACHILLES_NEXT_SERVING_FIXTURE'),simplifyVector=FALSE)
  role<-reader$user;stopifnot(grepl('^achilles_test_reader_[0-9a-f]+$',role))
  ex(paste0('GRANT USAGE ON SCHEMA "',serving,'" TO ',role,'; GRANT SELECT ON "',serving,'".achillesnext_approved_pages,"',serving,'".achillesnext_approved_current TO ',role,
    '; INSERT INTO "',results,'".achillesnext_audience_grant VALUES (',lit(scope),',',lit(role),',true)'))
  readerDetails<-DatabaseConnector::createConnectionDetails(dbms='postgresql',server='127.0.0.1/achilles_next_fixtures',port=as.integer(reader$port),user=role,password=reader$password)
  stopifnot(q(paste0('SELECT has_schema_privilege(',lit(role),',',lit(schema),",'USAGE')::text AS allowed"))$ALLOWED=='false')
  pointer<-function()q(paste0('SELECT publication_id::text AS id,revision::text AS revision FROM "',results,'".achillesnext_current_publication'))
  pages<-function(pub)q(paste0("SELECT sha256,encode(payload,'hex') AS bytes FROM \"",results,'".achillesnext_page_object WHERE publication_id=',lit(pub$publication_id),' ORDER BY sha256'))
  pin<-function(pub,want) {
    descriptor<-NULL
    f('.v2_directory')(pub$export_dir,function(d,bytes) {
      if(d$kind=='data' && f('.nv_json')(bytes)$metric_id=='core.person.count')descriptor<<-d
    })
    stopifnot(!is.null(descriptor))
    root<-readResultObject(readerDetails,serving,sourceId,pub$publication_id,scope,pub$root$sha256)
    stopifnot(identical(root,readBin(file.path(pub$export_dir,'objects',paste0(pub$root$sha256,'.json')),'raw',n=262145L)))
    bytes<-readResultObject(readerDetails,serving,sourceId,pub$publication_id,scope,pub$root$sha256,descriptor)
    stopifnot(f('.nv_json')(bytes)$rows[[1]]$values$person_count==want)
  }
  originalPointer<-pointer();originalPages<-pages(priorPub)
  prior<-function(expectPointer=TRUE) {
    if(expectPointer)stopifnot(identical(originalPointer,pointer()))
    stopifnot(identical(originalPages,pages(priorPub)));pin(priorPub,'1')
  }
  insertCondition<-function(rows,execute=ex) {
    definitions<-paste(paste0('"',names(input$columns$condition_occurrence),'" ',unlist(input$columns$condition_occurrence)),collapse=',')
    execute(paste0('INSERT INTO "',schema,'".condition_occurrence SELECT * FROM jsonb_to_recordset(',lit(wire(rows)),'::jsonb) x(',definitions,')'))
  }
  insertCondition(input$condition_initial)
  aJob<-processes$start('snapshot-a');processes$ready(aJob);aPid<-backend(aJob)
  # One committed ETL-like mutation includes an insert, a delete/backfill and a
  # vocabulary change. The first refresh already holds its repeatable-read snapshot.
  mutationId<-f('.store_transaction')(operator,results,function(tx) {
    id<-tx$one('SELECT pg_current_xact_id()::text')
    tx$execute(paste0('INSERT INTO "',schema,'".person SELECT 987654321,year_of_birth,gender_concept_id,race_concept_id,ethnicity_concept_id FROM "',schema,'".person LIMIT 1'))
    tx$execute(paste0('DELETE FROM "',schema,'".condition_occurrence'))
    insertCondition(input$condition_changed,tx$execute)
    tx$execute(paste0('UPDATE "',schema,'".concept SET domain_id=',lit('Drug'),' WHERE concept_id=100'))
    stopifnot(tx$one('SELECT pg_current_xact_id()::text')==id);id
  },isolation=2L)
  bJob<-processes$start('snapshot-b');processes$ready(bJob);bPid<-backend(bJob)
  stopifnot(aPid!=bPid,backend(aJob)==aPid);prior()
  processes$release(aJob);processes$release(bJob)
  aResult<-processes$result(aJob);bResult<-processes$result(bJob)
  stopifnot(isTRUE(aResult$ok),isTRUE(bResult$ok));prior()
  summaries<-lapply(list(aResult,bResult),function(result) {
    candidate<-result$value;stopifnot(candidate$generated_metric_count=='142',candidate$profile_complete,!candidate$publishable)
    f('.store_transaction')(worker,results,function(tx) {
      f('.store_datasets')(tx,candidate$release_id)
      read<-function(mid,field,where='')tx$one(paste0('SELECT ',field,'::text FROM ',tx$schema,'.achillesnext_aggregate_cell WHERE release_id=',lit(candidate$release_id),' AND metric_id=',lit(mid),where))
      list(person_count=read('core.person.count','person_count'),
        condition_count=read('core.condition.capture_count','record_count'," AND dimensions->'concept_tag'->>'kind'='all' AND dimensions->>'period_kind'='full_scope'"),
        wrong_domain_count=read('core.condition.integrity_count','record_count'," AND dimensions->>'flag'='wrong_domain_concept' AND dimensions->>'present'='true'"))
    })
  })
  stopifnot(identical(unlist(summaries[[1]],use.names=FALSE),c('1','1','0')),
    identical(unlist(summaries[[2]],use.names=FALSE),c('2','2','2')))
  context<-lapply(list(aResult,bResult),function(result)f('.store_transaction')(worker,results,function(tx)f('.store_context')(tx,result$value$release_id)))
  for(key in c('release_id','run_id','source_release_id'))stopifnot(context[[1]][[key]]!=context[[2]][[key]])
  # Disconnect a third worker at its final precommit callback, after all candidate
  # writes. Only the exact fixture-owned application/session is signaled.
  before<-counts();lost<-processes$start('connection-loss',pauseAt=bResult$ticks)
  processes$ready(lost);lostPid<-backend(lost);stopifnot(identical(before,counts()));prior()
  terminated<-cq(paste0('SELECT pg_terminate_backend(pid,5000)::text AS stopped FROM pg_stat_activity WHERE pid=',as.integer(lostPid),
    ' AND application_name=',lit(lost$app)," AND usename=current_user AND datname=current_database() AND pid<>pg_backend_pid()"))
  stopifnot(nrow(terminated)==1L,terminated$STOPPED=='true')
  processes$release(lost);lostResult<-processes$result(lost)
  stopifnot(!isTRUE(lostResult$ok),lostResult$kind=='error',identical(before,counts()),
    q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==baselineTemp);prior()
  publications<-list()
  for(i in 1:2) {
    candidate<-list(aResult,bResult)[[i]]$value
    sealResultRelease(operator,results,candidate$release_id);validateResultRelease(operator,results,candidate$release_id)
    publications[[i]]<-publishResultRelease(operator,results,candidate$release_id,file.path(out,paste0('approved-',i)),scope,paste0('ops-approval-',i),policy,
      function(c)identical(c$release_id,candidate$release_id)&&identical(c$source_id,sourceId),expectedRevision=NULL)
    pub<-publications[[i]]
    stopifnot(q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_publication p JOIN "',results,'".achillesnext_validation_receipt v ON v.receipt_id=p.receipt_id WHERE p.publication_id=',lit(pub$publication_id),
      ' AND p.release_id=',lit(candidate$release_id),' AND v.release_id=p.release_id AND v.passed'))$N=='1')
  }
  prior();pageCopies<-lapply(publications,pages)
  race<-list(processes$start('promote-a','promote',publicationId=publications[[1]]$publication_id,expectedRevision='1'),
    processes$start('promote-b','promote',publicationId=publications[[2]]$publication_id,expectedRevision='1'))
  lapply(race,processes$ready)
  # Hold the actual CAS advisory key until both independent promotion sessions
  # are visibly blocked on it. This proves contention rather than near-simultaneous
  # process starts that could still execute sequentially.
  waiting<-f('.store_transaction')(operator,results,function(tx) {
    tx$one(paste0('SELECT pg_advisory_xact_lock(hashtextextended(jsonb_build_array(',lit(sourceId),",'core-characterization-v2',",lit(scope),')::text,0))::text'))
    lapply(race,processes$release);start<-proc.time()[['elapsed']]
    repeat {
      tx$execute('SELECT pg_stat_clear_snapshot()')
      pids<-character()
      tx$stream(paste0("SELECT pid::text FROM pg_stat_activity WHERE usename=current_user AND datname=current_database() AND application_name IN (",
        paste(vapply(race,function(ctx)lit(ctx$app),''),collapse=','),") AND wait_event_type='Lock' AND wait_event='advisory'"),function(pid){pids<<-c(pids,pid)})
      if(length(pids)==2L)return(pids)
      if(proc.time()[['elapsed']]-start>15)stop('Promotion workers did not contend on the CAS gate')
      Sys.sleep(0.02)
    }
  },isolation=2L)
  outcomes<-lapply(race,processes$result)
  won<-which(vapply(outcomes,function(r)isTRUE(r$ok),TRUE));stopifnot(length(won)==1L)
  loser<-setdiff(1:2,won)
  stopifnot(outcomes[[won]]$revision=='2',outcomes[[loser]]$message=='Current publication conflict',
    pointer()$REVISION=='2',pointer()$ID==publications[[won]]$publication_id)
  stopifnot(promoteResultPublication(operator,results,publications[[won]]$publication_id,'1')=='2')
  conflict<-tryCatch({promoteResultPublication(operator,results,publications[[loser]]$publication_id,'1');NULL},error=identity)
  stopifnot(inherits(conflict,'error'),conditionMessage(conflict)=='Current publication conflict',pointer()$REVISION=='2')
  for(i in 1:2){stopifnot(identical(pageCopies[[i]],pages(publications[[i]])));pin(publications[[i]],as.character(i))}
  prior(FALSE);processes$assertStopped()
  stopifnot(identical(implementation,implementationIdentity(getwd())))
  report<-list(snapshots=summaries,overlap_observed=TRUE,distinct_candidate_identities=TRUE,late_connection_loss_rollback=TRUE,
    promotion_contention_observed=TRUE,one_cas_winner=TRUE,stale_cas_rejected=TRUE,idempotent_winner_retry=TRUE,approval_contexts_isolated=TRUE,
    pinned_prior_bytes_retained=TRUE,pinned_loser_readable=TRUE,source_denied_reads=TRUE,children_stopped=TRUE,
    final_revision=pointer()$REVISION,overlap_backend_pids=list(aPid,bPid),mutation_transaction_id=mutationId,promotion_waiter_pids=as.list(waiting),terminated_backend_pid=lostPid,implementation=implementation)
  writeLines(wire(report),file.path(out,'report.json'),useBytes=TRUE)
  cat('OVERLAP_REPEATABLE_READ_ETL_MUTATION_CONNECTION_LOSS_AND_CAS_PINNING_OK\n')
}
main()
