# Prepare immutable SQL fragments only after exact row validation. Both writers
# use this seam, including the single-row reference path.
.store_row_parts <- function(schema,releaseId,metricId,row,assets = .v2_assets()) {
  key<-.v2_row(metricId,row,assets)
  columns<-c(record_count="record_count",person_count="person_count",person_days="person_days",interval_count="interval_count",
    n="n",sum="sum_value",min="minimum",max="maximum",p10="p10",p25="p25",p50="p50",p75="p75",p90="p90")
  columns<-columns[names(columns)%in%names(row$values)]
  .nv_need(row$row_kind%in%c("counts","eligibility_counts","summary","metadata"),"Unknown typed aggregate payload")
  metadata<-identical(row$row_kind,"metadata")
  prefix<-paste0("INSERT INTO ",schema,".achillesnext_aggregate_cell(release_id,metric_id,row_key,route_key,sort_key,dimensions,state,reason_code,payload_kind",
    if(length(columns))paste0(",",paste(columns,collapse=",")) else "",if(metadata)",metadata_value" else "",
    ") VALUES ")
  cell<-paste0("(",paste(c(.store_uuid(releaseId),.store_literal(metricId),.store_literal(row$row_key),"'A'",.store_literal(key),
      paste0(.store_literal(.json(row$dimensions)),"::jsonb"),.store_literal(row$state),if(is.null(row$reason_code))"NULL" else .store_literal(row$reason_code),
      .store_literal(if(row$row_kind=="eligibility_counts")"counts" else row$row_kind),
      vapply(names(columns),function(k)if(is.null(row$values[[k]]))"NULL" else row$values[[k]],""),
      if(metadata)if(is.null(row$values))"NULL" else paste0(.store_literal(.json(row$values)),"::jsonb") else character()),collapse=","),")")
  edgePrefix<-paste0("INSERT INTO ",schema,".achillesnext_denominator_edge VALUES ")
  edges<-vapply(row$denominator_refs,function(ref)paste0("(",paste(c(.store_uuid(releaseId),vapply(c(metricId,row$row_key,ref$measure,ref$metric_id,ref$row_key,ref$field),.store_literal,"")),collapse=","),")"),"")
  bytes<-nchar(enc2utf8(prefix),type="bytes")+nchar(enc2utf8(cell),type="bytes")+1+
    sum(nchar(enc2utf8(edges),type="bytes")+nchar(enc2utf8(edgePrefix),type="bytes")+1)
  list(key=key,prefix=prefix,cell=cell,edge_prefix=edgePrefix,edges=edges,bytes=bytes)
}
# A typed reference writer; useful for parity and bounded persistence benchmarks.
.store_put_row <- function(tx,releaseId,metricId,row,assets = .v2_assets()) {
  p<-.store_row_parts(tx$schema,releaseId,metricId,row,assets)
  tx$execute(paste0(p$prefix,p$cell))
  for(edge in p$edges)tx$execute(paste0(p$edge_prefix,edge))
  invisible(p$key)
}
