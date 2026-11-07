# Public semantic access, native mathematical evidence and bounded saved-only I/O.
library(AchillesNext)
source('tests/tracer/saved-result-fixture.R')
local({
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object')
  folder<-tempfile('semantic-provider-');dir.create(folder);on.exit(unlink(folder,recursive=TRUE))
  x<-makeSavedResultFixture(file.path(folder,'admitted'))
  validateResultArtifact(x$directory)
  # After complete admission, all provider tests deny source/store connections.
  attempted<-0L;original<-DatabaseConnector::connect
  assignInNamespace('connect',function(...){attempted<<-attempted+1L;stop('Unexpected connection')},ns='DatabaseConnector')
  on.exit(assignInNamespace('connect',original,ns='DatabaseConnector'),add=TRUE)
  active<-TRUE
  p<-openArtifactResultProvider(x$directory,x$context,function(c)active&&identical(c,x$context));on.exit(p$close(),add=TRUE)
  errors<-0L
  fail<-function(work,code) {
    e<-tryCatch({work();NULL},error=identity)
    stopifnot(inherits(e,'achillesnext_read_error'),identical(e$code,code));errors<<-errors+1L
    invisible(e)
  }
  metrics<-list();cursor<-NULL
  repeat {
    page<-p$listMetrics(limit=7L,cursor=cursor)
    stopifnot(page$state=='available',length(page$metrics)<=7L,page$budget$objects<=64L)
    metrics<-c(metrics,page$metrics)
    if(page$complete)break
    cursor<-page$cursor
  }
  ids<-vapply(metrics,function(m)m$metric_id,'')
  stopifnot(length(ids)==142L,!anyDuplicated(ids),identical(ids,sort(names(f('.v2_assets')()$metrics),method='radix')))
  stopifnot(all(vapply(metrics,function(m)!is.null(m$capability)&&identical(m$rows,as.character(length(x$rows[[m$metric_id]]))),TRUE)))
  count<-p$selectSavedRows('core.person.count')
  stopifnot(count$state=='available',count$rows[[1]]$values$person_count=='10',!length(count$dependencies),!count$generation_requested,count$transformations=='none',count$budget$objects<12L)
  # Registry-driven capability discovery also handles installed count extensions.
  extension<-f('.profile_assets')('reference-person-v1')
  for(mid in names(extension$metrics))stopifnot(f('.saved_selection')(mid,assets=extension)$state=='selection_shape_supported')
  gender<-p$selectSavedRows('core.person.gender_count',maxRows=1L)
  stopifnot(length(gender$rows)==1L,!gender$complete,length(gender$dependencies)==1L,gender$dependencies[[1]]$row$values$person_count=='10')
  second<-p$selectSavedRows('core.person.gender_count',maxRows=1L,cursor=gender$cursor)
  stopifnot(second$complete,second$rows[[1]]$dimensions$gender_concept_id=='9007199254740993',second$rows[[1]]$values$person_count=='4',second$rows[[1]]$row_key!=gender$rows[[1]]$row_key)
  summary<-p$selectSavedRows('core.measurement.numeric_summary',list(concept_tag=list(kind='id',value='123')))
  stopifnot(length(summary$rows)==3L,all(vapply(summary$rows,function(r)r$row_kind=='summary',TRUE)),length(summary$dependencies)==3L)
  # Byte pagination accounts for the complete envelope and only returned evidence.
  oneSizes<-integer();cursor<-NULL
  repeat {
    one<-p$selectSavedRows('core.measurement.numeric_summary',maxRows=1L,cursor=cursor)
    oneSizes<-c(oneSizes,length(f('.v2_bytes')(one)))
    if(one$complete)break
    cursor<-one$cursor
  }
  byteLimit<-max(oneSizes)+128L
  stopifnot(byteLimit<length(f('.v2_bytes')(summary)))
  cursor<-NULL;keys<-character();bytePages<-0L
  repeat {
    page<-p$selectSavedRows('core.measurement.numeric_summary',maxBytes=byteLimit,cursor=cursor)
    stopifnot(length(page$rows)>0L,length(f('.v2_bytes')(page))<=byteLimit)
    units<-vapply(page$rows,function(r)r$dimensions$unit_concept_tag$value,'')
    stopifnot(setequal(units,vapply(page$dependencies,function(d)d$row$dimensions$unit_concept_tag$value,'')))
    keys<-c(keys,vapply(page$rows,function(r)r$row_key,''));bytePages<-bytePages+1L
    if(page$complete)break
    cursor<-page$cursor
  }
  stopifnot(bytePages>1L,!anyDuplicated(keys),identical(keys,vapply(summary$rows,function(r)r$row_key,'')))
  header<-p$listMetrics(limit=1L)
  headerBytes<-length(f('.v2_bytes')(header))-length(f('.v2_bytes')(header$metrics[[1]]))
  metricBytes<-headerBytes+max(vapply(metrics,function(m)length(f('.v2_bytes')(m)),1L))+256L
  cursor<-NULL;byteIds<-character()
  repeat {
    page<-p$listMetrics(limit=100L,maxBytes=metricBytes,cursor=cursor)
    stopifnot(length(page$metrics)>0L,length(f('.v2_bytes')(page))<=metricBytes)
    byteIds<-c(byteIds,vapply(page$metrics,function(m)m$metric_id,''))
    if(page$complete)break
    cursor<-page$cursor
  }
  stopifnot(identical(byteIds,ids))
  zero<-Filter(function(r)r$dimensions$unit_concept_tag$value=='777',summary$rows)[[1]]
  stopifnot(zero$state=='empty_population',zero$values$n=='0',is.null(zero$values$p50))
  chosen<-p$selectSavedRows('core.measurement.numeric_summary',list(concept_tag=list(kind='id',value='123'),unit_concept_tag=list(kind='id',value='456'),raw_operator_tag=list(kind='null')))
  stopifnot(length(chosen$rows)==1L,chosen$rows[[1]]$values$mean_numerator=='20.5',chosen$rows[[1]]$values$mean_denominator=='6',chosen$rows[[1]]$values$p50=='2.5',chosen$budget$objects<15L)
  eligible<-p$selectSavedRows('core.measurement.numeric_summary',list(unit_concept_tag=list(kind='id',value='456'),eligibility_reason='eligible'),rowKind='eligibility_counts')
  stopifnot(eligible$rows[[1]]$row_kind=='eligibility_counts',eligible$dependencies[[1]]$row$row_kind=='summary')
  chained<-p$selectSavedRows('core.condition.observation_qualification_count',list(concept_tag=list(kind='id',value='123')))
  stopifnot(length(chained$dependencies)==2L,setequal(vapply(chained$dependencies,function(d)d$metric_id,''),c('core.condition.capture_count','core.person.count')))
  absent<-p$selectSavedRows('core.person.gender_count',list(gender_concept_id='-1'))
  stopifnot(absent$state=='not_saved',!length(absent$rows),!absent$generation_requested)
  suppressed<-p$selectSavedRows('core.drug.capture_count')
  stopifnot(suppressed$state=='suppressed',!length(suppressed$rows))
  empty<-p$selectSavedRows('core.specimen.capture_count')
  stopifnot(empty$state=='available',empty$dataset$state=='empty_source',empty$rows[[1]]$values$record_count=='0')
  unavailable<-p$selectSavedRows('core.visit.care_setting_count')
  stopifnot(unavailable$state=='available',unavailable$rows[[1]]$state=='unavailable',is.null(unavailable$rows[[1]]$values))
  unsaved<-p$selectSavedRows('core.measurement.numeric_summary',list(period_kind='calendar_month',period_start='2020-01-01',period_end='2020-01-31'))
  stopifnot(unsaved$state=='additional_batch_job_required',!unsaved$generation_requested,!length(unsaved$rows))
  pop<-p$selectSavedRows('core.condition.capture_count',population='observed_rows');stopifnot(pop$state=='additional_batch_job_required')
  fail(function()p$selectSavedRows('core.person.gender_count',maxRows=1L,cursor=paste0(gender$cursor,'x')),'invalid_cursor')
  cursor<-p$listMetrics(limit=1L)$cursor
  fail(function()p$selectSavedRows('core.person.count',cursor=cursor),'invalid_cursor')
  cursor<-p$selectSavedRows('core.person.gender_count',maxRows=1L)$cursor
  fail(function()p$selectSavedRows('core.person.gender_count',list(gender_concept_id='0'),maxRows=1L,cursor=cursor),'invalid_cursor')
  otherContext<-x$context;otherContext$instance_id<-'another-instance'
  q<-openArtifactResultProvider(x$directory,otherContext,function(c)TRUE);on.exit(q$close(),add=TRUE)
  fail(function()q$selectSavedRows('core.person.gender_count',maxRows=1L,cursor=cursor),'invalid_cursor')
  for(work in list(function()p$selectSavedRows('unknown'),function()p$listMetrics(limit=0L),function()p$selectSavedRows('core.person.count',maxRows=1001L),function()p$selectSavedRows('core.person.gender_count',list(gender_concept_id=123)),function()p$selectSavedRows('core.measurement.numeric_summary',list(unit_concept_tag=list(kind='null')))))fail(work,'invalid_request')
  fail(function()p$selectSavedRows('core.person.count',maxBytes=10L),'resource_limit');stopifnot(p$inspect()$cache_bytes==0L)
  measured<-p$listMetrics(limit=1L)
  fail(function()p$listMetrics(limit=1L,maxBytes=length(f('.v2_bytes')(measured))-1L),'resource_limit')
  tiny<-openArtifactResultProvider(x$directory,x$context,function(c)TRUE,readBudget=list(maxObjects=4L));on.exit(tiny$close(),add=TRUE)
  fail(function()tiny$selectSavedRows('core.person.gender_count'),'resource_limit')
  dependencyBudget<-openArtifactResultProvider(x$directory,x$context,function(c)TRUE,readBudget=list(maxObjects=gender$budget$objects-1L));on.exit(dependencyBudget$close(),add=TRUE)
  fail(function()dependencyBudget$selectSavedRows('core.person.gender_count',maxRows=1L),'resource_limit')
  for(fault in c('wrong_reference','wrong_value','missing_eligibility','wrong_eligibility')) {
    z<-makeSavedResultFixture(file.path(folder,fault),fault=fault)
    # Deliberately corrupt rehashed fixtures are not admitted publications.
    q<-openArtifactResultProvider(z$directory,z$context,function(c)TRUE)
    fail(function()q$selectSavedRows(if(grepl('eligibility',fault))'core.measurement.numeric_summary' else 'core.person.gender_count'),'integrity_failure')
    stopifnot(q$inspect()$cache_bytes==0L);q$close()
  }
  cancelled<-FALSE
  t<-f('.saved_artifact_transport')(x$directory,x$context,function(c)TRUE);read<-t$read
  t$read<-function(d,cancel){bytes<-read(d,cancel);if(d$kind=='data')cancelled<<-TRUE;bytes}
  late<-f('.saved_provider')(t);on.exit(late$close(),add=TRUE)
  fail(function()late$selectSavedRows('core.person.count',cancel=function()cancelled),'aborted')
  stopifnot(late$inspect()$cache_bytes==0L)
  p$listMetrics();active<-FALSE;fail(function()p$selectSavedRows('core.person.count'),'inaccessible');stopifnot(p$inspect()$cache_bytes==0L)
  active<-TRUE;fail(function()p$listMetrics(cancel=function()TRUE),'aborted')
  p$close();p$close();fail(function()p$listMetrics(),'closed')
  stopifnot(attempted==0L)
  cat('SAVED_PROVIDER_DISCOVERY_ROWS_SUMMARY_DENOMINATORS_PAGINATION_BUDGETS_ZERO_SOURCE_OK errors=',errors,'\n')
})
