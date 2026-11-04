library(AchillesNext)
local({
  f<-function(n)get(n,asNamespace('AchillesNext'));wire<-f('.json')
  plan<-planCharacterizationRefresh('cdm','fixture:refresh','results','serving','5.5')
  stopifnot(identical(f('.refresh_plan')(plan),plan),plan$execution$refresh_worker_implemented)
  rejects<-function(work,message) {
    e<-tryCatch(work(),error=identity);stopifnot(inherits(e,'error'),identical(conditionMessage(e),message))
  }
  # Rehashing a tampered request must not turn it into an executable plan.
  for(change in list(function(p){p$refresh$reuse_previous_aggregates<-TRUE;p},
    function(p){p$publication$automatic<-TRUE;p},function(p){p$request$metric_ids<-p$request$metric_ids[-1];p},
    function(p){p$batch$definitions$runtime$implementation_sha256<-strrep('0',64);p},
    function(p){p$extra<-TRUE;p})) {
    bad<-change(plan);bad$plan_sha256<-NULL;bad$plan_sha256<-f('.hash')(wire(bad))
    rejects(function()executeCharacterizationRefresh(NULL,bad),'Refresh plan changed or is stale; create a new plan')
  }
  rejects(function()executeCharacterizationRefresh(NULL,plan,maxAggregateRows=0),'Invalid aggregate row budget')
  rejects(function()executeCharacterizationRefresh(NULL,plan,maxStageBytes=-1),'Invalid intermediate byte budget')
  rejects(function()executeCharacterizationRefresh(NULL,plan,statementTimeoutMs=0),'Invalid statement timeout')
  seen<-character();allow<-TRUE
  tx<-list(schema='"results"',stream=function(sql,visit){seen<<-c(seen,sql);visit('2.0.0')},one=function(sql){seen<<-c(seen,sql);if(allow)'true' else 'false'})
  f('.refresh_readiness')(tx)
  stopifnot(length(seen)>10,!any(grepl('INSERT INTO|UPDATE |DELETE |CREATE |cdm|serving|current_publication',seen,ignore.case=TRUE)))
  allow<-FALSE
  rejects(function()f('.refresh_readiness')(tx),'Refresh worker lacks required SELECT privilege on achillesnext_profile_registry')
  # Database/JDBC diagnostics can contain SQL or connection details. Readiness
  # exposes only fixed messages and reason codes, never the underlying condition.
  captures<-function(work,message,code) {
    e<-tryCatch(work(),error=identity)
    stopifnot(inherits(e,'AchillesRefreshReadinessFailure'),identical(conditionMessage(e),message),identical(e$reason_code,code),
      is.null(e$call),is.null(e$parent))
  }
  allow<-FALSE
  captures(function()f('.refresh_readiness')(tx),'Refresh worker lacks required SELECT privilege on achillesnext_profile_registry','refresh.store_privilege_missing')
  badVersion<-tx;badVersion$stream<-function(sql,visit)visit('3.0.0')
  versionMessage<-'Refresh result-store version unavailable or unsupported; check results schema USAGE, marker SELECT and storage version'
  captures(function()f('.refresh_readiness')(badVersion),versionMessage,'refresh.store_version_unavailable_or_unsupported')
  privateError<-'sentinel confidential JDBC/SQL details'
  denied<-tx;denied$stream<-function(...)stop(privateError)
  captures(function()f('.refresh_readiness')(denied),versionMessage,'refresh.store_version_unavailable_or_unsupported')
  failedCheck<-tx;failedCheck$one<-function(...)stop(privateError)
  captures(function()f('.refresh_readiness')(failedCheck),
    'Refresh store privilege check failed for SELECT on achillesnext_profile_registry; check results schema USAGE and table access',
    'refresh.store_privilege_check_failed')
  cat('REFRESH_CANONICAL_PLAN_TAMPERING_LIMITS_AND_READINESS_BEFORE_WRITES_OK\n')
})
