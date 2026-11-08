# Maintainer-labelled synthetic API walkthrough, not participant/UI acceptance.
# Run from the package checkout; optionally retain the fixture and transcript.
library(AchillesNext)
source('tests/tracer/saved-result-fixture.R')
source('tools/benchmark/implementation_identity.R')
local({
  args<-commandArgs(TRUE);stopifnot(length(args)<=1L)
  output<-if(length(args))args[[1]] else tempfile('saved-walkthrough-')
  if(file.exists(output)||dir.exists(output))stop('Walkthrough output must be new',call.=FALSE)
  stopifnot(dir.create(output,mode='0700'));output<-normalizePath(output)
  if(!length(args))on.exit(unlink(output,recursive=TRUE),add=TRUE)
  implementation<-implementationIdentity('.')
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');wire<-f('.v2_bytes')
  labels<-list('0'='Synthetic gender zero','123'='Demo condition','456'='Demo unit A',
               '9007199254740993'='Demo unit B','1'='Demo visit')
  x<-makeSavedResultFixture(file.path(output,'labelled'),savedLabels=labels,extraConceptIds='-1',saveCalendar=TRUE)
  old<-makeSavedResultFixture(file.path(output,'legacy'))
  # Full native admission precedes the synthetic host's exact-context approval.
  validateResultArtifact(x$directory);validateResultArtifact(old$directory)
  attempts<-0L;connect<-DatabaseConnector::connect
  assignInNamespace('connect',function(...){attempts<<-attempts+1L;stop('Unexpected database connection')},ns='DatabaseConnector')
  on.exit(assignInNamespace('connect',connect,ns='DatabaseConnector'),add=TRUE)
  active<-TRUE
  p<-openArtifactResultProvider(x$directory,x$context,function(c)active&&identical(c,x$context))
  legacy<-openArtifactResultProvider(old$directory,old$context,function(c)identical(c,old$context))
  on.exit({p$close();legacy$close()},add=TRUE)
  steps<-list()
  record<-function(id,persona,intent,method,arguments,response,interpretation) {
    stopifnot(!isTRUE(response$generation_requested))
    if(!is.null(response$budget))stopifnot(response$budget$objects<=64L,
      response$budget$bytes<=8388608L,response$budget$rows<=8192L)
    hasCursor<-!is.null(response$cursor)
    # Opaque cursors are reader-local; retain availability, not reusable tokens.
    response['cursor']<-list(NULL)
    if(!is.null(arguments$cursor))arguments$cursor<-'redacted_reader_local_cursor'
    if(is.function(arguments$cancel))arguments$cancel<-'always_true_test_predicate'
    steps[[length(steps)+1L]]<<-o(id=id,persona=persona,intent=intent,method=method,
      arguments=arguments,has_continuation=hasCursor,response=response,interpretation=interpretation)
    invisible(response)
  }
  select<-function(id,persona,intent,arguments,expected,interpretation) {
    response<-do.call(p$selectSavedRows,arguments);stopifnot(identical(response$state,expected))
    record(id,persona,intent,'selectSavedRows',arguments,response,interpretation)
    response
  }
  expectError<-function(id,method,arguments,code) {
    error<-tryCatch({do.call(p[[method]],arguments);NULL},error=identity)
    stopifnot(inherits(error,'achillesnext_read_error'),identical(error$code,code))
    record(id,'both','Stop or reject this interaction',method,arguments,
      o(state='error',code=error$code),'No successful page or new generation is returned.')
  }
  # Owner: discover the complete approved inventory without a whole-catalogue read.
  metrics<-list();cursor<-NULL;pages<-0L
  repeat {
    page<-p$listMetrics(limit=25L,cursor=cursor);pages<-pages+1L
    stopifnot(page$state=='available',length(page$metrics)<=25L)
    record(paste0('catalogue-',pages),'owner','Discover reports and saved filter capabilities',
      'listMetrics',o(limit=25L,continuation=!is.null(cursor)),page,
      'Capability describes supported shape; catalogue state describes this publication scope.')
    metrics<-c(metrics,page$metrics)
    if(page$complete)break
    cursor<-page$cursor
  }
  ids<-vapply(metrics,function(m)m$metric_id,'')
  stopifnot(length(ids)==142L,!anyDuplicated(ids),identical(ids,sort(names(f('.v2_assets')()$metrics),method='radix')))
  matrix<-stats::setNames(lapply(metrics,function(m)o(capability=m$capability,
    saved_state=m$state,reason_code=m$reason_code,saved_rows=m$rows)),ids)
  for(mid in ids)stopifnot(identical(matrix[[mid]]$capability,f('.saved_capability')(mid)))
  total<-select('population','owner','Read the saved PERSON baseline',list(metricId='core.person.count'),'available',
    '10 is the PERSON-table count in this synthetic publication, not an observed-only count.')
  stopifnot(total$rows[[1]]$values$person_count=='10')
  # Researcher: find a saved name, then carry its exact ID into a report filter.
  found<-p$searchConcepts(' DEMO CONDITION ',limit=1L)
  stopifnot(found$state=='available',found$searched,length(found$concepts)==1L,found$normalized_query=='demo condition')
  record('discover-concept','researcher','Find an approved saved concept name','searchConcepts',
    o(query=' DEMO CONDITION ',limit=1L),found,'ASCII-space trimming and ASCII case folding; prefix matching only.')
  concept<-found$concepts[[1]]$concept_tag;stopifnot(concept$value=='123')
  lookup<-p$lookupConcepts(c('-1','-2','123','777','9007199254740993'))
  record('exact-ids','researcher','Distinguish saved IDs, missing names and absent IDs','lookupConcepts',
    o(conceptIds=as.list(c('-1','-2','123','777','9007199254740993'))),lookup,
    'Missing names and not_saved IDs do not become concept zero or a zero count; large IDs stay strings.')
  byId<-stats::setNames(lookup$concepts,vapply(lookup$concepts,function(e)e$concept_tag$value,''))
  stopifnot(byId[['-1']]$state=='available',byId[['-1']]$label_state=='unavailable',
    byId[['-2']]$state=='not_saved',byId[['777']]$label_state=='unavailable',
    byId[['9007199254740993']]$concept_tag$value=='9007199254740993')
  period<-function(kind,start='null',end='null')o(period_kind=kind,period_start=start,period_end=end)
  capture<-function(p)c(o(concept_tag=concept),p)
  allTime<-select('condition-full','researcher','Read full-scope condition capture',
    list(metricId='core.condition.capture_count',filters=capture(period('full_scope'))),'available',
    '4 records and 3 distinct people are already computed; the provider performs no join or regrouping.')
  stopifnot(allTime$rows[[1]]$values$record_count=='4',allTime$rows[[1]]$values$person_count=='3')
  for(month in list(c('01','31'),c('02','29'))) {
    response<-select(paste0('condition-month-',month[[1]]),'researcher','Select an exact saved month',
      list(metricId='core.condition.capture_count',filters=capture(period('calendar_month',paste0('2020-',month[[1]],'-01'),paste0('2020-',month[[1]],'-',month[[2]])))),'available',
      '2 records and 2 people in this saved month; do not sum monthly distinct people to obtain the full-scope total.')
    stopifnot(response$rows[[1]]$values$record_count=='2',response$rows[[1]]$values$person_count=='2')
  }
  select('unsaved-month','researcher','Ask for a valid but absent saved month',
    list(metricId='core.condition.capture_count',filters=capture(period('calendar_month','2020-03-01','2020-03-31'))),'not_saved',
    'This approved fixture has no such row. Absence is not a measured zero.')
  select('unsaved-window','researcher','Ask for an arbitrary unsaved date window',
    list(metricId='core.condition.capture_count',filters=capture(period('calendar_month','2020-01-02','2020-01-31'))),'additional_batch_job_required',
    'An operator would need separate approved batch work; no query is sent to the CDM.')
  select('population-switch','owner','Ask for an observed-only population on an all-recorded metric',
    list(metricId='core.condition.capture_count',population='observed_rows'),'additional_batch_job_required',
    'Select a separately saved observed metric if available; changing a population is not an interactive restriction.')
  select('joint-filter','researcher','Ask for condition by gender when that joint grain was not saved',
    list(metricId='core.condition.capture_count',filters=o(gender_concept_id='0')),'additional_batch_job_required',
    'Separate marginal counts do not authorize constructing a joint distribution.')
  dims<-o(concept_tag=concept,unit_concept_tag=o(kind='id',value='456'),raw_operator_tag=o(kind='null'))
  summary<-select('measurement-unit','researcher','Select one saved measurement unit/operator stratum',
    list(metricId='core.measurement.numeric_summary',filters=dims),'available',
    'The saved p50 is 2.5; the exact mean remains 20.5/6. Do not average percentiles or pool units.')
  stopifnot(length(summary$rows)==1L,summary$rows[[1]]$values$p50=='2.5',
    summary$rows[[1]]$values$mean_numerator=='20.5',summary$rows[[1]]$values$mean_denominator=='6',
    length(summary$dependencies)==1L,summary$dependencies[[1]]$row$values$record_count=='6')
  dims$unit_concept_tag$value<-'9007199254740993'
  other<-select('measurement-other-unit','researcher','Change to another saved unit without pooling',
    list(metricId='core.measurement.numeric_summary',filters=dims),'available','A separate saved stratum, with the original exact unit ID.')
  stopifnot(other$rows[[1]]$dimensions$unit_concept_tag$value=='9007199254740993')
  dims$unit_concept_tag$value<-'456';dims$raw_operator_tag<-o(kind='id',value='0')
  select('unsaved-operator','researcher','Distinguish saved NULL from a zero raw operator',
    list(metricId='core.measurement.numeric_summary',filters=dims),'not_saved','NULL and ID zero are different saved strata; neither is substituted for the other.')
  dims$raw_operator_tag<-o(kind='null')
  dims$unit_concept_tag$value<-'777'
  empty<-select('empty-summary','researcher','Inspect an eligible population of zero',
    list(metricId='core.measurement.numeric_summary',filters=dims),'available','n=0 and p50=NULL means empty_population; the median is not zero.')
  stopifnot(empty$rows[[1]]$state=='empty_population',empty$rows[[1]]$values$n=='0',is.null(empty$rows[[1]]$values$p50))
  select('monthly-summary','researcher','Ask for a monthly percentile that was not saved',
    list(metricId='core.measurement.numeric_summary',filters=period('calendar_month','2020-01-01','2020-01-31')),'additional_batch_job_required',
    'The full-scope saved summary cannot be reinterpreted as a monthly summary.')
  suppressed<-select('scope-omitted','owner','Inspect a drug report omitted by this fixture policy',
    list(metricId='core.drug.capture_count'),'suppressed','No rows returned; suppressed output is not an empty domain.')
  stopifnot(!length(suppressed$rows))
  specimen<-select('empty-source','owner','Inspect an explicitly saved empty specimen source',
    list(metricId='core.specimen.capture_count'),'available','empty_source is recorded separately from policy omission and missing rows.')
  stopifnot(specimen$rows[[1]]$state=='empty_source',specimen$rows[[1]]$values$record_count=='0')
  visit<-select('schema-absent','owner','Inspect care-setting data unavailable because of schema capability',
    list(metricId='core.visit.care_setting_count'),'available','schema_absent and unavailable values are not a concept ID or zero count.')
  stopifnot(visit$rows[[1]]$state=='unavailable',visit$rows[[1]]$dimensions$setting_concept_tag$kind=='schema_absent',is.null(visit$rows[[1]]$values))
  zero<-select('computed-zero','researcher','Inspect a saved computed count of zero',
    list(metricId='core.person.gender_count',filters=o(gender_concept_id='-1')),'available','An explicit computed zero is different from a missing saved stratum.')
  stopifnot(zero$rows[[1]]$state=='computed',zero$rows[[1]]$values$person_count=='0')
  oldSearch<-legacy$searchConcepts('Demo')
  stopifnot(oldSearch$state=='unavailable',!oldSearch$searched,oldSearch$reason_code=='terminology.name_index_not_saved')
  record('legacy-search','researcher','Open original2.0.0 data without an approved name index','searchConcepts',o(query='Demo'),oldSearch,
    'The completed availability response is not a completed empty search; no live vocabulary fallback.')
  # Errors invalidate cursors. Fetch a new page after changing any request filter.
  first<-p$selectSavedRows('core.person.gender_count',maxRows=1L)
  record('pagination-first','researcher','Start a bounded saved-row traversal','selectSavedRows',
    o(metricId='core.person.gender_count',maxRows=1L),first,'Continue only with the same arguments and reader context.')
  cursor<-first$cursor;genderKeys<-first$rows[[1]]$row_key;pageNumber<-1L
  while(!is.null(cursor)) {
    arguments<-list(metricId='core.person.gender_count',maxRows=1L,cursor=cursor)
    page<-do.call(p$selectSavedRows,arguments);pageNumber<-pageNumber+1L
    record(paste0('pagination-',pageNumber),'researcher','Continue the same bounded saved selection',
      'selectSavedRows',arguments,page,'The next saved row is returned without offset paging or recomputation.')
    genderKeys<-c(genderKeys,page$rows[[1]]$row_key);cursor<-page$cursor
  }
  stopifnot(length(genderKeys)==3L,!anyDuplicated(genderKeys))
  expectError('stale-selection','selectSavedRows',list(metricId='core.person.gender_count',filters=o(gender_concept_id='0'),maxRows=1L,cursor=first$cursor),'invalid_cursor')
  expectError('response-limit','selectSavedRows',list(metricId='core.person.count',maxBytes=10L),'resource_limit')
  expectError('cancel','selectSavedRows',list(metricId='core.person.count',cancel=function()TRUE),'aborted')
  active<-FALSE
  expectError('authority-loss','selectSavedRows',list(metricId='core.person.count'),'inaccessible')
  active<-TRUE
  p$close();p$close()
  expectError('closed','selectSavedRows',list(metricId='core.person.count'),'closed')
  stopifnot(attempts==0L,p$inspect()$closed)
  writeBin(wire(o(profile_id=x$context$profile_id,profile_sha256=x$context$profile_sha256,
    reports=matrix)),file.path(output,'report-filter-matrix.json'))
  writeBin(wire(o(kind='synthetic_maintainer_api_walkthrough',status='passed',
    execution='automated',human_participants=0L,human_completion_time_seconds=NULL,
    qualification='Not participant, clinical, browser, ATLAS or representative-scale acceptance',
    implementation=implementation,admitted_context=x$context,source_connection_attempts=attempts,
    catalogue_pages=pages,report_count=length(ids),steps=steps)),file.path(output,'walkthrough.json'))
  cat('SAVED_WALKTHROUGH_142_REPORTS_DISCOVERY_FILTER_STATES_NO_SOURCE_OK steps=',length(steps),'\n')
})
