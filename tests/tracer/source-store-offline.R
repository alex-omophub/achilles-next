# Source aggregate transport and typed ingestion can be exercised independently.
library(AchillesNext)
local({
  f <- function(n)get(n,asNamespace("AchillesNext"));o <- f(".object");wire <- f(".json")
  a <- f(".profile_assets")("reference-person-v1");ids <- names(a$metrics)
  fixture <- jsonlite::fromJSON("tests/fixtures/reference-person-v1.json",simplifyVector=FALSE)
  records <- unlist(lapply(ids,function(mid)lapply(fixture$expected[[mid]],function(row)
    o(metric_id=mid,dimensions=row$dimensions,row_kind="counts",values=row$values))),recursive=FALSE)
  rejects <- function(work)stopifnot(inherits(try(work(),silent=TRUE),"try-error"))
  queries <- character();sourceCount <- "6";raw <- vapply(records,wire,"")
  query <- list(one=function(sql) {
    queries <<- c(queries,sql)
    if(grepl("information_schema.columns",sql,fixed=TRUE)) return('{"type":"bigint","nullable":"YES"}')
    wire(o(valid=TRUE,source_count=sourceCount))
  },stream=function(sql,visit) {queries <<- c(queries,sql);for(text in raw)visit(text)})
  source <- function(limit=100L)f(".profile_source")(query,a,"cdm",as.list(ids),limit)
  rows <- list();writer <- list(add=function(mid,row) {
    f(".v2_row")(mid,row,a);rows[[length(rows)+1L]] <<- o(metric_id=mid,row=row)
  })
  port <- source();result <- f(".profile_consume")(port,writer,a)
  stopifnot(identical(names(port),c("schema_sha256","source_count","stream")),
    grepl("^[a-f0-9]{64}$",port$schema_sha256),result$seen==5L,
    identical(unname(unlist(result$counts)),c("1","4")),length(rows)==5L,
    rows[[5]]$row$dimensions$gender_concept_id=="9007199254740993",
    all(vapply(rows[-1],function(x)x$row$denominator_refs[[1]]$value=="6",TRUE)),
    !any(grepl("achillesnext_|INSERT|UPDATE|DELETE|COMMIT|ROLLBACK",queries)))
  rejects(function()port$stream(identity))
  # A source without SQL or a connection feeds the same typed sink unchanged.
  huge <- "9007199254740993"
  big <- list(o(metric_id=ids[1],dimensions=o(),row_kind="counts",values=o(person_count=huge)),
    o(metric_id=ids[2],dimensions=o(gender_concept_id="0"),row_kind="counts",values=o(person_count=huge)))
  memory <- function(items,count=huge)list(source_count=count,stream=function(visit)for(item in items)visit(item))
  rows <- list();result <- f(".profile_consume")(memory(big),writer,a)
  stopifnot(result$seen==2L,rows[[2]]$row$values$person_count==huge,
    rows[[2]]$row$denominator_refs[[1]]$value==huge)
  for(value in list(1,"1.0","NaN","Infinity","1e3","-1")) {
    bad <- big;bad[[1]]$values$person_count <- value
    rejects(function()f(".profile_consume")(memory(bad),writer,a))
  }
  bad <- big;bad[[1]]$patient_id <- "forbidden"
  rejects(function()f(".profile_consume")(memory(bad),writer,a))
  rejects(function()f(".profile_consume")(memory(rev(big)),writer,a))
  rejects(function()f(".profile_consume")(memory(big[-1]),writer,a))
  rejects(function()f(".profile_consume")(memory(c(big[1],big)),writer,a))
  # Transport limits and single-use failure behavior do not require a database.
  port <- source(1L);rejects(function()port$stream(identity));rejects(function()port$stream(identity))
  raw <- strrep("x",65537L);port <- source();rejects(function()port$stream(identity))
  raw <- NA_character_;port <- source();rejects(function()port$stream(identity))
  raw <- vapply(records,wire,"");port <- source()
  rejects(function()port$stream(function(item)stop("injected sink cancellation")))
  rejects(function()port$stream(identity))
  # An empty source retains its zero singleton and explicit empty state.
  zero <- big[1];zero[[1]]$values$person_count <- "0";rows <- list()
  f(".profile_consume")(memory(zero,"0"),writer,a)
  stopifnot(length(rows)==1L,rows[[1]]$row$state=="empty_source",rows[[1]]$row$reason_code=="source.empty")
  cat("SOURCE_ONLY_PORT_TYPED_SINK_EXACT_COUNTS_LIMITS_AND_FAILURES_OK\n")
})
