# A typed write seam for trusted aggregate producers; never accepts patient rows.
.store_put_row <- function(tx,releaseId,metricId,row) {
  key<-.v2_row(metricId,row)
  columns<-c(record_count="record_count",person_count="person_count",person_days="person_days",interval_count="interval_count",
    n="n",sum="sum_value",min="minimum",max="maximum",p10="p10",p25="p25",p50="p50",p75="p75",p90="p90")
  columns<-columns[names(columns)%in%names(row$values)]
  .nv_need(row$row_kind%in%c("counts","eligibility_counts","summary"),"This producer writes numerical aggregates only")
  tx$execute(paste0("INSERT INTO ",tx$schema,".achillesnext_aggregate_cell(release_id,metric_id,row_key,route_key,sort_key,dimensions,state,reason_code,payload_kind",
    if(length(columns))paste0(",",paste(columns,collapse=",")) else "",
    ") VALUES (",paste(c(.store_uuid(releaseId),.store_literal(metricId),.store_literal(row$row_key),"'A'",.store_literal(key),
      paste0(.store_literal(.json(row$dimensions)),"::jsonb"),.store_literal(row$state),if(is.null(row$reason_code))"NULL" else .store_literal(row$reason_code),
      .store_literal(if(row$row_kind=="eligibility_counts")"counts" else row$row_kind),
      vapply(names(columns),function(k)if(is.null(row$values[[k]]))"NULL" else row$values[[k]],"")),collapse=","),")"))
  for(ref in row$denominator_refs) tx$execute(paste0("INSERT INTO ",tx$schema,".achillesnext_denominator_edge VALUES (",
    paste(c(.store_uuid(releaseId),vapply(c(metricId,row$row_key,ref$measure,ref$metric_id,ref$row_key,ref$field),.store_literal,"")),collapse=","),")"))
  invisible(key)
}
