# Installed generation over new bounded CSV-backed CDM schemas only.
library(AchillesNext)
source('tools/benchmark/implementation_identity.R')
local({
  args<-commandArgs(TRUE);stopifnot(length(args)==2L)
  env<-new.env();sys.source(args[[1]],env);out<-normalizePath(args[[2]],mustWork=TRUE)
  input<-jsonlite::fromJSON(file.path(out,'input.json'),simplifyVector=FALSE)
  f<-function(n)get(n,asNamespace('AchillesNext'));lit<-f('.store_literal');wire<-f('.v2_bytes')
  implementation<-implementationIdentity('.')
  owner<-DatabaseConnector::connect(env$fixtureConnection('owner'));on.exit(DatabaseConnector::disconnect(owner),add=TRUE)
  ex<-function(sql)DatabaseConnector::executeSql(owner,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,'sql-error.txt'))
  q<-function(sql)DatabaseConnector::querySql(owner,sql,integer64AsNumeric=FALSE)
  guard<-q("SELECT current_database() AS db,current_user AS usr,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB=='achilles_next_fixtures',guard$USR=='achilles_next_fixture_owner',guard$MARKER=='AchillesNext synthetic fixture sandbox v1')
  schemas<-vapply(input,function(x)x$schema,'')
  stopifnot(all(grepl('^cdm_synthetic_[0-9a-f]{12}$',schemas)),!anyDuplicated(schemas))
  results<-paste0('achillesnext_preview_',Sys.getpid());serve<-paste0('achillesnext_preview_serve_',Sys.getpid());installed<-FALSE
  hadTemp<-q("SELECT has_database_privilege('achilles_next_runner',current_database(),'TEMPORARY')::text AS ok")$OK=='true'
  on.exit({
    if(installed)ex(paste0('DROP SCHEMA "',serve,'","',results,'" CASCADE'))
    if(!hadTemp)ex('REVOKE TEMPORARY ON DATABASE achilles_next_fixtures FROM achilles_next_runner')
  },add=TRUE,after=FALSE)
  if(!hadTemp)ex('GRANT TEMPORARY ON DATABASE achilles_next_fixtures TO achilles_next_runner')
  initializeResultStore(env$fixtureConnection('owner'),results,serve,schemas);installed<-TRUE
  producer<-c('source_release','analysis_run','operation','result_release','dataset','aggregate_cell','denominator_edge')
  tables<-function(ids)paste(paste0('"',results,'".achillesnext_',ids),collapse=',')
  ex(paste0('GRANT USAGE ON SCHEMA "',results,'" TO achilles_next_runner; GRANT SELECT ON ',
    tables(c('storage_version','profile_registry','validation_receipt',producer)),' TO achilles_next_runner; GRANT INSERT ON ',tables(producer),
    ' TO achilles_next_runner; GRANT UPDATE ON ',tables(c('analysis_run','result_release')),' TO achilles_next_runner'))
  snapshots<-list()
  for(one in input) {
    marker<-q(paste0("SELECT obj_description(oid,'pg_namespace') AS marker FROM pg_namespace WHERE nspname=",lit(one$schema)))$MARKER
    stopifnot(identical(marker,one$marker))
    generated<-generateCharacterizationCandidate(env$fixtureConnection(),one$schema,paste0('fixture:synthetic:',one$manifest_sha256),
      results,one$version,maxAggregateRows=50000L)
    stopifnot(generated$generated_metric_count=='142',generated$profile_complete,!generated$publishable)
    snapshot<-f('.store_transaction')(env$fixtureConnection(),results,function(tx) {
      datasets<-f('.store_datasets')(tx,generated$release_id);rows<-list()
      for(mid in names(datasets)) {
        rows[[mid]]<-list()
        f('.store_rows')(tx,generated$release_id,mid,function(row,key){rows[[mid]][[length(rows[[mid]])+1L]]<<-row})
      }
      list(datasets=datasets,rows=rows)
    })
    ex(paste0('REVOKE ALL ON SCHEMA "',one$schema,'" FROM achilles_next_runner'))
    denied<-tryCatch({
      f('.store_transaction')(env$fixtureConnection(),results,function(tx)tx$one(paste0('SELECT count(*)::text FROM "',one$schema,'".person')),readOnly=TRUE)
      FALSE
    },error=function(e)TRUE)
    stopifnot(denied)
    sealResultRelease(env$fixtureConnection('owner'),results,generated$release_id)
    validateResultRelease(env$fixtureConnection('owner'),results,generated$release_id)
    stopifnot(q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_current_publication'))$N=='0')
    snapshot$manifest_sha256<-one$manifest_sha256;snapshot$schema<-one$schema;snapshot$version<-one$version
    snapshot$validated<-TRUE;snapshot$producer_source_access_revoked<-TRUE
    snapshots[[length(snapshots)+1L]]<-snapshot
    cat('SYNTHETIC_PREVIEW_142_GENERATED_AND_NATIVE_VALIDATED ',one$version,'\n',sep='')
  }
  stopifnot(identical(implementation,implementationIdentity('.')))
  writeBin(wire(list(snapshots=snapshots,implementation=implementation)),file.path(out,'results.json'))
})
