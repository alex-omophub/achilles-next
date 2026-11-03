library(AchillesNext)
local({
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');wire<-f('.json')
  metadata<-list(
    o(table='person',kind='r',column='person_id',type='bigint',readable=TRUE),
    o(table='person',kind='r',column='gender_concept_id',type='bigint',readable=FALSE),
    o(table='observation_period',kind='r',column='person_id',type='bigint',readable=TRUE),
    o(table='cdm_source',kind='r',column='cdm_version',type='text',readable=FALSE),
    o(table='vocabulary',kind='r',column='vocabulary_id',type='text',readable=TRUE))
  queries<-character()
  tx<-list(stream=function(sql,visit){queries<<-c(queries,sql);for(m in metadata)visit(wire(m))},one=function(sql){
    queries<<-c(queries,sql);if(grepl('"observation_period"',sql,fixed=TRUE))'true' else 'false'})
  result<-f('.core_capabilities')(tx,'cdm');v<-result$values
  stopifnot(v[['person.person_id']]$state=='available',v[['person.gender_concept_id']]$state=='inaccessible',
    v[['person.gender_concept_id']]$observed_type=='bigint',v[['observation_period.person_id']]$state=='available_empty',
    v[['device_exposure.unit_concept_id']]$state=='absent',v$cdm_source$state=='inaccessible',v$vocabulary$state=='available',
    v$operator_assertions$state=='absent',v$schema_metadata$state=='available',
    length(queries)==4L,!any(grepl('COUNT|INSERT|UPDATE|DELETE',queries,ignore.case=TRUE)),
    identical(result,f('.core_capabilities')(tx,'cdm')))
  a<-f('.v2_assets')()
  for(p in names(v)) {
    row<-o(row_key='',dimensions=o(probe_id=p),row_kind='metadata',state='computed',reason_code=NULL,values=v[[p]],denominator_refs=list())
    row$row_key<-f('.v2_row_identity')(a$rows[['core.source.capabilities']],row);f('.v2_row')('core.source.capabilities',row)
  }
  timings<-f('.core_timing')(list(person=list(duration_ms='0'),reports=list(duration_ms='125')),'140')
  stopifnot(length(timings)==7L,timings[[1]]$values$duration_ms=='140',timings[[2]]$values$duration_ms=='0')
  for(t in timings) {
    row<-o(row_key='',dimensions=t$dimensions,row_kind='metadata',state='computed',reason_code=NULL,values=t$values,denominator_refs=list())
    row$row_key<-f('.v2_row_identity')(a$rows[['core.execution.timing']],row);f('.v2_row')('core.execution.timing',row)
  }
  # Force timing capture before the first metadata row is assembled. R otherwise
  # delays evaluating the timing argument until after passport/capability/ledger writes.
  captured<-FALSE;writes<-0L
  supported<-stats::setNames(lapply(f('.core_probes')(),function(p)o(state='available',reason_code=NULL,observed_type='fixture')),f('.core_probes')())
  coverage<-o(scope_kind='standard_full',complete=TRUE,excluded_record_count='0',reason_code=NULL)
  counts<-stats::setNames(as.character(c(1L,length(supported),length(a$metrics),5L)),f('.core_metadata_ids')())
  datasets<-stats::setNames(lapply(names(a$metrics),function(mid)o(state='computed',reason_code=NULL,required=TRUE,completeness=coverage,
    rows=if(mid%in%names(counts))counts[[mid]] else '0')),names(a$metrics))
  sink<-list(schema='"fixture"',execute=function(sql){writes<<-writes+1L})
  f('.core_write_metadata')(sink,'00000000-0000-4000-8000-000000000001','fixture','5.5',strrep('a',64),supported,datasets,
    '2026-01-01T00:00:00.000Z','2026-01-01T00:00:01.000Z',
    {captured<-TRUE;f('.core_timing')(list(),'1000')},1000000L,0L,function()stopifnot(captured))
  stopifnot(captured,writes>0L)
  # Invalid public request arguments fail before any connection is opened.
  rejects<-function(work,message) {
    error<-tryCatch(work(),error=identity)
    stopifnot(inherits(error,'error'),identical(conditionMessage(error),message))
  }
  generate<-function(...)generateCharacterizationCandidate(NULL,'cdm','source','results','5.5',...)
  rejects(function()generate(numericStrategy='approximate'),'Choose an exact measurement summary strategy')
  for(limit in list(0,Inf,1.5))rejects(function()generate(maxAggregateRows=limit),'Invalid aggregate row budget')
  rejects(function()generate(statementTimeoutMs=0),'Invalid statement timeout')
  rejects(function()generate(maxStageBytes=-1),'Invalid intermediate byte budget')
  cat('CORE_CAPABILITY_DENIAL_EMPTY_ABSENCE_TIMING_AND_REQUEST_GUARDS_OK\n')
})
