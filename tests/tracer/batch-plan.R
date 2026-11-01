# Offline installed planner regressions; no database or private files required.
library(AchillesNext)
main<-function() {
  p<-planCharacterizationBatch("cdm","fixture:batch","5.5")
  stopifnot(length(p$modules)==51L,p$execution$state=="planning_only",!p$execution$report_generation_implemented,
    p$scope$concepts=="all_observed",is.null(p$scope$observed_window),p$reuse$across_transactions=="recompute",
    identical(p,planCharacterizationBatch("cdm","fixture:batch","5.5")))
  assets<-AchillesNext:::.v2_assets();seen<-character();outputs<-character()
  for(m in p$modules) {
    stopifnot(all(unlist(m$depends_on)%in%seen),m$source_access=="explicit_batch_only",
      m$execution==if(m$id%in%c("person.demographics","observation.union","observation.outputs"))"available_in_population_baseline" else "not_implemented")
    seen<-c(seen,m$id);outputs<-c(outputs,unlist(m$metric_ids))
    for(g in m$grains) stopifnot(identical(g$grain,assets$metrics[[g$metric_id]]$grain),
      identical(g$population,assets$metrics[[g$metric_id]]$population),identical(g$dimensions,assets$metrics[[g$metric_id]]$dimensions))
  }
  stopifnot(length(outputs)==142L,!anyDuplicated(outputs),setequal(outputs,names(assets$metrics)))
  shared<-planCharacterizationBatch("cdm","fixture:batch","5.5",strategy="shared")
  stopifnot(planCharacterizationBatch("public","fixture:public","5.4")$source$cdm_schema=="public")
  stopifnot(p$plan_sha256!=shared$plan_sha256,any(vapply(shared$modules,function(m)m$materialization=="evaluate_run_owned_temp",TRUE)))
  wide<-planCharacterizationBatch("cdm","fixture:batch","5.3",list(start="0001-01-01",end="9999-12-31"))
  stopifnot(wide$scope$recorded=="all_physical_rows_including_undated_and_unlinked")
  fails<-function(work,text) stopifnot(grepl(text,tryCatch({work();"accepted"},error=conditionMessage),fixed=TRUE))
  for(w in list(list(start="2020-02-30",end="2021-01-01"),list(start="2021-01-01",end="2020-01-01"),
    list(start="0000-01-01",end="2020-01-01"),list(start="2020-01-01",end="2021-01-01",extra=TRUE)))
    fails(function()planCharacterizationBatch("cdm","fixture:batch","5.5",w),"Invalid observed date window")
  fails(function()planCharacterizationBatch('cdm";DROP SCHEMA public',"x","5.5"),"Invalid batch source")
  fails(function()planCharacterizationBatch("cdm","x","5.5",strategy="auto"),"Batch strategy")
  changed<-p;changed$modules[[1]]$inputs<-list("unknown")
  fails(function()AchillesNext:::.batch_check_plan(changed),"Changed batch definitions")
  changed<-p;changed$source$source_id<-"other"
  fails(function()AchillesNext:::.batch_check_plan(changed),"Changed batch definitions")
  source<-AchillesNext:::.batch_reference_sql(shared,"death",AchillesNext:::.batch_numeric_sql())
  stopifnot(!grepl('e."death_id"',source,fixed=TRUE),grepl('NULL::numeric',source,fixed=TRUE),
    grepl('IS NOT DISTINCT FROM',source,fixed=TRUE),!grepl('concept_id IN (',source,fixed=TRUE))
  cat("PASS: 51-node DAG / 142 exact profile grains; deterministic full-history/all-concept plans; strict inputs and changed-identity rejection\n")
}
main()
