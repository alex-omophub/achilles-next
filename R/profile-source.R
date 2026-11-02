# Internal source/store seam for installed registered profiles. The caller owns
# the transaction; this borrowed source handle has no store schema or commit API.
.profile_source <- function(query,assets,schema,metricOrder,maxRows) {
  schemaHash <- .profile_preflight(query,assets,schema)
  check <- .store_decode(query$one(.profile_sql(assets$entry$check_sql,schema)))
  .analysis_keys(check,c("valid","source_count"))
  .nv_need(isTRUE(check$valid)&&.v2_count(check$source_count),"Invalid registered source membership")
  order <- paste(vapply(seq_along(metricOrder),function(i)paste0("WHEN ",.store_literal(metricOrder[[i]])," THEN ",i),""),collapse=" ")
  sql <- paste0("SELECT doc FROM (",.profile_sql(assets$entry$producer_sql,schema),") q(doc) ORDER BY CASE doc::jsonb->>'metric_id' ",order," ELSE 2147483647 END")
  used <- FALSE
  list(schema_sha256=schemaHash,source_count=check$source_count,stream=function(visit) {
    .nv_need(!used,"Source aggregate stream is single-use");used <<- TRUE;seen <- 0L
    query$stream(sql,function(text) {
      seen <<- seen+1L
      .nv_need(.string(text)&&seen<=maxRows&&nchar(text,type="bytes")<=65536L,"Registered aggregate resource limit")
      visit(.store_decode(text))
    })
    invisible(NULL)
  })
}
# Consume typed aggregate records without source SQL or a database connection.
# writer$add validates complete rows before SQL; lifecycle remains with the caller.
.profile_consume <- function(source,writer,assets) {
  .nv_need(.v2_count(source$source_count),"Invalid source count")
  empty <- source$source_count=="0";state <- if(empty)"empty_source" else "computed";reason <- if(empty)"source.empty" else NULL
  counts <- stats::setNames(rep(list("0"),length(assets$metrics)),names(assets$metrics));targets <- list();seen <- 0L
  source$stream(function(item) {
    seen <<- seen+1L
    .analysis_keys(item,c("metric_id","dimensions","row_kind","values"));mid <- item$metric_id
    .nv_need(.string(mid)&&mid%in%names(assets$metrics),"Unregistered generated metric")
    row <- .object(row_key="",dimensions=item$dimensions,row_kind=item$row_kind,state=state,reason_code=reason,values=item$values,denominator_refs=list())
    spec <- .analysis_denominator(mid,row,assets,forKey=TRUE)
    if(!is.null(spec)) {
      target <- targets[[spec$metric_id]];.nv_need(!is.null(target),"Missing generated singleton dependency")
      row$denominator_refs <- lapply(spec$measures,function(m).object(measure=m$source,metric_id=spec$metric_id,row_key=target$row_key,field=m$target,value=target$values[[m$target]]))
      .v2_denominator_check(mid,row,function(id,key)target$dimensions,assets)
    }
    row$row_key <- .v2_row_identity(assets$rows[[mid]],row);writer$add(mid,row)
    counts[[mid]] <<- .nv_add(counts[[mid]],"1")
    if(mid%in%assets$singletons) {.nv_need(counts[[mid]]=="1","Duplicate generated singleton");targets[[mid]] <<- row}
  })
  .nv_need(all(vapply(counts[assets$singletons],function(n)n=="1",TRUE)),"Missing generated singleton")
  list(counts=counts,seen=seen)
}
