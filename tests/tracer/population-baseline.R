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
  results<-paste0('achillesnext_population_',Sys.getpid());serving<-paste0('achillesnext_popserve_',Sys.getpid())
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
  snapshots<-list();saved<-list();baselineTemp<-q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N
  makeSource<-function(case,version,index) {
    schema<-paste0('cdm_tiny_population_',Sys.getpid(),'_',index,'_',gsub('.','',version,fixed=TRUE));sources<<-c(sources,schema)
    ex(paste0('CREATE SCHEMA "',schema,'"; COMMENT ON SCHEMA "',schema,'" IS \'AchillesNext synthetic fixture sandbox v1: population\''))
    table<-function(n)paste0('"',schema,'".',n)
    ex(paste0('CREATE TABLE ',table('person'),'(person_id bigint,year_of_birth bigint,gender_concept_id bigint,race_concept_id bigint,ethnicity_concept_id bigint); CREATE TABLE ',table('observation_period'),'(person_id bigint,observation_period_start_date date,observation_period_end_date date,period_type_concept_id bigint)'))
    for(n in c('person','observation_period')) {
      definitions<-if(n=='person')'person_id bigint,year_of_birth bigint,gender_concept_id bigint,race_concept_id bigint,ethnicity_concept_id bigint' else 'person_id bigint,observation_period_start_date date,observation_period_end_date date,period_type_concept_id bigint'
      ex(paste0('INSERT INTO ',table(n),' SELECT * FROM jsonb_to_recordset(',lit(wire(case[[n]])),'::jsonb) x(',definitions,')'))
    }
    ex(paste0('GRANT USAGE ON SCHEMA "',schema,'" TO achilles_next_runner; GRANT SELECT ON ALL TABLES IN SCHEMA "',schema,'" TO achilles_next_runner'))
    schema
  }
  inspect<-function(release) {
    collected<-list();context<-readPopulationObservationBaseline(env$fixtureConnection(),results,release,function(mid,row){collected[[mid]]<<-c(collected[[mid]],list(row))})
    for(mid in f('.population_ids')())if(is.null(collected[[mid]]))collected[[mid]]<-list()
    stopifnot(!context$profile_complete,!context$publishable,context$generated_metric_count=='19',length(context$inventory)==142L,
      sum(vapply(context$inventory,function(m)m$state=='not_requested',TRUE))==123L)
    list(context=context,rows=collected)
  }
  count<-0L
  for(version in c('5.3','5.4','5.5'))for(case in input) {
    count<-count+1L;schema<-makeSource(case,version,count)
    generated<-generatePopulationObservationBaseline(env$fixtureConnection(),schema,paste0('fixture:population:',case$id),results,version,case$window)
    stopifnot(generated$state=='building',!generated$publishable)
    snapshots[[length(snapshots)+1L]]<-c(list(case=case$id,version=version),inspect(generated$release_id))
    saved[[length(saved)+1L]]<-list(schema=schema,release=generated$release_id)
    stopifnot(q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==baselineTemp)
  }
  # A building baseline has no policy suppression. A valid wire row is not
  # necessarily a valid producer row inside a computed baseline dataset.
  mid<-'core.observation_period.boundary_month_count'
  original<-snapshots[[1]]$rows[[mid]][[1]]
  target<-paste0(' WHERE release_id=',lit(saved[[1]]$release),' AND metric_id=',lit(mid),' AND row_key=',lit(original$row_key))
  for(state in c('suppressed','empty_source','empty_population')) {
    value<-if(state=='suppressed')'NULL' else '0'
    ex(paste0('UPDATE "',results,'".achillesnext_aggregate_cell SET state=',lit(state),",reason_code='fixture.invalid_baseline_state',interval_count=",value,',person_count=',value,target))
    emitted<-0L
    error<-tryCatch({readPopulationObservationBaseline(env$fixtureConnection(),results,saved[[1]]$release,function(mid,row){emitted<<-emitted+1L});'accepted'},error=conditionMessage)
    stopifnot(grepl('Saved row state is inconsistent',error,fixed=TRUE),emitted==0L)
    ex(paste0('UPDATE "',results,"\".achillesnext_aggregate_cell SET state='computed',reason_code=NULL,interval_count=",original$values$interval_count,',person_count=',original$values$person_count,target))
  }
  # Genuine all-ineligible summaries remain readable in a computed dataset.
  stopifnot(any(vapply(snapshots[[1]]$rows[['core.observation_period.first_age_summary']],function(row)row$row_kind=='summary'&&row$state=='empty_population'&&identical(row$values$n,'0'),TRUE)))
  inspect(saved[[1]]$release)
  # Source access is revoked while saved readback is replayed in a fresh process.
  for(v in saved)ex(paste0('REVOKE ALL ON SCHEMA "',v$schema,'" FROM achilles_next_runner'))
  script<-file.path(out,'offline-reader.R')
  writeLines(c('library(AchillesNext); a<-commandArgs(TRUE); e<-new.env();sys.source(a[1],e); rows<-0L;',
    'x<-readPopulationObservationBaseline(e$fixtureConnection(),a[2],a[3],function(mid,row){rows<<-rows+1L});stopifnot(rows>0L,!x$publishable);cat("SOURCE_DENIED_FRESH_PROCESS_READ_OK\\n")'),script)
  stopifnot(system2(file.path(R.home('bin'),'Rscript'),c('--vanilla',shQuote(script),shQuote(normalizePath(args[1])),results,saved[[1]]$release),stdout=file.path(out,'fresh-read.log'),stderr=file.path(out,'fresh-read-error.log'))==0L)
  # Full-profile completeness/publication remains closed, never false suppression.
  error<-tryCatch({sealResultRelease(env$fixtureConnection('owner'),results,saved[[1]]$release);'accepted'},error=conditionMessage)
  stopifnot(error!='accepted',q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_current_publication'))$N=='0')
  # Failure checks use an independent new tiny source; every attempt is atomic.
  case<-Filter(function(c)c$id=='adversarial',input)[[1]];schema<-makeSource(case,'5.5',count+1L)
  before<-q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N
  fails<-function(work) {
    error<-tryCatch({work();'accepted'},error=conditionMessage)
    stopifnot(error!='accepted',q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N==before,
      q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==baselineTemp)
  }
  generate<-function(...)generatePopulationObservationBaseline(env$fixtureConnection(),schema,'fixture:failure',results,'5.5',...)
  fails(function()generate(maxStageBytes=0))
  steps<-0L;fails(function()generate(check=function(){steps<<-steps+1L;if(steps==8L)stop('cancel')}))
  steps<-0L;fails(function()generate(check=function(){steps<<-steps+1L;if(steps==30L)stop('cancel during aggregate write')}))
  old<-generate();oldRows<-inspect(old$release_id)$rows
  ex(paste0('INSERT INTO "',schema,'".observation_period VALUES(1,DATE \'2018-01-01\',DATE \'2018-01-01\',0)'))
  refreshed<-generate();newData<-inspect(refreshed$release_id)
  stopifnot(old$release_id!=refreshed$release_id,identical(wire(oldRows),wire(inspect(old$release_id)$rows)),newData$context$observed_window$start=='2018-01-01')
  before<-q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N
  ex(paste0('INSERT INTO "',schema,'".observation_period VALUES(1,\'infinity\'::date,\'infinity\'::date,0)'))
  fails(function()generate())
  ex(paste0('DELETE FROM "',schema,'".observation_period WHERE observation_period_start_date=\'infinity\'::date'))
  ex(paste0('INSERT INTO "',schema,'".person SELECT * FROM "',schema,'".person LIMIT 1'))
  fails(function()generate())
  ex(paste0('DELETE FROM "',schema,'".person WHERE ctid=(SELECT ctid FROM "',schema,'".person ORDER BY ctid DESC LIMIT 1)'))
  ex(paste0('ALTER TABLE "',schema,'".person DROP COLUMN race_concept_id'))
  fails(function()generate())
  stopifnot(identical(implementation,implementationIdentity(getwd())))
  writeLines(wire(list(snapshots=snapshots,implementation=implementation,cleanup='temporary_stage_cleanup_checked',full_profile_gate='rejected',fresh_source_denied_read='passed',failure_tests='budget,cancellation,duplicate_PERSON,missing_column_roll_back')),file.path(out,'report.json'),useBytes=TRUE)
  cat('PASS: 19 generated/persisted results; three declared schema versions; source-denied readback; incomplete publication gate; atomic failures\n')
}
main()
