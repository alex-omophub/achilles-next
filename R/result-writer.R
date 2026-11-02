# Bounded numerical-aggregate writer. Existing row triggers remain authoritative;
# no trigger bypass, source query, store migration or revision reinterpretation.
.store_writer <- function(tx,releaseId,assets=.v2_assets(),maxRows=128L,maxBytes=1024^2) {
  valid <- function(x,lo,hi)is.numeric(x)&&length(x)==1L&&!is.na(x)&&is.finite(x)&&x==floor(x)&&x>=lo&&x<=hi
  .nv_need(valid(maxRows,1,1024)&&valid(maxBytes,256,4*1024^2),"Invalid persistence batch bounds")
  queue<-list();bytes<-0;closed<-FALSE;failed<-FALSE
  stats<-.object(strategy="bounded_values",rows=0,edges=0,cell_statements=0,edge_statements=0,
    sql_bytes=0,peak_queued_rows=0,peak_queued_sql_bytes=0,max_rows=maxRows,max_sql_bytes=maxBytes)
  guard<-function().nv_need(!closed&&!failed,"Persistence writer is closed or failed")
  safe<-function(work)tryCatch(work(),error=function(e){failed<<-TRUE;stop(e)},interrupt=function(e){failed<<-TRUE;stop(e)})
  submit<-function(sql,kind) {
    n<-nchar(enc2utf8(sql),type="bytes");.nv_need(n<=maxBytes,"Persistence SQL byte limit")
    tx$execute(sql)
    field<-paste0(kind,"_statements");stats[[field]]<<-stats[[field]]+1
    stats$sql_bytes<<-stats$sql_bytes+n
  }
  flush<-function()safe(function() {
    guard();if(!length(queue))return(invisible(NULL))
    prefixes<-unique(vapply(queue,function(p)p$prefix,""))
    # Different row kinds can have different numerical column sets. Insert all
    # cells before any edges so in-batch dependencies satisfy the existing FKs.
    for(prefix in prefixes) {
      cells<-vapply(Filter(function(p)identical(p$prefix,prefix),queue),function(p)p$cell,"")
      submit(paste0(prefix,paste(cells,collapse=",")),"cell")
    }
    edges<-unlist(lapply(queue,function(p)p$edges),use.names=FALSE)
    if(length(edges))submit(paste0(queue[[1]]$edge_prefix,paste(edges,collapse=",")),"edge")
    stats$rows<<-stats$rows+length(queue);stats$edges<<-stats$edges+length(edges)
    queue<<-list();bytes<<-0;invisible(NULL)
  })
  add<-function(metricId,row)safe(function() {
    guard();p<-.store_row_parts(tx$schema,releaseId,metricId,row,assets)
    .nv_need(p$bytes<=maxBytes,"Aggregate exceeds persistence byte budget")
    if(length(queue)&&(length(queue)>=maxRows||bytes+p$bytes>maxBytes))flush()
    queue[[length(queue)+1L]]<<-p;bytes<<-bytes+p$bytes
    stats$peak_queued_rows<<-max(stats$peak_queued_rows,length(queue))
    stats$peak_queued_sql_bytes<<-max(stats$peak_queued_sql_bytes,bytes)
    invisible(p$key)
  })
  finish<-function() {
    if(!closed){flush();closed<<-TRUE}
    .nv_need(!failed,"Persistence writer failed");stats
  }
  list(add=add,flush=flush,finish=finish)
}
