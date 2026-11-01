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
.domain_denominators <- function(tx,release,mid,row) {
  definition<-.v2_assets()$metrics[[mid]]$denominator
  if(is.null(definition)||row$row_kind!='counts'||row$state%in%c('unsupported','unavailable'))return(list())
  dims<-row$dimensions;target<-strsplit(definition,' ',fixed=TRUE)[[1]][1];targetDims<-.object();measures<-'person_count'
  if(grepl('for full-scope',definition,fixed=TRUE)&&dims$period_kind!='full_scope')return(list())
  if(grepl('same period',definition,fixed=TRUE))targetDims<-dims[c('period_kind','period_start','period_end')]
  if(grepl('same year/gender/age',definition,fixed=TRUE))targetDims<-dims[c('year','gender_concept_id','year_age_decile')]
  if(grepl('in full scope',definition,fixed=TRUE)){targetDims<-c(dims['concept_tag'],.object(period_kind='full_scope',period_start='null',period_end='null'));measures<-c('record_count','person_count')}
  key<-.v2_row_identity(.v2_assets()$rows[[target]],.object(row_kind='counts',dimensions=targetDims))
  values<-.store_decode(tx$one(paste0("SELECT jsonb_build_object('person_count',person_count::text,'record_count',record_count::text)::text FROM ",tx$schema,".achillesnext_aggregate_cell WHERE release_id=",.store_uuid(release)," AND metric_id=",.store_literal(target)," AND row_key=",.store_literal(key))))
  refs<-lapply(measures,function(measure).object(measure=measure,metric_id=target,row_key=key,field=measure,value=values[[measure]]))
  row$denominator_refs<-refs;.v2_denominator_check(mid,row,function(id,key)targetDims);refs
}
.domain_reconcile <- function(tx,release,datasets,totals) {
  s<-tx$schema;rid<-.store_uuid(release)
  for(domain in .domain_names()) {
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
