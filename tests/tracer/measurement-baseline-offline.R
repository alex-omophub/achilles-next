library(AchillesNext)
local({
  f<-function(n)get(n,asNamespace('AchillesNext'))
  ids<-setdiff(f('.domain_ids')(TRUE),f('.domain_ids')())
  stopifnot(length(ids)==19L,all(grepl('^(core|observed)[.]measurement[.]',ids)),
    length(c(f('.population_ids')(),f('.domain_ids')(TRUE)))==138L,length(f('.v2_assets')()$metrics)==142L)
  rejects<-function(work,message) {
    error<-tryCatch({work();'accepted'},error=conditionMessage)
    stopifnot(identical(error,message))
  }
  for(strategy in list(NULL,NA_character_,'approximate','',c('reference','weighted')))
    rejects(function()generateMeasurementBaseline(NULL,'cdm','source','results','5.5',numericStrategy=strategy),
      'Choose an exact measurement summary strategy')
  for(limit in list(0,-1,0.5,Inf,NA_real_,'100',1000001))
    rejects(function()generateMeasurementBaseline(NULL,'cdm','source','results','5.5',maxAggregateRows=limit),
      'Invalid aggregate row budget')
  # An accepted double cap must reach exact decimal-string comparison intact.
  # No database or 100,000-row materialization is needed to reproduce the bug.
  generate<-generateMeasurementBaseline;scope<-new.env(parent=environment(generate))
  scope$.baseline_generate<-function(...) {
    limit<-tail(list(...),1L)[[1L]]
    stopifnot(f('.v2_count')(as.character(limit)),f('.nv_unsigned_cmp')('100000',as.character(limit))<0L)
    limit
  }
  environment(generate)<-scope
  for(limit in list(1e6,1000000L))stopifnot(identical(generate(NULL,'cdm','source','results','5.5',maxAggregateRows=limit),1000000L))
  cat('NINETEEN_MEASUREMENT_OUTPUTS_AND_PRECONNECTION_OPERATOR_BUDGET_GUARDS_OK\n')
})
