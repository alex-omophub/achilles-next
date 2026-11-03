library(AchillesNext)
local({
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');wire<-f('.json')
  metadata<-list(
    o(table='person',kind='r',column='person_id',type='int8',readable=TRUE),
    o(table='person',kind='r',column='gender_concept_id',type='int8',readable=FALSE),
    o(table='observation_period',kind='r',column='person_id',type='int8',readable=TRUE),
    o(table='cdm_source',kind='r',column='cdm_version',type='text',readable=FALSE),
    o(table='vocabulary',kind='r',column='vocabulary_id',type='text',readable=TRUE))
  queries<-character()
  tx<-list(stream=function(sql,visit){queries<<-c(queries,sql);for(m in metadata)visit(wire(m))},one=function(sql){
    queries<<-c(queries,sql);if(grepl('"observation_period"',sql,fixed=TRUE))'true' else 'false'})
  result<-f('.core_capabilities')(tx,'cdm');v<-result$values
  stopifnot(v[['person.person_id']]$state=='available',v[['person.gender_concept_id']]$state=='inaccessible',
    v[['person.gender_concept_id']]$observed_type=='int8',v[['observation_period.person_id']]$state=='available_empty',
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
  # Invalid public request arguments fail before any connection is opened.
  rejects<-function(work)stopifnot(inherits(try(work(),silent=TRUE),'try-error'))
  generate<-function(...)generateCharacterizationCandidate(NULL,'cdm','source','results','5.5',...)
  rejects(function()generate(numericStrategy='approximate'));rejects(function()generate(maxAggregateRows=0))
  rejects(function()generate(maxAggregateRows=Inf));rejects(function()generate(maxAggregateRows=1.5))
  rejects(function()generate(statementTimeoutMs=0));rejects(function()generate(maxStageBytes=-1))
  cat('CORE_CAPABILITY_DENIAL_EMPTY_ABSENCE_TIMING_AND_REQUEST_GUARDS_OK\n')
})
