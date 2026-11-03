#' Plan a complete characterization refresh without connecting to a database
#' @inheritParams planCharacterizationBatch
#' @param resultsSchema Restricted results schema, distinct from source/serving.
#' @param servingSchema Approved-page schema, distinct from source/results.
#' @param numericStrategy Exact measurement summary operator: weighted or reference.
#' @return A deterministic planning-only request. No candidate or checkpoint is
#'   created, and no source/store connection or publication occurs.
#' @export
planCharacterizationRefresh <- function(cdmSchema,sourceId,resultsSchema,servingSchema,declaredCdmVersion,numericStrategy="weighted") {
  .nv_need(.string(sourceId)&&nchar(enc2utf8(sourceId),type="bytes")%in%1:256,"Invalid refresh source identifier")
  .nv_need(all(vapply(list(resultsSchema,servingSchema),function(s).batch_identifier(s)&&s!="public",TRUE))&&
    length(unique(c(cdmSchema,resultsSchema,servingSchema)))==3L,"Separate valid source, results and serving schemas are required")
  .nv_need(.string(numericStrategy)&&numericStrategy%in%c("weighted","reference"),"Choose an exact measurement summary strategy")
  batch<-planCharacterizationBatch(cdmSchema,sourceId,declaredCdmVersion,NULL,"shared")
  plan<-.object(format_version="1.0.0",kind="characterization_refresh_plan",batch=batch,
    target=.object(engine="postgresql",results_schema=resultsSchema,serving_schema=servingSchema,required_storage_version="2.0.0"),
    request=.object(numeric_strategy=numericStrategy,metric_ids=as.list(names(.v2_assets()$metrics))),
    refresh=.object(mode="full_recompute",reuse_previous_aggregates=FALSE,durable_checkpoints=FALSE,
      source_identity="unknown_until_verified",reason_code="source.no_verified_immutable_release"),
    publication=.object(automatic=FALSE,retain_previous=TRUE,requires_complete_validation=TRUE,requires_institutional_approval=TRUE),
    execution=.object(state="planning_only",source_accessed=FALSE,store_inspected=FALSE,refresh_worker_implemented=FALSE))
  plan$plan_sha256<-.hash(.json(plan));plan
}
