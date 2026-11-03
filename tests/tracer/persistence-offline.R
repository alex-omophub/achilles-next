# Queue bounds and validation failures require no database; numerical corpus is
# independently checked by the native/JavaScript differential tests.
library(AchillesNext)
local({
  args<-commandArgs(TRUE);stopifnot(length(args)==1L)
  f<-function(n)get(n,asNamespace("AchillesNext"));o<-f(".object")
  cases<-jsonlite::fromJSON(args[[1]],simplifyVector=FALSE)
  cases<-Filter(function(c)isTRUE(c$valid),cases)
  stopifnot(length(cases)>100L,any(vapply(cases,function(c)c$row$row_kind=="metadata",TRUE)))
  sql<-character();tx<-list(schema='"fixture"',execute=function(s)sql<<-c(sql,s))
  release<-"00000000-0000-4000-8000-000000000001"
  writer<-f(".store_writer")(tx,release,maxRows=2L,maxBytes=1048576)
  for(c in cases)writer$add(c$metric_id,c$row)
  stats<-writer$finish();stopifnot(stats$rows==length(cases),stats$peak_queued_rows<=2,
    stats$peak_queued_sql_bytes<=1048576,all(nchar(enc2utf8(sql),type="bytes")<=1048576),
    identical(stats,writer$finish()),grepl("9007199254740993",paste(sql,collapse=""),fixed=TRUE))
  rejects<-function(work)stopifnot(inherits(try(work(),silent=TRUE),"try-error"))
  rejects(function()writer$add(cases[[1]]$metric_id,cases[[1]]$row))
  a<-f(".profile_assets")("reference-person-v1");mid<-names(a$metrics)[[1]]
  row<-o(row_key="",dimensions=o(),row_kind="counts",state="computed",reason_code=NULL,values=o(person_count="9007199254740993"),denominator_refs=list())
  row$row_key<-f(".v2_row_identity")(a$rows[[mid]],row)
  sql<-character();writer<-f(".store_writer")(tx,release,a,maxRows=1L)
  writer$add(mid,row);stopifnot(!length(sql));writer$finish();stopifnot(length(sql)==1L)
  size<-f(".store_row_parts")(tx$schema,release,mid,row,a)$bytes
  sql<-character();writer<-f(".store_writer")(tx,release,a,maxBytes=size-1)
  rejects(function()writer$add(mid,row));rejects(function()writer$finish());stopifnot(!length(sql))
  # A byte cap can force a flush before the row cap is reached.
  sql<-character();writer<-f(".store_writer")(tx,release,a,maxRows=128L,maxBytes=2*size-1)
  writer$add(mid,row);writer$add(mid,row);stats<-writer$finish()
  stopifnot(stats$peak_queued_rows==1L,stats$cell_statements==2L)
  sql<-character();writer<-f(".store_writer")(tx,release,a)
  bad<-row;bad$values$person_count<-"1.0"
  rejects(function()writer$add(mid,bad));rejects(function()writer$finish());stopifnot(!length(sql))
  calls<-0;broken<-list(schema=tx$schema,execute=function(s){calls<<-calls+1L;stop("Injected write failure")})
  writer<-f(".store_writer")(broken,release,a);writer$add(mid,row)
  rejects(function()writer$finish());rejects(function()writer$finish());stopifnot(calls==1L)
  for(bounds in list(list(maxRows=0),list(maxRows=1025),list(maxBytes=NA_real_),list(maxBytes=4*1024^2+1)))
    rejects(function()do.call(f(".store_writer"),c(list(tx=tx,releaseId=release),bounds)))
  cat("BOUNDED_PERSISTENCE_MIXED_ROWS_BYTE_LIMITS_EXACT_VALUES_AND_FAIL_CLOSED_OK\n")
})
