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
  snapshots<-list();saved<-list();careCases<-list();baselineTemp<-q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N
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
  for(index in seq_along(input)) {
    case<-input[[index]];schema<-makeSource(case,index);sourceId<-paste0('fixture:core:',case$case)
    generated<-generateCharacterizationCandidate(env$fixtureConnection(),schema,sourceId,results,case$version)
    stopifnot(generated$generated_metric_count=='142',generated$profile_complete,!generated$publishable)
    snap<-f('.store_transaction')(env$fixtureConnection(),results,function(tx) {
      datasets<-f('.store_datasets')(tx,generated$release_id);rows<-list()
      for(mid in names(datasets)) {
        rows[[mid]]<-list()
        f('.store_rows')(tx,generated$release_id,mid,function(row,key){rows[[mid]][[length(rows[[mid]])+1L]]<<-row})
      }
      context<-f('.store_context')(tx,generated$release_id)
      list(datasets=datasets,rows=rows,schema_sha256=context$observed_schema_sha256)
    })
    # All validation uses only saved results; source denial must not alter it.
    ex(paste0('REVOKE ALL ON SCHEMA "',schema,'" FROM achilles_next_runner'))
    sealResultRelease(env$fixtureConnection('owner'),results,generated$release_id)
    validateResultRelease(env$fixtureConnection('owner'),results,generated$release_id)
    if(index==1L)f('.store_transaction')(env$fixtureConnection(),results,function(tx)f('.store_validate')(tx,generated$release_id))
    snap$validated<-TRUE;snap$generated_metric_count<-generated$generated_metric_count
    snapshots[[length(snapshots)+1L]]<-c(list(case=case$case,version=case$version,source_id=sourceId),snap)
    saved[[length(saved)+1L]]<-list(schema=schema,release=generated$release_id)
    stopifnot(q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_current_publication'))$N=='0',
      q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==baselineTemp)
    cat('CORE_142_VALIDATED ',case$case,' ',case$version,'\n',sep='')
  }
  # Permit all numeric rows but fail inside metadata writing: no candidate may
  # escape a late metadata limit failure, even after a bounded writer flush.
  schema<-saved[[1]]$schema
  ex(paste0('GRANT USAGE ON SCHEMA "',schema,'" TO achilles_next_runner'))
  numericRows<-sum(vapply(snapshots[[1]]$datasets[setdiff(names(snapshots[[1]]$datasets),f('.core_metadata_ids')())],function(d)as.numeric(d$rows),0))
  before<-q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N
  err<-tryCatch({generateCharacterizationCandidate(env$fixtureConnection(),schema,'fixture:late-budget',results,input[[1]]$version,maxAggregateRows=numericRows+1);'accepted'},error=conditionMessage)
  stopifnot(err!='accepted',grepl('Aggregate row budget',err),q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N==before)
  stopifnot(identical(implementation,implementationIdentity(getwd())))
  writeLines(wire(list(snapshots=snapshots,implementation=implementation)),file.path(out,'report.json'),useBytes=TRUE)
  cat('CORE_METADATA_NATIVE_VALIDATION_SOURCE_DENIED_AND_LATE_BUDGET_ROLLBACK_OK\n')
}
main()
