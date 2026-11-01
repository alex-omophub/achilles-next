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
    collected<-list();context<-readDomainBaseline(env$fixtureConnection(),results,release,function(mid,row){collected[[mid]]<<-c(collected[[mid]],list(row))})
    for(mid in c(f('.population_ids')(),f('.domain_ids')()))if(is.null(collected[[mid]]))collected[[mid]]<-list()
    stopifnot(!context$profile_complete,!context$publishable,context$generated_metric_count=='119',length(context$inventory)==142L,
      sum(vapply(context$inventory,function(m)m$state=='not_requested',TRUE))==23L)
    list(context=context,rows=collected)
  }
  for(index in seq_along(input)) {
    case<-input[[index]];schema<-makeSource(case,index)
    generated<-generateDomainBaseline(env$fixtureConnection(),schema,paste0('fixture:domain:',case$case),results,case$version)
    snap<-inspect(generated$release_id)
    snapshots[[length(snapshots)+1L]]<-c(list(case=case$case,version=case$version),snap)
    saved[[length(saved)+1L]]<-list(schema=schema,release=generated$release_id)
    stopifnot(q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==baselineTemp)
    writeLines(wire(list(snapshots=snapshots,implementation=implementation)),file.path(out,'partial-report.json'),useBytes=TRUE)
    cat('GENERATED ',case$case,' ',case$version,'\n',sep='')
  }
  # Budget checks use the small empty-source release to keep CI inexpensive.
  emptyIndex<-which(vapply(input,function(c)c$case=='empty_source'&&c$version=='5.5',TRUE))[1]
  mid<-'core.person.count';sample<-snapshots[[emptyIndex]]$rows[[mid]][[1]]
  size<-length(serialize(list(metric_id=mid,row=sample),NULL,version=3,xdr=FALSE));emitted<-0L
  readDomainBaseline(env$fixtureConnection(),results,saved[[emptyIndex]]$release,function(id,row){stopifnot(identical(wire(row),wire(sample)));emitted<<-emitted+1L},mid,maxSpoolBytes=size)
  stopifnot(emitted==1L)
  emitted<-0L
  error<-tryCatch({readDomainBaseline(env$fixtureConnection(),results,saved[[emptyIndex]]$release,function(...){emitted<<-emitted+1L},mid,maxSpoolBytes=size-1L);'accepted'},error=conditionMessage)
  stopifnot(grepl('Read spool byte limit exceeded',error,fixed=TRUE),emitted==0L,
    length(Sys.glob(file.path(tempdir(),'achillesnext-read-*')))==0L)
  # Page exact stored concept identities, including NULL/0/unknown, but not ALL.
  page<-listDomainConcepts(env$fixtureConnection(),results,saved[[1]]$release,'condition',2)
  tags<-page$concepts;cursor<-page$next_cursor
  while(!is.null(cursor)) {
    page<-listDomainConcepts(env$fixtureConnection(),results,saved[[1]]$release,'condition',2,cursor)
    tags<-c(tags,page$concepts);cursor<-page$next_cursor
  }
  stopifnot(length(tags)==7L,any(vapply(tags,function(t)t$kind=='null',TRUE)),!any(vapply(tags,function(t)t$kind=='all',TRUE)))
  page<-listDomainConcepts(env$fixtureConnection(),results,saved[[1]]$release,'condition',1)
  error<-tryCatch({listDomainConcepts(env$fixtureConnection(),results,saved[[2]]$release,'condition',1,page$next_cursor);'accepted'},error=conditionMessage)
  stopifnot(error!='accepted')
  selected<-list()
  readDomainBaseline(env$fixtureConnection(),results,saved[[1]]$release,function(mid,row){selected[[length(selected)+1L]]<<-row},
    'core.condition.capture_count',list(kind='all'),list(period_kind='calendar_month',period_start='2020-01-01',period_end='2020-01-31'))
  stopifnot(length(selected)==1L,selected[[1]]$values$person_count=='3')
  emitted<-0L
  error<-tryCatch({readDomainBaseline(env$fixtureConnection(),results,saved[[1]]$release,function(mid,row){emitted<<-emitted+1L},
    'core.condition.capture_count',period=list(period_kind='calendar_month',period_start='2020-01-02',period_end='2020-01-03'));'accepted'},error=conditionMessage)
  stopifnot(grepl('generation is required',error,fixed=TRUE),emitted==0L)
  # Whole-history summaries/source marginals cannot silently accept calendars.
  for(mid in c('core.drug.quantity_summary','core.condition.source_count')) {
    emitted<-0L
    error<-tryCatch({readDomainBaseline(env$fixtureConnection(),results,saved[[1]]$release,function(mid,row){emitted<<-emitted+1L},mid,
      period=list(period_kind='calendar_month',period_start='2020-01-01',period_end='2020-01-31'));'accepted'},error=conditionMessage)
    stopifnot(grepl('generation is required',error,fixed=TRUE),emitted==0L)
  }
  # Every selected metric must support the exact period, before any output.
  for(metrics in list('observed.condition.capture_count',c('core.condition.capture_count','observed.condition.capture_count'))) {
    emitted<-0L
    error<-tryCatch({readDomainBaseline(env$fixtureConnection(),results,saved[[1]]$release,function(mid,row){emitted<<-emitted+1L},metrics,
      period=list(period_kind='undated',period_start='null',period_end='null'));'accepted'},error=conditionMessage)
    stopifnot(grepl('generation is required',error,fixed=TRUE),emitted==0L)
  }
  # Named R vectors have the same array-shaped selector metadata as plain input.
  named<-readDomainBaseline(env$fixtureConnection(),results,saved[[1]]$release,function(mid,row){},
    c(label='core.condition.capture_count'),list(kind='all'),list(period_kind='undated',period_start='null',period_end='null'))
  stopifnot(is.null(names(named$selection$metric_ids)),grepl('"metric_ids":[',wire(named$selection),fixed=TRUE))
  # Required table/column/capability errors are atomic, never false empty data.
  case<-input[[3]];schema<-makeSource(case,100L)
  before<-q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N
  fails<-function(work) {
    error<-tryCatch({work();'accepted'},error=conditionMessage)
    stopifnot(error!='accepted',q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N==before,
      q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==baselineTemp)
  }
  generate<-function(...)generateDomainBaseline(env$fixtureConnection(),schema,'fixture:domain-failure',results,'5.5',...)
  fails(function()generate(maxStageBytes=0))
  steps<-0L;fails(function()generate(check=function(){steps<<-steps+1L;if(steps==90L)stop('cancel during output stages')}))
  ex(paste0('ALTER TABLE "',schema,'".visit_occurrence ADD COLUMN admitting_source_concept_id bigint; UPDATE "',schema,'".visit_occurrence SET admitting_source_concept_id=999'))
  fails(function()generate())
  ex(paste0('ALTER TABLE "',schema,'".visit_occurrence DROP COLUMN admitting_source_concept_id'))
  ex(paste0('INSERT INTO "',schema,'".concept VALUES(100,\'Drug\')'))
  fails(function()generate())
  ex(paste0('DELETE FROM "',schema,'".concept WHERE concept_id=100 AND domain_id=\'Drug\''))
  for(id in c(100L,200L)) {
    ex(paste0('INSERT INTO "',schema,'".concept VALUES(',id,',NULL)'));fails(function()generate());ex(paste0('DELETE FROM "',schema,'".concept WHERE concept_id=',id,' AND domain_id IS NULL'))
  }
  ex(paste0('REVOKE SELECT ON "',schema,'".drug_exposure FROM achilles_next_runner'))
  fails(function()generate())
  ex(paste0('GRANT SELECT ON "',schema,'".drug_exposure TO achilles_next_runner'))
  ex(paste0('ALTER TABLE "',schema,'".death RENAME TO hidden_death')); fails(function()generate()); ex(paste0('ALTER TABLE "',schema,'".hidden_death RENAME TO death'))
  ex(paste0('ALTER TABLE "',schema,'".observation DROP COLUMN qualifier_concept_id'))
  fails(function()generate())
  ex(paste0('ALTER TABLE "',schema,'".observation ADD COLUMN qualifier_concept_id bigint'))
  declaredOther<-generateDomainBaseline(env$fixtureConnection(),schema,'fixture:declared-other',results,'5.3')
  declaredOtherContext<-inspect(declaredOther$release_id)$context
  stopifnot(declaredOtherContext$inventory[['core.specimen.visit_link_presence_count']]$state=='computed')
  # Only place-of-service becomes unavailable when optional CARE_SITE is denied.
  ex(paste0('REVOKE SELECT ON "',schema,'".care_site FROM achilles_next_runner'))
  denied<-generate();deniedRows<-inspect(denied$release_id)$rows[['core.visit.care_setting_count']]
  stopifnot(all(vapply(Filter(function(r)r$dimensions$setting_kind=='place_of_service',deniedRows),function(r)r$state=='unavailable'&&is.null(r$values),TRUE)),
    all(vapply(Filter(function(r)r$dimensions$setting_kind!='place_of_service',deniedRows),function(r)r$state=='computed',TRUE)))
  careCases[[length(careCases)+1L]]<-list(reason='capability.care_site_denied',rows=deniedRows)
  ex(paste0('GRANT SELECT ON "',schema,'".care_site TO achilles_next_runner; INSERT INTO "',schema,'".care_site VALUES(1,999)'))
  ambiguous<-generate();ambiguousRows<-inspect(ambiguous$release_id)$rows[['core.visit.care_setting_count']]
  stopifnot(any(vapply(ambiguousRows,function(r)identical(r$reason_code,'capability.care_site_ambiguous'),TRUE)))
  careCases[[length(careCases)+1L]]<-list(reason='capability.care_site_ambiguous',rows=ambiguousRows)
  ex(paste0('DROP TABLE "',schema,'".care_site'))
  absent<-generate();absentRows<-inspect(absent$release_id)$rows[['core.visit.care_setting_count']]
  stopifnot(any(vapply(absentRows,function(r)r$state=='unsupported'&&is.null(r$values),TRUE)))
  careCases[[length(careCases)+1L]]<-list(reason='capability.care_site_absent',rows=absentRows)
  # A new source row yields a new release; the old saved results stay unchanged.
  oldRows<-inspect(saved[[3]]$release)$rows
  ex(paste0('INSERT INTO "',saved[[3]]$schema,'".condition_occurrence SELECT * FROM "',saved[[3]]$schema,'".condition_occurrence LIMIT 1'))
  changed<-generateDomainBaseline(env$fixtureConnection(),saved[[3]]$schema,'fixture:changed',results,'5.5')
  stopifnot(changed$release_id!=saved[[3]]$release,identical(wire(oldRows),wire(inspect(saved[[3]]$release)$rows)))
  # Read and concept/date selection work in another process with all CDM denied.
  for(v in saved)ex(paste0('REVOKE ALL ON SCHEMA "',v$schema,'" FROM achilles_next_runner'))
  script<-file.path(out,'offline-reader.R')
  writeLines(c('library(AchillesNext);a<-commandArgs(TRUE);e<-new.env();sys.source(a[1],e);n<-0L;',
    'x<-readDomainBaseline(e$fixtureConnection(),a[2],a[3],function(mid,row){n<<-n+1L},"core.condition.capture_count",list(kind="all"),list(period_kind="calendar_year",period_start="2020-01-01",period_end="2020-12-31"));stopifnot(n==1L,!x$publishable);',
    'p<-listDomainConcepts(e$fixtureConnection(),a[2],a[3],"condition",1);stopifnot(length(p$concepts)==1L);cat("SOURCE_DENIED_DOMAIN_READ_OK\\n")'),script)
  stopifnot(system2(file.path(R.home('bin'),'Rscript'),c('--vanilla',shQuote(script),shQuote(normalizePath(args[1])),results,saved[[1]]$release),stdout=file.path(out,'fresh-read.log'),stderr=file.path(out,'fresh-read-error.log'))==0L)
  error<-tryCatch({sealResultRelease(env$fixtureConnection('owner'),results,saved[[1]]$release);'accepted'},error=conditionMessage)
  stopifnot(error!='accepted',q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_current_publication'))$N=='0')
  stopifnot(identical(implementation,implementationIdentity(getwd())))
  writeLines(wire(list(snapshots=snapshots,care_cases=careCases,implementation=implementation,source_denied='passed',full_profile_gate='rejected',atomic_failures='passed')),file.path(out,'report.json'),useBytes=TRUE)
  cat('PASS: 119 persisted outputs; bounded concept paging; source-denied saved selection; atomic failures; incomplete publication gate\n')
}
main()
