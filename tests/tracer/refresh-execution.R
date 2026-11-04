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
  q<-function(sql)DatabaseConnector::querySql(owner,sql,integer64AsNumeric=FALSE)
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
  schema<-makeSource(input,1L);sourceId<-'fixture:full-refresh'
  plan<-function()planCharacterizationRefresh(schema,sourceId,results,serving,'5.5')
  request<-plan();worker<-env$fixtureConnection();operator<-env$fixtureConnection('owner')
  tableCount<-function(table)q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_',table))$N
  counts<-function()vapply(producerTables,tableCount,'')
  inspect<-function(candidate)f('.store_transaction')(worker,results,function(tx) {
    context<-f('.store_context')(tx,candidate$release_id);datasets<-f('.store_datasets')(tx,candidate$release_id)
    hashes<-list()
    for(mid in c(f('.population_ids')(),f('.domain_ids')(TRUE))) {
      rows<-character();f('.store_rows')(tx,candidate$release_id,mid,function(row,key){rows<<-c(rows,wire(row))})
      hashes[[mid]]<-f('.hash')(wire(as.list(rows)))
    }
    telemetry<-f('.store_decode')(tx$one(paste0('SELECT telemetry::text FROM ',tx$schema,'.achillesnext_operation WHERE run_id=',lit(candidate$run_id)," AND operation_id='core_characterization.refresh' AND state='succeeded'")))
    stopifnot(telemetry$producer_request$refresh$plan$plan_sha256==candidate$refresh$plan_sha256,
      f('.hash')(wire(telemetry$producer_request))==q(paste0('SELECT request_sha256 AS h FROM "',results,'".achillesnext_analysis_run WHERE run_id=',lit(candidate$run_id)))$H)
    list(context=context,hashes=hashes,person_count=tx$one(paste0('SELECT person_count::text FROM ',tx$schema,'.achillesnext_aggregate_cell WHERE release_id=',lit(candidate$release_id)," AND metric_id='core.person.count'")))
  })
  first<-executeCharacterizationRefresh(worker,request);a<-inspect(first)
  stopifnot(first$state=='building',first$profile_complete,!first$publishable,first$refresh$mode=='full_recompute',!first$refresh$reused)
  sealResultRelease(operator,results,first$release_id);validateResultRelease(operator,results,first$release_id)
  policy<-list(id='fixture-refresh',revision='1',scope_kind='restricted',allow_metrics=list('core.person.count'))
  published<-publishResultRelease(operator,results,first$release_id,file.path(out,'prior-publication'),'fixture-refresh','fixture-initial',policy,function(candidate)TRUE,'0')
  stopifnot(published$revision=='1');validateResultArtifact(published$export_dir)
  reader<-jsonlite::fromJSON(Sys.getenv('ACHILLES_NEXT_SERVING_FIXTURE'),simplifyVector=FALSE)
  role<-reader$user;stopifnot(grepl('^achilles_test_reader_[0-9a-f]+$',role))
  ex(paste0('GRANT USAGE ON SCHEMA "',serving,'" TO ',role,'; GRANT SELECT ON "',serving,'".achillesnext_approved_pages,"',serving,'".achillesnext_approved_current TO ',role,
    '; INSERT INTO "',results,'".achillesnext_audience_grant VALUES (',lit('fixture-refresh'),',',lit(role),',true)'))
  readerDetails<-DatabaseConnector::createConnectionDetails(dbms='postgresql',server='127.0.0.1/achilles_next_fixtures',port=as.integer(reader$port),user=role,password=reader$password)
  stopifnot(q(paste0('SELECT has_schema_privilege(',lit(role),',',lit(schema),",'USAGE')::text AS allowed"))$ALLOWED=='false')
  oldPointer<-function()q(paste0('SELECT source_id,profile_id,scope_id,publication_id::text,revision::text FROM "',results,'".achillesnext_current_publication ORDER BY source_id,profile_id,scope_id'))
  oldPages<-function()q(paste0("SELECT sha256,encode(payload,'hex') AS bytes FROM \"",results,'".achillesnext_page_object WHERE publication_id=',lit(published$publication_id),' ORDER BY sha256'))
  pointer<-oldPointer();pages<-oldPages();personDescriptor<-NULL
  f('.v2_directory')(published$export_dir,function(d,bytes) {
    if(d$kind=='data' && f('.nv_json')(bytes)$metric_id=='core.person.count')personDescriptor<<-d
  })
  stopifnot(!is.null(personDescriptor))
  prior<-function() {
    stopifnot(identical(pointer,oldPointer()),identical(pages,oldPages()))
    root<-readResultObject(readerDetails,serving,sourceId,published$publication_id,'fixture-refresh',published$root$sha256)
    stopifnot(identical(root,readBin(file.path(published$export_dir,'objects',paste0(published$root$sha256,'.json')),'raw',n=262145L)))
    bytes<-readResultObject(readerDetails,serving,sourceId,published$publication_id,'fixture-refresh',published$root$sha256,personDescriptor)
    stopifnot(f('.nv_json')(bytes)$rows[[1]]$values$person_count=='1')
  }
  prior()
  # Readiness failure precedes the first stage/result write.
  before<-counts();ticks<-0L
  ex(paste0('REVOKE INSERT ON "',results,'".achillesnext_source_release FROM achilles_next_runner'))
  error<-tryCatch({executeCharacterizationRefresh(worker,request,check=function(){ticks<<-ticks+1L});NULL},error=identity)
  ex(paste0('GRANT INSERT ON "',results,'".achillesnext_source_release TO achilles_next_runner'))
  stopifnot(inherits(error,'error'),ticks==2L,identical(before,counts()));prior()
  second<-executeCharacterizationRefresh(worker,request);b<-inspect(second)
  stopifnot(identical(a$hashes,b$hashes),first$release_id!=second$release_id,first$run_id!=second$run_id);prior()
  sealResultRelease(operator,results,second$release_id);validateResultRelease(operator,results,second$release_id)
  approvalCalled<-FALSE
  error<-tryCatch({publishResultRelease(operator,results,second$release_id,file.path(out,'denied-publication'),'fixture-refresh','fixture-denied',policy,function(candidate){approvalCalled<<-TRUE;FALSE},'1');NULL},error=identity)
  stopifnot(approvalCalled,inherits(error,'error'),conditionMessage(error)=='Result publication failed; prior current preserved',
    !dir.exists(file.path(out,'denied-publication')),tableCount('publication')=='1');prior()
  # Row contents change while schema and unknown release labels stay identical.
  ex(paste0('INSERT INTO "',schema,'".person SELECT 987654321,year_of_birth,gender_concept_id,race_concept_id,ethnicity_concept_id FROM "',schema,'".person LIMIT 1'))
  third<-executeCharacterizationRefresh(worker,request);c<-inspect(third)
  stopifnot(c$person_count=='2',a$context$observed_schema_sha256==c$context$observed_schema_sha256);prior()
  ex(paste0('UPDATE "',results,'".achillesnext_aggregate_cell SET person_count=person_count+1 WHERE release_id=',lit(third$release_id)," AND metric_id='core.person.gender_count'"))
  sealResultRelease(operator,results,third$release_id)
  validationError<-tryCatch({f('.store_transaction')(operator,results,function(tx)f('.store_validate')(tx,third$release_id));NULL},error=identity)
  stopifnot(inherits(validationError,'error'),conditionMessage(validationError)=='Numerator exceeds denominator')
  error<-tryCatch({validateResultRelease(operator,results,third$release_id);NULL},error=identity)
  stopifnot(inherits(error,'error'),conditionMessage(error)=='Aggregate release validation failed');prior()
  # Simulate changed installed definitions. A stale request is rejected before
  # a source/store connection; a fresh request recomputes instead of reusing data.
  originalDefinitions<-f('.run_definitions');restored<-FALSE
  on.exit(if(!restored)assignInNamespace('.run_definitions',originalDefinitions,ns='AchillesNext'),add=TRUE)
  assignInNamespace('.run_definitions',function(){d<-originalDefinitions();d$implementation_sha256<-strrep('f',64);d},ns='AchillesNext')
  before<-counts();error<-tryCatch({executeCharacterizationRefresh(NULL,request);NULL},error=identity)
  stopifnot(inherits(error,'error'),conditionMessage(error)=='Refresh plan changed or is stale; create a new plan',identical(before,counts()))
  changed<-plan();stopifnot(changed$plan_sha256!=request$plan_sha256)
  ticks<-0L;fourth<-executeCharacterizationRefresh(worker,changed,check=function(){ticks<<-ticks+1L});lastTick<-ticks;d<-inspect(fourth)
  assignInNamespace('.run_definitions',originalDefinitions,ns='AchillesNext');restored<-TRUE
  stopifnot(d$person_count=='2',fourth$refresh$plan_sha256==changed$plan_sha256);prior()
  # Fail/cancel at the final cooperative check, after metadata and succeeded-run
  # writes but before the candidate transaction commits. No checkpoint survives.
  for(mode in c('error','interrupt')) {
    before<-counts();ticks<-0L
    condition<-if(mode=='error')structure(list(message='fixture late refresh failure',call=NULL),class=c('AchillesPopulationFailure','error','condition')) else
      structure(list(message='fixture late refresh cancellation',call=NULL),class=c('interrupt','condition'))
    rejected<-tryCatch({executeCharacterizationRefresh(worker,request,check=function(){ticks<<-ticks+1L;if(ticks==lastTick)stop(condition)});FALSE},error=function(e)TRUE,interrupt=function(e)TRUE)
    stopifnot(rejected,ticks==lastTick,identical(before,counts()),q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==baselineTemp);prior()
  }
  snapshots<-list(a,b,c,d)
  stopifnot(length(unique(vapply(snapshots,function(s)s$context$release_id,'')))==4L,
    length(unique(vapply(snapshots,function(s)s$context$run_id,'')))==4L,
    length(unique(vapply(snapshots,function(s)s$context$source_release_id,'')))==4L,
    identical(implementation,implementationIdentity(getwd())))
  report<-list(person_counts=lapply(snapshots,function(s)s$person_count),fresh_identities=TRUE,unchanged_numeric_parity=TRUE,
    stale_definitions_rejected=TRUE,source_changed_recomputed=TRUE,new_definitions_recomputed=TRUE,late_failure_rolled_back=TRUE,
    late_cancellation_rolled_back=TRUE,validation_failure_preserved=TRUE,approval_failure_preserved=TRUE,source_denied_pinned_reads=TRUE,
    prior_pointer_and_bytes_preserved=TRUE,readiness_before_writes=TRUE,final_callback_count=lastTick,prior_publication=published$publication_id,
    implementation=implementation)
  writeLines(wire(report),file.path(out,'report.json'),useBytes=TRUE)
  cat('FULL_REFRESH_FRESH_IDENTITIES_SOURCE_DEFINITION_CHANGES_AND_PRIOR_PUBLICATION_PRESERVATION_OK\n')
}
main()
