#' Generate the eight-domain and population/observation baseline
#' @inheritParams generatePopulationObservationBaseline
#' @return A restricted building release with 119 of 142 frozen outputs,
#'   including explicitly unsupported conditional outputs. Not publishable yet.
#' @details Reads full recorded source history once in a repeatable-read batch.
#'   Precomputes raw concepts, domain totals, calendar months/years and undated
#'   capture counts. The 19 measurement outputs and four metadata outputs remain
#'   not requested. Source tables must be readable even when empty. No clinical
#'   source rows, source strings or person identifiers are persisted in results.
#' @export
generateDomainBaseline <- function(connectionDetails,cdmSchema,sourceId,resultsSchema,declaredCdmVersion,
  maxStageBytes=64*1024^2,check=NULL,statementTimeoutMs=30000L) {
  .baseline_generate(connectionDetails,cdmSchema,sourceId,resultsSchema,declaredCdmVersion,NULL,maxStageBytes,check,statementTimeoutMs,TRUE)
}
.baseline_normalize <- function(x) {
  if(is.null(x))return(NULL)
  if(grepl('.',x,fixed=TRUE)){x<-sub('0+$','',x);x<-sub('[.]$','',x)}
  if(x=='-0')'0' else x
}
.domain_stream_sql <- function(tx,release,output,mid) {
  rule<-.analysis_rule(mid)
  join<-"";denominator<-"NULL"
  if(!is.null(rule)) {
    condition<-paste0("o.row_kind=",.store_literal(rule$row_kind))
    for(k in names(rule$when))condition<-paste0(condition," AND o.dimensions->>",.store_literal(k),"=",.store_literal(rule$when[[k]]))
    bindings<-c(lapply(rule$dimensions,function(b)if(!is.null(b$source))paste0("o.dimensions->",.store_literal(b$source)) else .store_literal(b$constant)),lapply(rule$key_defaults,.store_literal))
    dimensions<-if(!length(bindings))"'{}'::jsonb" else paste0("jsonb_build_object(",paste(vapply(names(bindings),function(k)paste0(.store_literal(k),",",bindings[[k]]),""),collapse=","),")")
    join<-paste0(" LEFT JOIN ",tx$schema,".achillesnext_aggregate_cell d ON d.release_id=",.store_uuid(release)," AND d.metric_id=",.store_literal(rule$metric_id),
      " AND d.route_key='A' AND d.payload_kind='counts' AND d.dimensions=",dimensions," AND ",condition)
    fields<-unique(vapply(rule$measures,function(m)m$target,""))
    values<-paste(vapply(fields,function(m)paste0(.store_literal(m),",d.",m,"::text"),""),collapse=",")
    denominator<-paste0("CASE WHEN d.row_key IS NOT NULL THEN jsonb_build_object('metric_id',d.metric_id,'row_key',d.row_key,'dimensions',d.dimensions,'values',jsonb_build_object(",values,")) END")
  }
  paste0("SELECT jsonb_build_object('row_kind',o.row_kind,'dimensions',o.dimensions,'values',o.values,'denominator',",denominator,
    ")::text FROM (SELECT * FROM ",output,") o",join," WHERE o.metric_id=",.store_literal(mid))
}
# Target identity and values travel with the streamed row. This function has no
# connection/transaction argument and performs zero per-cell database lookups.
.domain_denominators <- function(mid,row,target) {
  if(row$state%in%c('unsupported','unavailable'))return(list())
  spec<-.analysis_denominator(mid,row,forKey=TRUE)
  if(is.null(spec))return(list())
  targetId<-spec$metric_id;targetDims<-spec$dimensions
  measures<-vapply(spec$measures,function(m)m$target,"")
  key<-.v2_row_identity(.v2_assets()$rows[[targetId]],.object(row_kind='counts',dimensions=targetDims))
  .population_need(!is.null(target)&&identical(target$metric_id,targetId)&&identical(target$row_key,key)&&identical(.json(target$dimensions),.json(targetDims)),"Missing or mismatched streamed denominator")
  .population_need(all(vapply(target$values[measures],.v2_count,TRUE)),"Invalid streamed denominator counts")
  refs<-lapply(spec$measures,function(m).object(measure=m$source,metric_id=targetId,row_key=key,field=m$target,value=target$values[[m$target]]))
  row$denominator_refs<-refs;.v2_denominator_check(mid,row,function(id,key)targetDims);refs
}
.domain_reconcile <- function(tx,release,datasets,totals) {
  s<-tx$schema;rid<-.store_uuid(release)
  for(domain in intersect(.domain_names(TRUE),names(totals))) {
    mid<-paste0('core.',domain,'.capture_count')
    cells<-paste0('(SELECT * FROM ',s,'.achillesnext_aggregate_cell WHERE release_id=',rid,' AND metric_id=',.store_literal(mid),')')
    .population_need(tx$one(paste0("WITH cells AS ",cells,", totals AS (SELECT dimensions-'concept_tag' AS dims,record_count,person_count FROM cells WHERE dimensions->'concept_tag'->>'kind'='all'), parts AS (SELECT dimensions-'concept_tag' AS dims,sum(record_count) AS n FROM cells WHERE dimensions->'concept_tag'->>'kind'<>'all' GROUP BY 1) SELECT count(*)::text FROM totals t FULL JOIN parts p USING(dims) WHERE t.record_count IS DISTINCT FROM COALESCE(p.n,0) OR t.person_count>t.record_count"))=='0','Domain ALL record totals do not reconcile')
    .population_need(tx$one(paste0('SELECT record_count::text FROM ',cells," c WHERE dimensions->'concept_tag'->>'kind'='all' AND dimensions->>'period_kind'='full_scope'"))==totals[[domain]]$raw,'Domain full-scope source total mismatch')
    for(suffix in c('frequency_histogram','distinct_concepts_histogram')) {
      hist<-paste0('core.',domain,'.',suffix)
      group<-if(suffix=='frequency_histogram')" GROUP BY dimensions->'concept_tag'" else ''
      .population_need(tx$one(paste0('SELECT count(*)::text FROM (SELECT COALESCE(sum(person_count),0) AS n FROM ',s,'.achillesnext_aggregate_cell WHERE release_id=',rid,' AND metric_id=',.store_literal(hist),group,') h WHERE n<>(SELECT person_count FROM ',s,".achillesnext_aggregate_cell WHERE release_id=",rid," AND metric_id='core.person.count')"))=='0','Domain person histogram does not reconcile')
    }
    .population_need(tx$one(paste0('SELECT count(*)::text FROM (SELECT sum(record_count) AS n FROM ',s,'.achillesnext_aggregate_cell WHERE release_id=',rid,' AND metric_id=',.store_literal(paste0('core.',domain,'.integrity_count'))," GROUP BY dimensions->>'flag') f WHERE n<>",totals[[domain]]$raw))=='0','Domain integrity marginals do not reconcile')
  }
  .store_domain_reconcile(tx,release,datasets);.store_reconcile(tx,release)
  invisible(TRUE)
}
