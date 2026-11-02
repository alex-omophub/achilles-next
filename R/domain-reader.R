#' Stream saved restricted domain reports without source access
#' @inheritParams readPopulationObservationBaseline
#' @param metricIds Optional subset of the 119 generated metric identifiers.
#' @param conceptTag Optional typed raw concept tag or ALL selector.
#' @param period Optional exact saved period selector with period_kind,
#'   period_start and period_end (strings, including the literal "null").
#' @return Restricted baseline metadata and the exact saved selection. This is
#'   not an approved provider. Unsupported date grains require new generation.
#' @export
readDomainBaseline <- function(connectionDetails,resultsSchema,releaseId,visit,metricIds=NULL,conceptTag=NULL,period=NULL,maxSpoolBytes=64*1024^2) {
  .domain_read(connectionDetails,resultsSchema,releaseId,visit,metricIds,conceptTag,period,maxSpoolBytes,FALSE)
}
.domain_read <- function(connectionDetails,resultsSchema,releaseId,visit,metricIds,conceptTag,period,maxSpoolBytes,measurementMode) {
  ids<-c(.population_ids(),.domain_ids(measurementMode))
  .population_need(is.null(metricIds)||(is.character(metricIds)&&length(metricIds)>0L&&!anyDuplicated(metricIds)&&all(metricIds%in%ids)),"Choose generated baseline metric IDs")
  if(!is.null(conceptTag)){.v2_component(conceptTag,'concept_tag');.population_need(conceptTag$kind!='schema_absent','Invalid concept selector')}
  if(!is.null(period)) {
    .v2_keys(period,c('period_kind','period_start','period_end'))
    .v2_dimensions('core.condition.capture_count',.object(dimensions=c(.object(concept_tag=.object(kind='all')),period),row_kind='counts'))
  }
  .population_need(is.function(visit),'A streaming row visitor is required')
  selected<-unname(metricIds %||% ids)
  for(dimension in c(if(!is.null(conceptTag))'concept_tag',if(!is.null(period))'period_kind')) {
    supported<-vapply(selected,function(mid)dimension%in%unlist(.v2_assets()$rows[[mid]]$dimensions),TRUE)
    .population_need(is.null(metricIds)||all(supported),'Metric/selector grain not precomputed; generation is required')
    selected<-selected[supported]
  }
  # Validation and emission share the same saved-results snapshot. Source
  # credentials, vocabulary resolution and clinical joins are never involved.
  checkPeriods<-if(is.null(period))NULL else function(tx) {
    available<-character()
    tx$stream(paste0("SELECT metric_id FROM ",tx$schema,".achillesnext_aggregate_cell WHERE release_id=",.store_uuid(releaseId),
      " AND metric_id IN (",paste(vapply(selected,.store_literal,""),collapse=","),") AND dimensions @> ",.store_literal(.json(period)),"::jsonb GROUP BY metric_id"),function(mid)available<<-c(available,mid))
    .population_need(setequal(available,selected),'Period not precomputed for every selected metric; generation is required')
  }
  selectRow<-function(mid,row) {
    if(!mid%in%selected)return(FALSE)
    if(!is.null(conceptTag)&&(is.null(row$dimensions$concept_tag)||!identical(.json(conceptTag),.json(row$dimensions$concept_tag))))return(FALSE)
    if(!is.null(period)&&(is.null(row$dimensions$period_kind)||!identical(.json(row$dimensions[names(period)]),.json(period))))return(FALSE)
    TRUE
  }
  context<-.baseline_read(connectionDetails,resultsSchema,releaseId,visit,TRUE,checkPeriods,maxSpoolBytes,selectRow,measurementMode)
  c(context,.object(selection=.object(metric_ids=as.list(selected),concept_tag=conceptTag,period=period)))
}

