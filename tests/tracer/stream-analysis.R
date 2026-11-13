# Compact completed-source handoff proof. No scale activation or publication.
library(AchillesNext)
source('tools/benchmark/implementation_identity.R')
source('tools/benchmark/matched_reference.R')
local({
  args<-commandArgs(TRUE);stopifnot(length(args)==2L)
  env<-new.env();sys.source(args[1],env);out<-normalizePath(args[2],mustWork=TRUE)
  python<-Sys.getenv('ACHILLES_NEXT_REFERENCE_PYTHON',unset='python3')
  stopifnot(system2(python,c('tools/source_analysis_handoff.py','inspect','--output-dir',shQuote(out)),stdout=FALSE)==0L)
  handoff<-jsonlite::fromJSON(file.path(out,'handoff.json'),simplifyVector=FALSE)
  compiled<-jsonlite::fromJSON(file.path(out,'reference.json'),simplifyVector=FALSE)
  stopifnot(grepl('^cdm_stream_[0-9a-f]{16}$',handoff$source_schema),identical(handoff$analysis_execution_authorized,FALSE),identical(handoff$qualifying,FALSE))
  # This contributor proof cannot turn a large handoff into execution permission.
  checkSource<-function() {
    stopifnot(dir.exists(handoff$stream_dir),!any(file.exists(file.path(handoff$stream_dir,c('STOP','dropped.json','active','active.json')))))
  }
  checkSource()
  counts<-unlist(handoff$table_rows);stopifnot(length(counts)<=64L,all(is.finite(counts)),all(counts>=0),sum(counts)<=20000,
    counts[['person']]<=1000,counts[['observation_period']]<=2000)
  f<-function(n)get(n,asNamespace('AchillesNext'));lit<-f('.store_literal');wire<-f('.v2_bytes')
  original<-implementationIdentity('.')
  toolFiles<-c('tools/source_analysis_handoff.py','tools/matched_reference_sql.py','tools/matched_reference_compare.py','tools/benchmark/matched_reference.R','tests/tracer/stream-analysis.R','tests/test_partition_stream_postgresql.py')
  toolPins<-function()stats::setNames(lapply(toolFiles,function(p)digest::digest(file=p,algo='sha256')),toolFiles)
  pinnedTools<-toolPins()
  owner<-DatabaseConnector::connect(env$fixtureConnection('owner'));on.exit(DatabaseConnector::disconnect(owner),add=TRUE)
  ex<-function(sql)DatabaseConnector::executeSql(owner,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,'sql-error.txt'))
  q<-function(sql)DatabaseConnector::querySql(owner,sql,integer64AsNumeric=FALSE)
  guard<-q("SELECT current_database() AS db,current_user AS usr,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB=='achilles_next_fixtures',guard$USR=='achilles_next_fixture_owner',guard$MARKER=='AchillesNext synthetic fixture sandbox v1')
  schema<-handoff$source_schema;s<-paste0('"',schema,'"')
  stopifnot(identical(q(paste0("SELECT obj_description(oid,'pg_namespace') AS marker FROM pg_namespace WHERE nspname=",lit(schema)))$MARKER,handoff$source_marker))
  # Verify physical counts in the same snapshot subsequently imported by both
  # unchanged analyzers. The source itself receives no row or permission writes.
  exporter<-NULL
  results<-paste0('achillesnext_stream_analysis_',Sys.getpid());serving<-paste0(results,'_serve');installed<-FALSE
  hadTemp<-q("SELECT has_database_privilege('achilles_next_runner',current_database(),'TEMPORARY')::text AS ok")$OK=='true'
  writeBin(wire(list(results_schema=results,serving_schema=serving,runner_had_temp=hadTemp,source_schema=schema)),file.path(out,'analysis-fixture-state.json'))
  on.exit({
    failures<-character();clean<-function(work)tryCatch(work(),error=function(e){failures<<-c(failures,conditionMessage(e))})
    if(!is.null(exporter)) {
      clean(function()rJava::.jcall(exporter@jConnection,'V','rollback'))
      clean(function()DatabaseConnector::disconnect(exporter))
    }
    if(installed)clean(function()ex(paste0('DROP SCHEMA "',serving,'","',results,'" CASCADE')))
    if(!hadTemp)clean(function()ex('REVOKE TEMPORARY ON DATABASE achilles_next_fixtures FROM achilles_next_runner'))
    if(length(failures))stop('Stream analysis fixture cleanup failed: ',paste(failures,collapse='; '))
  },add=TRUE,after=FALSE)
  stopifnot(!file.exists(file.path(out,'analysis-results.json')))
  if(!hadTemp)ex('GRANT TEMPORARY ON DATABASE achilles_next_fixtures TO achilles_next_runner')
  initializeResultStore(env$fixtureConnection('owner'),results,serving,schema);installed<-TRUE
  tables<-function(ids)paste(paste0('"',results,'".achillesnext_',ids),collapse=',')
  producer<-c('source_release','analysis_run','operation','result_release','dataset','aggregate_cell','denominator_edge')
  ex(paste0('GRANT USAGE ON SCHEMA "',results,'" TO achilles_next_runner; GRANT SELECT ON ',tables(c('storage_version','profile_registry','validation_receipt',producer)),
    ' TO achilles_next_runner; GRANT INSERT ON ',tables(producer),' TO achilles_next_runner; GRANT UPDATE ON ',tables(c('analysis_run','result_release')),' TO achilles_next_runner'))
  exporter<-DatabaseConnector::connect(env$fixtureConnection('owner'))
  rJava::.jcall(exporter@jConnection,'V','setAutoCommit',FALSE);rJava::.jcall(exporter@jConnection,'V','setTransactionIsolation',4L)
  snapshot<-referenceOne(exporter,'SELECT pg_export_snapshot()');witness<-referenceOne(exporter,'SELECT pg_current_snapshot()::text')
  for(table in names(handoff$table_rows))stopifnot(referenceOne(exporter,paste0('SELECT count(*)::text FROM ',s,'."',table,'"'))==as.character(handoff$table_rows[[table]]))
  capture<-function(candidate)f('.store_transaction')(env$fixtureConnection(),results,function(tx) {
    checkSource();datasets<-f('.store_datasets')(tx,candidate$release_id);rows<-list();n<-0L
    for(mid in names(datasets)) {
      rows[[mid]]<-list()
      f('.store_rows')(tx,candidate$release_id,mid,function(row,key){n<<-n+1L;stopifnot(n<=50000L);if(n%%256L==0L)checkSource();rows[[mid]][[length(rows[[mid]])+1L]]<<-row})
    }
    list(datasets=datasets,rows=rows,schema_sha256=f('.store_context')(tx,candidate$release_id)$observed_schema_sha256,
      source_id=handoff$source_id,version=handoff$cdm_version)
  })
  paths<-list();candidates<-list();witnesses<-new.env();witnesses$values<-character()
  for(path in c('optimized','reference')) {
    checkSource()
    cat('STREAM_ANALYSIS_GENERATE ',path,'\n',sep='')
    candidate<-if(path=='optimized')referenceOptimized(env$fixtureConnection(),schema,handoff$source_id,results,handoff$cdm_version,snapshot,witnesses) else
      referenceGenerate(env$fixtureConnection(),schema,handoff$source_id,results,handoff$cdm_version,compiled,snapshot,witnesses)
    stopifnot(candidate$generated_metric_count=='142',isTRUE(candidate$profile_complete),identical(candidate$publishable,FALSE))
    checkSource();paths[[path]]<-list(snapshot=capture(candidate));candidates[[path]]<-candidate
  }
  stopifnot(length(witnesses$values)==2L,all(witnesses$values==witness))
  writeBin(wire(list(columns=handoff$columns,table_rows=handoff$table_rows,denied_tables=list())),file.path(out,'source-model.json'))
  writeBin(wire(list(kind='source_inventory',table_rows=handoff$table_rows)),file.path(out,'source-expectations.json'))
  writeBin(wire(list(paths=paths,model='source-model.json',expectations='source-expectations.json')),file.path(out,'analysis-candidates.json'))
  stopifnot(system2(python,c('tools/matched_reference_compare.py',shQuote(file.path(out,'analysis-candidates.json'))))==0L)
  for(path in names(candidates)) {
    checkSource()
    sealResultRelease(env$fixtureConnection('owner'),results,candidates[[path]]$release_id)
    validateResultRelease(env$fixtureConnection('owner'),results,candidates[[path]]$release_id)
  }
  stopifnot(identical(original,implementationIdentity('.')),identical(pinnedTools,toolPins()))
  writeBin(wire(list(status='passed',handoff_sha256=handoff$handoff_sha256,source_id=handoff$source_id,
    implementation=original,tool_pins=pinnedTools,metric_count='142',numerical_metrics='138',imported_witnesses=as.list(witnesses$values),snapshot_witness=witness,
    candidates_natively_validated=TRUE,source_rows_and_grants_preserved=TRUE,published=FALSE,qualifying=FALSE,
    scope='compact handoff and matched generation/native validation; no large-tier execution or publication/telemetry qualification')),file.path(out,'analysis-results.json'))
  cat('STREAM_ANALYSIS_142_MATCHED_NATIVE_VALIDATION\n')
})
