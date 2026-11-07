# Structural selection and joint-grain checks; no source/store/provider reads.
library(AchillesNext)
local({
  attempts<-0L;connect<-DatabaseConnector::connect
  assignInNamespace('connect',function(...){attempts<<-attempts+1L;stop('Unexpected database connection')},ns='DatabaseConnector')
  on.exit(assignInNamespace('connect',connect,ns='DatabaseConnector'),add=TRUE)
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');request<-f('.saved_selection');cap<-f('.saved_capability')
  matrix<-f('.saved_capabilities')();stopifnot(length(matrix)==142L,identical(names(matrix),sort(names(matrix),method='radix')))
  for(mid in names(matrix)) {
    stopifnot(request(mid)$state=='selection_shape_supported',!request(mid)$generation_requested,
      matrix[[mid]]$availability=='requires_approved_catalogue',matrix[[mid]]$transformations=='none')
  }
  period<-function(kind,start='null',end='null')o(period_kind=kind,period_start=start,period_end=end)
  concept<-o(concept_tag=o(kind='id',value='9007199254740993'))
  query<-request('core.condition.capture_count',c(concept,period('calendar_month','2020-02-01','2020-02-29')))
  stopifnot(query$state=='selection_shape_supported',query$request$filters$concept_tag$value=='9007199254740993',
    cap('core.condition.capture_count')$population=='all_recorded_rows',cap('observed.condition.capture_count')$population=='observed_rows')
  reversed<-request('core.condition.capture_count',rev(c(concept,period('calendar_month','2020-02-01','2020-02-29'))))
  stopifnot(query$request_sha256==reversed$request_sha256)
  for(kind in c('full_scope','undated'))stopifnot(request('core.condition.capture_count',period(kind))$state=='selection_shape_supported')
  stopifnot(request('core.condition.capture_count',period('calendar_year','2020-01-01','2020-12-31'))$state=='selection_shape_supported')
  for(bounds in list(c('1900-02-01','1900-02-28'),c('2000-02-01','2000-02-29'),c('2100-02-01','2100-02-28')))
    stopifnot(request('core.condition.capture_count',period('calendar_month',bounds[1],bounds[2]))$state=='selection_shape_supported')
  summary<-request('core.measurement.numeric_summary',o(unit_concept_tag=o(kind='id',value='9007199254740993'),raw_operator_tag=o(kind='null')),rowKind='summary')
  stopifnot(summary$state=='selection_shape_supported',cap('core.measurement.numeric_summary')$time=='not_saved',
    cap('core.measurement.numeric_summary')$summary=='saved_summary_only')
  eligibility<-request('core.measurement.numeric_summary',o(eligibility_reason='eligible'),rowKind='eligibility_counts')
  stopifnot(eligibility$state=='selection_shape_supported',
    request('core.measurement.numeric_summary',o(eligibility_reason='eligible'))$reason_code=='selection.dimensions_not_saved')
  unsupported<-list(
    request('core.measurement.numeric_summary',period('calendar_month','2020-01-01','2020-01-31')),
    request('core.condition.capture_count',o(gender_concept_id='8507')),
    request('core.person.gender_count',o(year='2020')),
    request('core.condition.capture_count',o(unit_concept_tag=o(kind='id',value='1'))),
    request('core.condition.capture_count',population='observed_rows'),
    request('core.person.count',rowKind='summary'),
    request('core.condition.capture_count',period('calendar_month','2020-02-02','2020-02-29')),
    request('core.condition.capture_count',period('full_scope','2020-01-01','2020-02-29')))
  stopifnot(all(vapply(unsupported,function(x)x$state=='additional_batch_job_required'&&!x$generation_requested,TRUE)))
  rejects<-function(work)stopifnot(inherits(try(work(),silent=TRUE),'try-error'))
  rejects(function()request('unknown.metric'))
  rejects(function()request('core.person.count',list()))
  rejects(function()request('core.person.gender_count',o(gender_concept_id=9007199254740992)))
  rejects(function()request('core.condition.capture_count',o(concept_tag=o(kind='id',value='01'))))
  rejects(function()request('core.condition.capture_count',o(period_kind='calendar_month')))
  rejects(function()request('core.condition.capture_count',period('calendar_month','2021-02-01','2021-02-29')))
  rejects(function()request('core.observation_period.year_gender_age_count',o(year_age_decile='14')))
  rejects(function()request('core.observation_period.boundary_month_count',o(month='2020-01-15')))
  rejects(function()request('core.measurement.range_status_count',o(reason='unregistered_reason')))
  rejects(function()request('core.person.count',o(cohort_id=paste(rep('x',1025L),collapse=''))))
  rejects(function()request('core.person.count',o(cohort_id=o(kind='id',value=list('nested')))))
  rejects(function()request('core.person.count',o(cohort_id=o(value='1'))))
  rejects(function()request('core.person.count',structure(list('1','2'),names=c('cohort_id','cohort_id'))))
  rejects(function()request('core.person.count',stats::setNames(as.list(rep('1',17)),paste0('filter_',seq_len(17)))))
  tags<-lapply(list(o(kind='null'),o(kind='id',value='0'),o(kind='all'),o(kind='schema_absent')),function(tag)
    request('core.measurement.range_status_count',o(unit_concept_tag=tag))$request_sha256)
  stopifnot(length(unique(unlist(tags)))==4L)
  for(n in list(0,-1,1.5,NA_real_,Inf,1001,'100'))rejects(function()request('core.person.count',maxRows=n))
  for(n in list(0,8388609,'100'))rejects(function()request('core.person.count',maxBytes=n))
  calls<-0L;request('core.person.count',check=function(){calls<<-calls+1L});stopifnot(calls==2L)
  cancelled<-tryCatch({request('core.person.count',check=function()stop(structure(list(message='cancelled',call=NULL),class=c('interrupt','condition'))));FALSE},interrupt=function(e)TRUE)
  stopifnot(cancelled)
  calls<-0L;cancelled<-tryCatch({request('core.person.count',check=function(){calls<<-calls+1L;if(calls==2L)stop(structure(list(message='late cancellation',call=NULL),class=c('interrupt','condition')))});FALSE},interrupt=function(e)TRUE)
  stopifnot(cancelled,calls==2L)
  stopifnot(attempts==0L,!any(grepl('saved_selection|saved_capabilit',getNamespaceExports('AchillesNext'))))
  args<-commandArgs(TRUE)
  if(length(args)){stopifnot(length(args)==1L);writeLines(f('.json')(matrix),args[1],useBytes=TRUE)}
  cat('SAVED_SELECTION_142_METRICS_EXACT_GRAINS_BUDGETS_CANCELLATION_AND_NO_GENERATION_OK\n')
})
