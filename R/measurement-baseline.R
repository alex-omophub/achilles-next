#' Generate the whole-source measurement and domain baseline
#' @inheritParams generateDomainBaseline
#' @param numericStrategy Exact summary operator, weighted (default) or reference.
#' @param maxAggregateRows Maximum saved aggregate rows, integer 1 to 1000000.
#' @return A restricted building release with 138 of 142 outputs. Four metadata
#'   outputs and complete publication remain unimplemented.
#' @details Generates all nineteen measurement outputs across every recorded
#'   concept, together with the existing population and eight-domain reports.
#'   Only saved aggregates are read during browsing. Numeric input must use exact
#'   PostgreSQL NUMERIC/integer types; FLOAT is rejected before casts.
#' @export
generateMeasurementBaseline <- function(connectionDetails,cdmSchema,sourceId,resultsSchema,declaredCdmVersion,
  maxStageBytes=64*1024^2,check=NULL,statementTimeoutMs=30000L,numericStrategy="weighted",maxAggregateRows=1000000L) {
  .nv_need(.string(numericStrategy)&&numericStrategy%in%c("weighted","reference"),"Choose an exact measurement summary strategy")
  .nv_need(is.numeric(maxAggregateRows)&&length(maxAggregateRows)==1L&&is.finite(maxAggregateRows)&&maxAggregateRows>=1&&
    maxAggregateRows<=1000000&&maxAggregateRows==floor(maxAggregateRows),"Invalid aggregate row budget")
  .baseline_generate(connectionDetails,cdmSchema,sourceId,resultsSchema,declaredCdmVersion,NULL,maxStageBytes,check,
    statementTimeoutMs,TRUE,TRUE,numericStrategy,maxAggregateRows=as.integer(maxAggregateRows))
}
.measurement_reports <- function(table,person,periods,cap,numericStrategy) {
  parts<-list(.domain_reports("measurement",table,person,periods,cap));core<-"core.measurement."
  dims<-function(...)paste0("jsonb_build_object(",paste(c(...),collapse=","),")")
  concept<-"'concept_tag',concept_tag"
  counts<-function(suffix,dimensions,people=TRUE)paste0("SELECT ",.store_literal(paste0(core,suffix)),"::text AS metric_id,'counts'::text AS row_kind,dimensions,",
    "jsonb_build_object('record_count',COUNT(*)::text",if(people)",'person_count',COUNT(DISTINCT person_id) FILTER(WHERE linked)::text" else "",
    ") AS values FROM (SELECT *,",dimensions," AS dimensions FROM ",table,") x GROUP BY dimensions")
  for(pair in list(c("unit_count","unit_concept_tag","unit_tag"),c("coded_value_count","value_concept_tag","value_concept_tag"),c("operator_count","raw_operator_tag","operator_tag")))
    parts[[length(parts)+1L]]<-counts(pair[1],dims(concept,paste0("'",pair[2],"',",pair[3])))
  # Frozen core ordering differs from the earlier observed-window tracer: unit
  # exclusions precede explicit comparator exclusion. Neither definition changes.
  numericReason<-"CASE WHEN value_as_number IS NULL THEN 'numeric_missing' WHEN value_as_number::text IN ('NaN','Infinity','-Infinity') THEN 'numeric_non_finite' WHEN unit_id IS NULL THEN 'unit_null' WHEN unit_id=0 THEN 'unit_zero' WHEN NOT known_unit THEN 'unit_unrecognized' WHEN operator_id IS NOT NULL AND operator_id<>0 THEN 'operator_explicit_measurement_only' ELSE 'eligible' END"
  parts[[length(parts)+1L]]<-counts("numeric_eligibility_count",dims(concept,paste0("'reason',",numericReason)),FALSE)
  rangeReason<-"CASE WHEN value_as_number IS NULL THEN 'numeric_missing' WHEN value_as_number::text IN ('NaN','Infinity','-Infinity') THEN 'numeric_non_finite' WHEN NOT known_unit THEN 'unit_unavailable_or_unrecognized' WHEN operator_id IS NOT NULL AND operator_id<>0 THEN 'operator_explicit' WHEN range_low IS NULL AND range_high IS NULL THEN 'both_bounds_missing' WHEN range_low IS NULL OR range_high IS NULL THEN 'one_bound_missing' WHEN range_low::text IN ('NaN','Infinity','-Infinity') OR range_high::text IN ('NaN','Infinity','-Infinity') THEN 'bound_non_finite' WHEN range_low>range_high THEN 'bounds_reversed' WHEN value_as_number<range_low THEN 'below' WHEN value_as_number>range_high THEN 'above' ELSE 'within' END"
  parts[[length(parts)+1L]]<-counts("range_status_count",dims(concept,"'unit_concept_tag',unit_tag","'raw_operator_tag',operator_tag",paste0("'reason',",rangeReason)),FALSE)
  parts[[length(parts)+1L]]<-paste0("SELECT 'core.measurement.representation_count','counts',jsonb_build_object('concept_tag',g.concept_tag,'representation_flags',flags),jsonb_build_object('record_count',COUNT(c.representation_flags)::text,'person_count',COUNT(DISTINCT c.person_id) FILTER(WHERE c.linked)::text) FROM (SELECT DISTINCT concept_tag FROM ",table,") g CROSS JOIN (SELECT a.v||b.v||c.v AS flags FROM (VALUES('0'),('1')) a(v) CROSS JOIN (VALUES('0'),('1')) b(v) CROSS JOIN (VALUES('0'),('1')) c(v)) f LEFT JOIN ",table," c ON c.concept_tag=g.concept_tag AND c.representation_flags=f.flags GROUP BY g.concept_tag,flags")
  samples<-list();categories<-list();reasons<-.v2_assets()$profile$contracts$`eligibility-reasons`
  sample<-function(suffix,dimensions,value,reason,filter,order) {
    mid<-paste0(core,suffix)
    samples[[length(samples)+1L]]<<-paste0("SELECT ",.store_literal(mid),"::text AS metric_id,",dimensions," AS dimensions,",value," AS value,",reason," AS reason FROM ",table," WHERE ",filter)
    for(r in unlist(order))categories[[length(categories)+1L]]<<-paste0("(",.store_literal(mid),",",.store_literal(r),",'record_count')")
  }
  sample("numeric_summary",dims(concept,"'unit_concept_tag',unit_tag","'raw_operator_tag',operator_tag"),"value_as_number",numericReason,
    "known_unit AND (operator_id IS NULL OR operator_id=0)",reasons$numeric_summary_order)
  for(bound in c("low","high")) {
    value<-paste0("range_",bound)
    reason<-paste0("CASE WHEN ",value," IS NULL THEN 'bound_missing' WHEN ",value,"::text IN ('NaN','Infinity','-Infinity') THEN 'bound_non_finite' WHEN unit_id IS NULL THEN 'unit_null' WHEN unit_id=0 THEN 'unit_zero' WHEN NOT known_unit THEN 'unit_unrecognized' ELSE 'eligible' END")
    sample(paste0(value,"_summary"),dims(concept,"'unit_concept_tag',unit_tag"),value,reason,"known_unit",reasons$range_boundary_order)
    # Excluded raw unit groups cannot carry a summary (NULL/zero units are not
    # valid summary dimensions). Keep their actual first-match exclusions as
    # eligibility-only rows, without an eligible=0 summary companion.
    parts[[length(parts)+1L]]<-paste0("SELECT ",.store_literal(paste0(core,value,"_summary")),
      ",'eligibility_counts',dimensions,jsonb_build_object('record_count',COUNT(*)::text) FROM (SELECT ",
      dims(concept,"'unit_concept_tag',unit_tag",paste0("'eligibility_reason',",reason)),
      " AS dimensions FROM ",table," WHERE NOT known_unit) excluded GROUP BY dimensions")
  }
  sql<-paste(readLines(system.file("sql/postgresql/measurement-summary.sql",package="AchillesNext",mustWork=TRUE),warn=FALSE),collapse="\n")
  ranks<-if(numericStrategy=="weighted")"SELECT metric_id,dimensions,value,SUM(frequency) OVER(PARTITION BY metric_id,dimensions ORDER BY value ROWS UNBOUNDED PRECEDING) AS rank FROM (SELECT metric_id,dimensions,value,COUNT(*)::numeric AS frequency FROM eligible GROUP BY metric_id,dimensions,value) f" else
    "SELECT metric_id,dimensions,value,ROW_NUMBER() OVER(PARTITION BY metric_id,dimensions ORDER BY value)::numeric AS rank FROM eligible"
  for(k in c("samples","categories","ranks")) {
    value<-switch(k,samples=paste(samples,collapse=" UNION ALL "),categories=paste0("SELECT * FROM (VALUES ",paste(categories,collapse=","),") v(metric_id,reason,measure)"),ranks=ranks)
    sql<-gsub(paste0("{{",k,"}}"),value,sql,fixed=TRUE)
  }
  .nv_need(!grepl("{{",sql,fixed=TRUE),"Unbound measurement SQL token")
  parts[[length(parts)+1L]]<-sql
  paste(vapply(parts,function(p)paste0("SELECT * FROM (",p,") report"),""),collapse=" UNION ALL ")
}
