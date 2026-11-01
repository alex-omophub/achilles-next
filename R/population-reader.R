#' Read saved restricted population/observation aggregates without CDM access
#' @param connectionDetails PostgreSQL credentials with SELECT on restricted results.
#' @param resultsSchema Restricted results schema.
#' @param releaseId UUID returned by the population/observation generator.
#' @param visit Function called with metric ID and each exact saved row.
#' @return Source/profile/inventory/scope metadata. This is restricted building
#'   release readback, not an approved publication or UI provider.
#' @export
readPopulationObservationBaseline <- function(connectionDetails,resultsSchema,releaseId,visit) {
  .population_need(is.function(visit),"A streaming row visitor is required")
  .store_transaction(connectionDetails,resultsSchema,function(tx) {
    id<-.store_uuid(releaseId);s<-tx$schema;assets<-.v2_assets();ids<-.population_ids()
    context<-.store_decode(tx$one(paste0("SELECT jsonb_build_object('release_id',r.release_id::text,'run_id',a.run_id::text,'source_id',src.source_id,",
      "'profile_id',a.profile_id,'profile_sha256',a.profile_sha256,'profile_revision',a.profile_revision,'request_sha256',a.request_sha256,'state',r.state,'run_state',a.state,'expected_metric_count',r.expected_metric_count::text)::text ",
      "FROM ",s,".achillesnext_result_release r JOIN ",s,".achillesnext_analysis_run a USING(run_id) JOIN ",s,".achillesnext_source_release src USING(source_release_id) WHERE r.release_id=",id)))
    .population_need(context$state=="building"&&context$run_state=="succeeded"&&context$expected_metric_count=="142"&&
      context$profile_id==assets$profile$profile_id&&context$profile_revision==assets$profile$revision&&context$profile_sha256==assets$hash,"Expected a saved building core baseline release")
    inventory<-list();datasets<-list()
    tx$stream(paste0("SELECT jsonb_build_object('metric_id',metric_id,'version',metric_version,'population',population_id,'grain',grain_id,'row_schema_id',row_schema_id,'definition_sha256',definition_sha256,",
      "'state',state,'reason_code',reason_code,'required',required,'conditional_support',conditional_support,'rows',row_count::text,'completeness',completeness)::text FROM ",s,".achillesnext_dataset WHERE release_id=",id," ORDER BY metric_id COLLATE \"C\""),function(text) {
        .population_need(length(inventory)<142L,"Saved baseline inventory exceeds core profile")
        d<-.store_decode(text);inventory[[d$metric_id]]<<-.object(state=d$state,reason_code=d$reason_code,rows=d$rows)
        if(d$metric_id%in%ids){.v2_dataset(d);.population_need(d$state%in%c("computed","empty_source","empty_population"),"Baseline generation cannot stand in for policy suppression");datasets[[d$metric_id]]<<-d} else
          .population_need(d$state=="not_requested"&&d$reason_code=="generator.not_implemented"&&d$rows=="0"&&!d$completeness$complete,"Ungenerated outputs must remain explicitly incomplete")
      })
    .population_need(setequal(names(inventory),names(assets$metrics))&&setequal(names(datasets),ids),"Incomplete saved baseline inventory")
    .population_need(tx$one(paste0("SELECT count(*)::text FROM ",s,".achillesnext_aggregate_cell WHERE release_id=",id," AND metric_id NOT IN (",paste(vapply(ids,.store_literal,""),collapse=","),")"))=="0","Ungenerated outputs contain unexpected facts")
    telemetry<-.store_decode(tx$one(paste0("SELECT telemetry::text FROM ",s,".achillesnext_operation WHERE run_id=",.store_uuid(context$run_id)," AND operation_id='population_observation.generate' AND state='succeeded'")))
    .population_need(identical(.json(telemetry$producer_request$requested_metric_ids),.json(as.list(ids)))&&
      identical(.hash(.json(telemetry$producer_request)),context$request_sha256),"Saved requested-work identity mismatch")
    .population_reconcile(tx,releaseId,datasets,telemetry$totals)
    # Validate all 19 saved datasets before emitting rows, in one read snapshot.
    for(mid in ids) {
      count<-"0";last<-NULL;d<-datasets[[mid]]
      .store_rows(tx,releaseId,mid,function(row,key) {
        .population_need(is.null(last)||.v2_less(last,key),"Duplicate/unordered saved baseline row")
        last<<-key;count<<-.nv_add(count,"1")
        if(d$state%in%c("empty_source","empty_population")) .population_need(row$state==d$state,"Saved empty dataset contains nonempty rows")
      })
      .population_need(count==d$rows,"Saved baseline row count mismatch")
    }
    .population_need(datasets[["core.person.count"]]$rows=="1","Saved PERSON singleton missing")
    for(mid in ids).store_rows(tx,releaseId,mid,function(row,key)visit(mid,row))
    c(context,.object(generated_metric_count="19",profile_complete=FALSE,publishable=FALSE,inventory=inventory,
      scope=telemetry$request,observed_window=telemetry$observed_window,generation=.object(started_at=telemetry$started_at,ended_at=telemetry$ended_at),
      consistency="single_repeatable_read_saved_results",reusable_source_identity=FALSE))
  },readOnly=TRUE)
}
