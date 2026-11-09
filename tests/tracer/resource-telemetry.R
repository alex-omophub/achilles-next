# One capped, synthetic full-profile pair with observer wrappers; no runtime edits.
library(AchillesNext)
protocol<-Sys.getenv('ACHILLES_NEXT_TELEMETRY_PROTOCOL_DIR')
stopifnot(nzchar(protocol))
source(file.path(protocol,'implementation_identity.R'))
source(file.path(protocol,'matched_reference.R'))
source(file.path(protocol,'resource_telemetry.R'))
local({
 args<-commandArgs(TRUE);stopifnot(length(args)==2L)
 env<-new.env();sys.source(args[1],env);out<-normalizePath(args[2],mustWork=TRUE)
 input<-jsonlite::fromJSON(file.path(out,'input.json'),simplifyVector=FALSE)
 one<-input$source;stopifnot(grepl('^cdm_synthetic_[0-9a-f]{12}$',one$schema),grepl('^[0-9a-f]{12}$',input$nonce))
 f<-function(n)get(n,asNamespace('AchillesNext'));lit<-f('.store_literal');wire<-f('.v2_bytes');implementation<-implementationIdentity('.')
 owner<-DatabaseConnector::connect(env$fixtureConnection('owner'));on.exit(DatabaseConnector::disconnect(owner),add=TRUE)
 ex<-function(sql)DatabaseConnector::executeSql(owner,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,'sql-error.txt'))
 q<-function(sql)DatabaseConnector::querySql(owner,sql,integer64AsNumeric=FALSE)
 guard<-q("SELECT current_database() AS db,current_user AS usr,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
 stopifnot(guard$DB=='achilles_next_fixtures',guard$USR=='achilles_next_fixture_owner',guard$MARKER=='AchillesNext synthetic fixture sandbox v1')
 stopifnot(q(paste0("SELECT obj_description(oid,'pg_namespace') AS m FROM pg_namespace WHERE nspname=",lit(one$schema)))$M==one$marker)
 results<-paste0('achillesnext_telemetry_',input$nonce);serve<-paste0('achillesnext_tserve_',input$nonce);made<-FALSE;exporter<-NULL;observer<-NULL;status<-'failed'
 hadTemp<-q("SELECT has_database_privilege('achilles_next_runner',current_database(),'TEMPORARY')::text AS ok")$OK=='true'
 writeBin(wire(list(results_schema=results,serving_schema=serve,runner_had_temp=hadTemp)),file.path(out,'fixture-state.json'))
 on.exit({
   errors<-character();clean<-function(work)tryCatch(work(),error=function(e)errors<<-c(errors,conditionMessage(e)))
   if(!is.null(exporter)){clean(function()rJava::.jcall(exporter@jConnection,'V','rollback'));clean(function()DatabaseConnector::disconnect(exporter))}
   if(made)clean(function()ex(paste0('DROP SCHEMA "',serve,'","',results,'" CASCADE')))
   if(!hadTemp)clean(function()ex('REVOKE TEMPORARY ON DATABASE achilles_next_fixtures FROM achilles_next_runner'))
   if(!is.null(observer))clean(function()observer$finish(if(length(errors))'cleanup_failed' else status))
   if(length(errors))stop('Telemetry fixture cleanup failed')
 },add=TRUE,after=FALSE)
 if(!hadTemp)ex('GRANT TEMPORARY ON DATABASE achilles_next_fixtures TO achilles_next_runner')
 initializeResultStore(env$fixtureConnection('owner'),results,serve,one$schema);made<-TRUE
 tables<-function(ids)paste(paste0('"',results,'".achillesnext_',ids),collapse=',')
 producer<-c('source_release','analysis_run','operation','result_release','dataset','aggregate_cell','denominator_edge')
 ex(paste0('GRANT USAGE ON SCHEMA "',results,'" TO achilles_next_runner; GRANT SELECT ON ',tables(c('storage_version','profile_registry','validation_receipt',producer)),
  ' TO achilles_next_runner; GRANT INSERT ON ',tables(producer),' TO achilles_next_runner; GRANT UPDATE ON ',tables(c('analysis_run','result_release')),' TO achilles_next_runner'))
 observer<-resourceTelemetry(out,owner,c(one$schema,results,serve),one$schema)
 compiled<-jsonlite::fromJSON(file.path(out,'compiled.json'),simplifyVector=FALSE)
 exporter<-DatabaseConnector::connect(env$fixtureConnection('owner'));rJava::.jcall(exporter@jConnection,'V','setAutoCommit',FALSE);rJava::.jcall(exporter@jConnection,'V','setTransactionIsolation',4L)
 snapshot<-list(ID=referenceOne(exporter,'SELECT pg_export_snapshot()'),witness=referenceOne(exporter,'SELECT pg_current_snapshot()::text'))
 witnesses<-new.env();witnesses$values<-character();paths<-list();sourceId<-paste0('fixture:telemetry:',one$manifest_sha256)
 capture<-function(candidate)f('.store_transaction')(env$fixtureConnection(),results,function(tx) {
   datasets<-f('.store_datasets')(tx,candidate$release_id);rows<-list()
   for(mid in names(datasets)){rows[[mid]]<-list();f('.store_rows')(tx,candidate$release_id,mid,function(row,key)rows[[mid]][[length(rows[[mid]])+1L]]<<-row)}
   list(datasets=datasets,rows=rows,source_id=sourceId,version='5.5',schema_sha256=f('.store_context')(tx,candidate$release_id)$observed_schema_sha256)
 })
 for(path in c('optimized','reference')) {
   cat('TELEMETRY_GENERATE ',path,'\n',sep='')
   candidate<-observer$phase(paste0(path,'.generation'),function() {
     if(path=='optimized')referenceOptimized(env$fixtureConnection(),one$schema,sourceId,results,'5.5',snapshot$ID,witnesses,observer=observer) else
       referenceGenerate(env$fixtureConnection(),one$schema,sourceId,results,'5.5',compiled,snapshot$ID,witnesses,observer=observer)
   },database=TRUE)
   stopifnot(identical(candidate$generated_metric_count,'142'),isTRUE(candidate$profile_complete),identical(candidate$publishable,FALSE))
   snap<-capture(candidate);snap$generated_metric_count<-candidate$generated_metric_count
   # Persisted producer telemetry includes exact writer counters/revision and native stage observations.
   operation<-q(paste0("SELECT telemetry::text AS t FROM \"",results,'".achillesnext_operation WHERE run_id=',lit(candidate$run_id)))$T
   revision<-q(paste0('SELECT content_revision::text AS n FROM "',results,'".achillesnext_result_release WHERE release_id=',lit(candidate$release_id)))$N
   paths[[path]]<-list(candidate=candidate,snapshot=snap,operation=jsonlite::fromJSON(operation,simplifyVector=FALSE),content_revision=revision)
 }
 # Unobserved generation controls prove the observer has not changed analytical values.
 baselines<-list()
 for(path in c('optimized','reference')) {
   candidate<-if(path=='optimized')referenceOptimized(env$fixtureConnection(),one$schema,sourceId,results,'5.5',snapshot$ID,witnesses) else
     referenceGenerate(env$fixtureConnection(),one$schema,sourceId,results,'5.5',compiled,snapshot$ID,witnesses)
   baselines[[path]]<-capture(candidate)
 }
 stopifnot(identical(witnesses$values,rep(snapshot$witness,4L)))
 rJava::.jcall(exporter@jConnection,'V','rollback');DatabaseConnector::disconnect(exporter);exporter<-NULL
 checkpoint<-file.path(out,'candidates.json');writeBin(wire(list(paths=paths,model='model.json',expectations='expectations.json')),checkpoint)
 stopifnot(system2(Sys.getenv('ACHILLES_NEXT_REFERENCE_PYTHON',unset='python3'),c('tools/matched_reference_compare.py',shQuote(checkpoint)))==0L)
 ex(paste0('REVOKE ALL ON SCHEMA "',one$schema,'" FROM achilles_next_runner'))
 publications<-list();kinds<-if(isTRUE(input$with_projected))c('full','projected') else 'full'
 for(path in names(paths)) {
   candidate<-paths[[path]]$candidate
   observer$phase(paste0(path,'.seal'),function()sealResultRelease(env$fixtureConnection('owner'),results,candidate$release_id),database=TRUE)
   observer$phase(paste0(path,'.validation'),function()observer$public('validateResultRelease')(env$fixtureConnection('owner'),results,candidate$release_id),database=TRUE)
   paths[[path]]$snapshot$validated<-TRUE;publications[[path]]<-list()
   for(kind in kinds) {
     scope<-paste0('fixture-telemetry-',kind);policy<-list(id=scope,revision='1',scope_kind=if(kind=='full')'restricted' else 'distributable',allow_metrics=if(kind=='full')as.list(names(paths[[path]]$snapshot$datasets)) else list('core.person.count','core.person.gender_count'))
     directory<-paste0('export-',path,'-',kind);cat('TELEMETRY_PUBLISH ',path,' ',kind,'\n',sep='')
     pub<-observer$phase(paste0(path,'.publication.',kind),function()observer$public('publishResultRelease')(
       env$fixtureConnection('owner'),results,candidate$release_id,file.path(out,directory),scope,'synthetic-telemetry-review',policy,
       function(proposal)observer$phase('approval_callback',function(){stopifnot(proposal$source_id==sourceId);TRUE}),if(path=='optimized')'0' else '1',cancel=function(){observer$check();FALSE}),database=TRUE)
     observer$phase(paste0(path,'.file_read_sample'),function() {
       raw<-readBin(file.path(pub$export_dir,'objects',paste0(pub$root$sha256,'.json')),'raw',n=as.numeric(pub$root$bytes));stopifnot(f('.v2_hash')(raw)==pub$root$sha256)
     })
     publications[[path]][[kind]]<-list(directory=directory,publication_id=pub$publication_id,release_id=candidate$release_id,access_scope_id=scope,root=pub$root,policy=policy)
   }
 }
 # A cooperative cancellation after approval interrupts a building publication,
 # rolls back pages/control writes and removes its staged directory before CAS.
 before<-q(paste0('SELECT publication_id::text AS id,revision::text AS rev FROM "',results,'".achillesnext_current_publication ORDER BY scope_id'))
 count<-q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_publication'))$N
 interrupted<-FALSE;cancellationObserved<-FALSE;pageWritten<-FALSE;policy<-publications$reference$full$policy
 observer$set_after_statement(function(sql)if(grepl('^INSERT INTO .*achillesnext_page_object',sql)){pageWritten<<-TRUE;interrupted<<-TRUE})
 failure<-tryCatch({observer$phase('expected_cancel_probe',function()observer$public('publishResultRelease')(
   env$fixtureConnection('owner'),results,paths$reference$candidate$release_id,file.path(out,'cancelled-export'),policy$id,'synthetic-telemetry-cancel',policy,
   function(proposal)TRUE,'2',cancel=function(){observer$check();if(interrupted)cancellationObserved<<-TRUE;interrupted}),database=TRUE);FALSE},error=function(e)identical(conditionMessage(e),'Result publication failed; prior current preserved'))
 observer$set_after_statement(NULL)
 after<-q(paste0('SELECT publication_id::text AS id,revision::text AS rev FROM "',results,'".achillesnext_current_publication ORDER BY scope_id'))
 stopifnot(failure,interrupted,cancellationObserved,pageWritten,identical(before,after),count==q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_publication'))$N,
   !dir.exists(file.path(out,'cancelled-export')),!length(list.files(out,pattern='^[.]achilles-export',all.files=TRUE)))
 stopifnot(identical(implementation,implementationIdentity('.')))
 writeBin(wire(list(paths=paths,baseline_paths=baselines,publications=publications,snapshot_witness=snapshot$witness,imported_witnesses=as.list(witnesses$values),cancel_probe=list(passed=TRUE,previous_publication_preserved=TRUE,after_page_write=TRUE),implementation=implementation)),file.path(out,'results.json'))
 status<-'passed';cat('TELEMETRY_PAIR_AND_CANCEL_PROBE_PASSED\n')
})
