# Recreate the complete source-free request with this installed implementation.
# Checking only a caller-supplied digest would accept a rehashed unsafe request.
.refresh_plan <- function(plan) {
  .nv_need(.nv_object(plan)&&.nv_object(plan$batch)&&.nv_object(plan$batch$source)&&
    .nv_object(plan$target)&&.nv_object(plan$request),"Invalid refresh plan; create a new plan")
  source<-plan$batch$source
  expected<-planCharacterizationRefresh(source$cdm_schema,source$source_id,plan$target$results_schema,
    plan$target$serving_schema,source$declared_cdm_version,plan$request$numeric_strategy)
  .nv_need(identical(.json(plan),.json(expected)),"Refresh plan changed or is stale; create a new plan")
  expected
}
.refresh_readiness <- function(tx) {
  .store_version(tx)
  tables<-c("source_release","analysis_run","operation","result_release","dataset","aggregate_cell","denominator_edge")
  for(table in c("profile_registry",tables)) {
    target<-.store_literal(paste0(tx$schema,".achillesnext_",table))
    for(privilege in c("SELECT",if(table%in%tables)"INSERT",if(table%in%c("analysis_run","result_release"))"UPDATE")) {
      .nv_need(tx$one(paste0("SELECT COALESCE(has_table_privilege(to_regclass(",target,"),",.store_literal(privilege),"),false)::text"))=="true",
        paste("Refresh worker lacks required",privilege,"privilege on",paste0("achillesnext_",table)))
    }
  }
  invisible(TRUE)
}
#' Execute a checked full-refresh plan into a fresh restricted candidate
#' @param connectionDetails PostgreSQL worker credentials with SELECT-only source,
#'   TEMPORARY and restricted result-store producer grants.
#' @param plan A current unmodified plan from planCharacterizationRefresh().
#' @inheritParams generateCharacterizationCandidate
#' @return A fresh complete building candidate with refresh-plan identity. Sealing,
#'   validation, institutional approval and CAS promotion remain explicit operations.
#' @details Recomputes all inputs; does not read, replace or delete any publication.
#'   Errors/cancellation before generation commit roll back that candidate. Later
#'   validation/approval failure can leave an unpublished candidate for diagnosis.
#' @export
executeCharacterizationRefresh <- function(connectionDetails,plan,maxStageBytes=64*1024^2,check=NULL,
  statementTimeoutMs=30000L,maxAggregateRows=1000000L) {
  plan<-.refresh_plan(plan)
  .nv_need(is.numeric(maxAggregateRows)&&length(maxAggregateRows)==1L&&is.finite(maxAggregateRows)&&maxAggregateRows>=1&&
    maxAggregateRows<=1000000&&maxAggregateRows==floor(maxAggregateRows),"Invalid aggregate row budget")
  source<-plan$batch$source
  .baseline_generate(connectionDetails,source$cdm_schema,source$source_id,plan$target$results_schema,source$declared_cdm_version,
    NULL,maxStageBytes,check,statementTimeoutMs,TRUE,TRUE,plan$request$numeric_strategy,
    maxAggregateRows=as.integer(maxAggregateRows),coreMode=TRUE,refreshPlan=plan)
}