#' Page through a saved domain's raw concept identities
#' @inheritParams readPopulationObservationBaseline
#' @param domain One of condition, drug, procedure, visit, device, observation,
#'   death, specimen or measurement.
#' @param pageSize Integer from 1 to 128.
#' @param cursor NULL for the first page; otherwise the previous next_cursor.
#' @return A bounded list of typed concept tags and a release/revision-bound
#'   next_cursor, or NULL at the end. No patient/source strings or live labels.
#' @export
listDomainConcepts <- function(connectionDetails,resultsSchema,releaseId,domain,pageSize=64L,cursor=NULL) {
  .population_need(.string(domain)&&domain%in%.domain_names(TRUE),'Unknown baseline domain')
  .population_need(is.numeric(pageSize)&&length(pageSize)==1L&&!is.na(pageSize)&&pageSize==floor(pageSize)&&pageSize>=1&&pageSize<=128,'Invalid catalogue page size')
  .store_transaction(connectionDetails,resultsSchema,function(tx) {
    id<-.store_uuid(releaseId);s<-tx$schema;mid<-paste0('core.',domain,'.capture_count')
    context<-.store_decode(tx$one(paste0("SELECT jsonb_build_object('revision',r.content_revision::text,'state',r.state,'run_state',a.state,'profile',a.profile_sha256,'request',a.request_sha256,'producer',o.telemetry->'producer_request')::text FROM ",s,".achillesnext_result_release r JOIN ",s,".achillesnext_analysis_run a USING(run_id) JOIN ",s,".achillesnext_operation o ON o.run_id=a.run_id AND o.operation_id IN ('domain_baseline.generate','measurement_baseline.generate') AND o.state='succeeded' WHERE r.release_id=",id)))
    .population_need(context$state=='building'&&context$run_state=='succeeded'&&context$profile==.v2_assets()$hash&&.hash(.json(context$producer))==context$request,'Expected a saved domain baseline')
    .population_need(mid%in%unlist(context$producer$requested_metric_ids),'Domain was not generated; generation is required')
    binding<-.hash(.json(.object(release_id=releaseId,revision=context$revision,metric_id=mid,profile=context$profile)))
    after<-NULL
    if(!is.null(cursor)) {
      .v2_keys(cursor,c('binding','after'));.population_need(identical(cursor$binding,binding)&&.string(cursor$after)&&nchar(cursor$after,type='bytes')<=4096,'Cursor belongs to another release, revision or domain')
      after<-cursor$after
    }
    where<-paste0(' release_id=',id,' AND metric_id=',.store_literal(mid)," AND route_key='A' AND dimensions->>'period_kind'='full_scope' AND dimensions->'concept_tag'->>'kind'<>'all'")
    if(!is.null(after)).population_need(tx$one(paste0('SELECT count(*)::text FROM ',s,'.achillesnext_aggregate_cell WHERE',where,' AND sort_key=',.store_literal(after)))=='1','Unknown concept cursor')
    tags<-list();keys<-character()
    tx$stream(paste0("SELECT jsonb_build_object('tag',dimensions->'concept_tag','key',sort_key)::text FROM ",s,'.achillesnext_aggregate_cell WHERE',where,if(!is.null(after))paste0(' AND sort_key COLLATE "C">',.store_literal(after),' COLLATE "C"') else '', ' ORDER BY sort_key COLLATE "C" LIMIT ',as.integer(pageSize)+1L),function(text) {
      v<-.store_decode(text);.v2_component(v$tag,'concept_tag');tags[[length(tags)+1L]]<<-v$tag;keys<<-c(keys,v$key)
    })
    more<-length(tags)>pageSize;if(more)tags<-tags[seq_len(pageSize)]
    .object(release_id=releaseId,domain=domain,concepts=tags,next_cursor=if(more).object(binding=binding,after=keys[pageSize]) else NULL)
  },readOnly=TRUE)
}

#' Stream saved restricted measurement/domain aggregates without CDM access
#' @inheritParams readDomainBaseline
#' @return Validated restricted metadata and saved selection across 138 outputs;
#'   this is not an approved publication/provider.
#' @export
readMeasurementBaseline <- function(connectionDetails,resultsSchema,releaseId,visit,metricIds=NULL,conceptTag=NULL,period=NULL,maxSpoolBytes=64*1024^2) {
  .domain_read(connectionDetails,resultsSchema,releaseId,visit,metricIds,conceptTag,period,maxSpoolBytes,TRUE)
}
