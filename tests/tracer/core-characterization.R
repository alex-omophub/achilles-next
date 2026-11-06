# Installed producer/readback integration; source fixtures are tiny/disposable.
library(AchillesNext)
source('tools/benchmark/implementation_identity.R')
main<-function() {
  args<-commandArgs(TRUE);stopifnot(length(args)==2L)
  implementation<-implementationIdentity(getwd())
  env<-new.env(parent=globalenv());sys.source(args[1],env);out<-normalizePath(args[2],mustWork=TRUE)
  publicationMode<-nzchar(Sys.getenv('ACHILLES_NEXT_SERVING_FIXTURE'))
  if(publicationMode)source('tests/tracer/core-publication.R',local=TRUE)
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
  # Catalog type modifiers are schema evidence, even on an empty relation.
  # Exercise the same probe used by candidate generation without rounding data.
  probeSchema<-makeSource(list(columns=list(measurement=list(value_as_number='numeric(8,2)',value_source_value='varchar(12)')),
    tables=list(measurement=list()),denied_tables=list()),0L)
  probe<-function()f('.store_transaction')(env$fixtureConnection(),results,function(tx)f('.core_capabilities')(tx,probeSchema),readOnly=TRUE)
  first<-probe();stopifnot(identical(first,probe()),
    first$values[['measurement.value_as_number']]$observed_type=='numeric(8,2)',
    first$values[['measurement.value_source_value']]$observed_type=='character varying(12)')
  ex(paste0('ALTER TABLE "',probeSchema,'".measurement ALTER COLUMN value_as_number TYPE numeric(18,6)'))
  second<-probe();stopifnot(second$values[['measurement.value_as_number']]$observed_type=='numeric(18,6)',
    first$schema_sha256!=second$schema_sha256,identical(second,probe()))
  ex(paste0('ALTER TABLE "',probeSchema,'".measurement ALTER COLUMN value_source_value TYPE varchar(48)'))
  third<-probe();stopifnot(third$values[['measurement.value_source_value']]$observed_type=='character varying(48)',
    second$schema_sha256!=third$schema_sha256,identical(third,probe()))
  typeModifiers<-list(numeric_before=first$values[['measurement.value_as_number']]$observed_type,
    numeric_after=second$values[['measurement.value_as_number']]$observed_type,
    varchar_before=first$values[['measurement.value_source_value']]$observed_type,
    varchar_after=third$values[['measurement.value_source_value']]$observed_type,
    before_sha256=first$schema_sha256,numeric_changed_sha256=second$schema_sha256,varchar_changed_sha256=third$schema_sha256)
  writeLines(wire(typeModifiers),file.path(out,'schema-modifier-proof.json'))
  cat('NUMERIC_AND_VARCHAR_TYPEMODIFIERS_CHANGE_SCHEMA_IDENTITY_OK\n')
  for(index in seq_along(input)) {
    case<-input[[index]];schema<-makeSource(case,index);sourceId<-paste0('fixture:core:',case$case)
    generated<-if(publicationMode)executeCharacterizationRefresh(env$fixtureConnection(),
      planCharacterizationRefresh(schema,sourceId,results,serving,case$version)) else
      generateCharacterizationCandidate(env$fixtureConnection(),schema,sourceId,results,case$version)
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
    snap$refresh_executed<-publicationMode
    snapshots[[length(snapshots)+1L]]<-c(list(case=case$case,version=case$version,source_id=sourceId),snap)
    saved[[length(saved)+1L]]<-list(schema=schema,release=generated$release_id)
    stopifnot(q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_current_publication'))$N==if(publicationMode && index>1L)'2' else '0',
      q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==baselineTemp)
    if(publicationMode && index==1L)publicationProof<-testCorePublication(env,owner,results,serving,schema,sourceId,generated,snap,out)
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
  writeLines(wire(list(snapshots=snapshots,implementation=implementation,
    publication=if(publicationMode)publicationProof else NULL)),file.path(out,'report.json'),useBytes=TRUE)
  cat('CORE_METADATA_NATIVE_VALIDATION_SOURCE_DENIED_AND_LATE_BUDGET_ROLLBACK_OK\n')
}
main()
