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
  ex(paste0('GRANT USAGE ON SCHEMA "',results,'" TO achilles_next_runner; GRANT SELECT ON ',paste(qualified(c('profile_registry','validation_receipt',producerTables)),collapse=','),' TO achilles_next_runner; GRANT INSERT ON ',paste(qualified(producerTables),collapse=','),' TO achilles_next_runner; GRANT UPDATE ON ',paste(qualified(c('analysis_run','result_release')),collapse=','),' TO achilles_next_runner'))
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
    schema
  }
  inspect<-function(release) {
    rows<-list();context<-readMeasurementBaseline(env$fixtureConnection(),results,release,function(mid,row){rows[[mid]]<<-c(rows[[mid]],list(row))})
    for(mid in c(f('.population_ids')(),f('.domain_ids')(TRUE)))if(is.null(rows[[mid]]))rows[[mid]]<-list()
    stopifnot(context$generated_metric_count=='138',!context$profile_complete,!context$publishable,
      sum(vapply(context$inventory,function(m)m$state=='not_requested',TRUE))==4L)
    list(context=context,rows=rows)
  }
  for(index in seq_along(input)) {
    case<-input[[index]];schema<-makeSource(case,index)
    generated<-generateMeasurementBaseline(env$fixtureConnection(),schema,paste0('fixture:measurement:',case$case),results,case$version,maxAggregateRows=1e6)
    snap<-inspect(generated$release_id);snapshots[[length(snapshots)+1L]]<-c(list(case=case$case,version=case$version),snap)
    saved[[length(saved)+1L]]<-list(schema=schema,release=generated$release_id)
    stopifnot(q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==baselineTemp)
    writeLines(wire(list(snapshots=snapshots)),file.path(out,'partial-report.json'),useBytes=TRUE)
    cat('MEASUREMENT_GENERATED ',case$case,' ',case$version,'\n',sep='')
  }
  # Sorting every physical value is an independent exact quantile operator.
  ref<-generateMeasurementBaseline(env$fixtureConnection(),saved[[1]]$schema,'fixture:reference',results,input[[1]]$version,numericStrategy='reference')
  normal<-function(rows)lapply(rows,function(rs)sort(vapply(rs,wire,''),method='radix'))
  stopifnot(identical(normal(inspect(ref$release_id)$rows),normal(snapshots[[1]]$rows)))
  before<-q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N
  schema<-saved[[1]]$schema
  fails<-function(work) {
    error<-tryCatch({work();'accepted'},error=conditionMessage)
    stopifnot(error!='accepted',q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N==before,
      q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==baselineTemp)
  }
  generate<-function(...)generateMeasurementBaseline(env$fixtureConnection(),schema,'fixture:failure',results,'5.5',...)
  fails(function()generate(maxAggregateRows=1L));fails(function()generate(maxStageBytes=0))
  steps<-0L;fails(function()generate(check=function(){steps<<-steps+1L;if(steps==120L)stop('cancel during measurement reports')}))
  # Physical type checks run before a cast; preserve exact input after restoring.
  ex(paste0('ALTER TABLE "',schema,'".measurement ALTER COLUMN value_as_number TYPE double precision'))
  fails(function()generate())
  ex(paste0('ALTER TABLE "',schema,'".measurement ALTER COLUMN value_as_number TYPE numeric USING value_as_number::numeric'))
  definitions<-paste(paste0('"',names(input[[1]]$columns$measurement),'" ',unlist(input[[1]]$columns$measurement)),collapse=',')
  ex(paste0('TRUNCATE "',schema,'".measurement; INSERT INTO "',schema,'".measurement SELECT * FROM jsonb_to_recordset(',lit(wire(input[[1]]$tables$measurement)),'::jsonb) x(',definitions,')'))
  for(column in c('range_low','operator_concept_id')) {
    ex(paste0('ALTER TABLE "',schema,'".measurement RENAME COLUMN ',column,' TO hidden_',column));fails(function()generate())
    ex(paste0('ALTER TABLE "',schema,'".measurement RENAME COLUMN hidden_',column,' TO ',column))
  }
  ex(paste0('REVOKE SELECT ON "',schema,'".measurement FROM achilles_next_runner'));fails(function()generate())
  ex(paste0('GRANT SELECT ON "',schema,'".measurement TO achilles_next_runner'))
  # Corrupt a late new partition. No rows may escape before all validation passes.
  release<-saved[[1]]$release
  ex(paste0('UPDATE "',results,'".achillesnext_aggregate_cell SET record_count=record_count+1 WHERE ctid=(SELECT ctid FROM "',results,'".achillesnext_aggregate_cell WHERE release_id=',lit(release)," AND metric_id='core.measurement.range_status_count' LIMIT 1) AND release_id=",lit(release)," AND metric_id='core.measurement.range_status_count'"))
  emitted<-0L;error<-tryCatch({readMeasurementBaseline(env$fixtureConnection(),results,release,function(...){emitted<<-emitted+1L});'accepted'},error=conditionMessage)
  stopifnot(error!='accepted',emitted==0L)
  # Use the unmodified reference release for pinned saved selections/readback.
  page<-listDomainConcepts(env$fixtureConnection(),results,ref$release_id,'measurement',2L);tags<-page$concepts
  while(!is.null(page$next_cursor)){page<-listDomainConcepts(env$fixtureConnection(),results,ref$release_id,'measurement',2L,page$next_cursor);tags<-c(tags,page$concepts)}
  stopifnot(length(tags)==7L,any(vapply(tags,function(t)t$kind=='null',TRUE)))
  for(v in saved)ex(paste0('REVOKE ALL ON SCHEMA "',v$schema,'" FROM achilles_next_runner'))
  selected<-list();readMeasurementBaseline(env$fixtureConnection(),results,ref$release_id,function(mid,row){selected[[length(selected)+1L]]<<-row},
    'core.measurement.capture_count',list(kind='all'),list(period_kind='calendar_month',period_start='2020-01-01',period_end='2020-01-31'))
  stopifnot(length(selected)==1L)
  script<-file.path(out,'saved-reader.R')
  writeLines(c('library(AchillesNext);a<-commandArgs(TRUE);e<-new.env();sys.source(a[1],e);n<-0L;',
    'x<-readMeasurementBaseline(e$fixtureConnection(),a[2],a[3],function(mid,row){n<<-n+1L},"core.measurement.numeric_summary");stopifnot(n>0L,!x$publishable);',
    'p<-listDomainConcepts(e$fixtureConnection(),a[2],a[3],"measurement",1L);stopifnot(length(p$concepts)==1L);cat("SOURCE_DENIED_MEASUREMENT_READ_OK\\n")'),script)
  stopifnot(length(readLines(script))==3L);parse(script)
  stopifnot(system2(file.path(R.home('bin'),'Rscript'),c('--vanilla',shQuote(script),shQuote(normalizePath(args[1])),results,ref$release_id),stdout=file.path(out,'fresh-read.log'),stderr=file.path(out,'fresh-read-error.log'))==0L)
  error<-tryCatch({sealResultRelease(env$fixtureConnection('owner'),results,ref$release_id);'accepted'},error=conditionMessage)
  stopifnot(error!='accepted',q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_current_publication'))$N=='0')
  stopifnot(identical(implementation,implementationIdentity(getwd())))
  writeLines(wire(list(snapshots=snapshots,implementation=implementation,parity='passed',source_denied='passed',full_profile_gate='rejected',atomic_failures='passed')),file.path(out,'report.json'),useBytes=TRUE)
  cat('MEASUREMENT_138_OUTPUTS_REFERENCE_WEIGHTED_PARITY_SOURCE_DENIED_AND_ATOMIC_FAILURES_OK\n')
}
main()
