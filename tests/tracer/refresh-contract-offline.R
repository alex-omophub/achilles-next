library(AchillesNext)
local({
  f<-function(n)get(n,asNamespace('AchillesNext'))
  plan<-function(...)planCharacterizationRefresh('cdm','fixture:refresh','results','serving','5.5',...)
  p<-plan();stopifnot(identical(p,plan()),length(p$request$metric_ids)==142L,
    identical(unlist(p$request$metric_ids),names(f('.v2_assets')()$metrics)),
    p$execution$state=='planning_only',!p$execution$source_accessed,!p$execution$store_inspected,
    !p$execution$refresh_worker_implemented,p$refresh$mode=='full_recompute',
    !p$refresh$reuse_previous_aggregates,!p$refresh$durable_checkpoints,
    !p$publication$automatic,p$publication$retain_previous,p$publication$requires_institutional_approval,
    is.null(p$batch$scope$observed_window),p$target$required_storage_version=='2.0.0')
  withoutHash<-p;withoutHash$plan_sha256<-NULL
  stopifnot(identical(p$plan_sha256,f('.hash')(f('.json')(withoutHash))),
    plan(numericStrategy='reference')$plan_sha256!=p$plan_sha256,
    identical(plan(numericStrategy='reference')$batch$profile,p$batch$profile))
  f('.profile_assets')('reference-person-v1');stopifnot(identical(p,plan()))
  rejects<-function(work)stopifnot(inherits(try(work(),silent=TRUE),'try-error'))
  for(id in c('',strrep('x',257),paste0(strrep('\u00e9',128),'x')))
    rejects(function()planCharacterizationRefresh('cdm',id,'results','serving','5.5'))
  stopifnot(planCharacterizationRefresh('cdm',strrep('\u00e9',128),'results','serving','5.3')$batch$source$source_id==strrep('\u00e9',128))
  for(schemas in list(c('cdm','cdm','serving'),c('cdm','results','results'),c('cdm','public','serving'),c('cdm','results','pg_catalog'),c('cdm','results','unsafe;schema')))
    rejects(function()planCharacterizationRefresh(schemas[1],'fixture',schemas[2],schemas[3],'5.5'))
  rejects(function()plan(numericStrategy='approximate'))
  rejects(function()planCharacterizationRefresh('cdm','fixture','results','serving','6.0'))
  # Only the bounded version-marker query is available; no source/write handle.
  seen<-character();versions<-'2.0.0'
  tx<-list(schema='"results"',stream=function(sql,visit){seen<<-c(seen,sql);for(version in versions)visit(version)})
  stopifnot(f('.store_version')(tx)=='2.0.0',length(seen)==1L,grepl('LIMIT 2',seen,fixed=TRUE),
    !grepl('cdm|INSERT|UPDATE|DELETE|CREATE',seen,ignore.case=TRUE))
  for(v in list(character(),'3.0.0',c('2.0.0','2.0.0'),NA_character_)) {
    versions<-v;rejects(function()f('.store_version')(tx))
  }
  cat('REFRESH_PLANNING_ONLY_FULL_RECOMPUTE_IDENTITIES_AND_BOUNDED_VERSION_CHECK_OK\n')
})
