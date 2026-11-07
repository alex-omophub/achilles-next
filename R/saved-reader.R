# Internal verified traversal. Physical pages remain behind the future semantic API.
.saved_reader <- function(transport,cacheBytes=4194304L,maxObjects=64L,maxBytes=8388608L,maxRows=8192L) {
  context <- .saved_context(transport$context);assets <- .profile_context(context)
  control <- function(x,lo,hi) is.numeric(x)&&length(x)==1L&&!is.na(x)&&is.finite(x)&&x==floor(x)&&x>=lo&&x<=hi
  .nv_need(control(cacheBytes,0,8388608L) && control(maxObjects,1,256L) && control(maxBytes,1,16777216L) && control(maxRows,1,32768L),"Invalid read budget")
  .nv_need(is.function(transport$read)&&is.function(transport$check)&&is.logical(transport$cacheAllowed)&&length(transport$cacheAllowed)==1L&&!is.na(transport$cacheAllowed))
  if(!transport$cacheAllowed) cacheBytes <- 0L
  state <- new.env(parent=emptyenv());state$closed <- FALSE;state$generation <- 0L
  state$cache <- list();state$order <- character();state$bytes <- 0L
  state$stats <- list(fetched_objects=0L,fetched_bytes=0,cache_hits=0L)
  # UUID.randomUUID uses the already required JVM's secure random source.
  rJava::.jinit();uuid <- rJava::.jcall("java/util/UUID","Ljava/util/UUID;","randomUUID")
  secret <- rJava::.jcall(uuid,"S","toString")
  contextHash <- .v2_hash(.v2_bytes(context))
  clear <- function() {state$cache<-list();state$order<-character();state$bytes<-0L;state$generation<-state$generation+1L}
  check <- function(cancel,generation) {
    if(state$closed) .saved_error("closed")
    transport$check(cancel)
    if(state$closed) .saved_error("closed")
    if(generation!=state$generation) .saved_error("superseded")
  }
  encode <- function(doc) {
    bytes <- .v2_bytes(doc)
    encoded <- sub("=+$","",chartr("+/","-_",gsub("[\r\n]","",jsonlite::base64_enc(bytes))))
    paste0(encoded,".",digest::hmac(secret,bytes,algo="sha256"))
  }
  decode <- function(token,selection) tryCatch({
    .nv_need(.string(token) && nchar(token,type="bytes")<=8192L && grepl("^[A-Za-z0-9_-]+[.][a-f0-9]{64}$",token))
    parts <- strsplit(token,".",fixed=TRUE)[[1]]
    bytes <- jsonlite::base64_dec(paste0(chartr("-_","+/",parts[[1]]),strrep("=",(4L-nchar(parts[[1]])%%4L)%%4L)))
    doc <- .nv_json(bytes);.v2_keys(doc,c("version","context_sha256","selection_sha256","generation","last_key"))
    .nv_need(identical(token,encode(doc)) && identical(doc$version,1L) && identical(doc$context_sha256,contextHash) && identical(doc$selection_sha256,selection) && identical(doc$generation,state$generation) && .saved_key(doc$last_key))
    doc$last_key
  },error=function(e).saved_error("invalid_cursor"))
  run <- function(cancel,work) tryCatch({
    generation <- state$generation;check(cancel,generation)
    used <- new.env(parent=emptyenv());used$objects<-0L;used$bytes<-0;used$rows<-0L
    get <- function(d) {
      check(cancel,generation);.v2_descriptor_check(d)
      used$objects <- used$objects+1L;used$bytes <- used$bytes+as.numeric(d$bytes)
      if(!d$kind%in%c("root","index")) {
        if(.nv_unsigned_cmp(d$rows,as.character(maxRows-used$rows))>0L) .saved_error("resource_limit")
        used$rows <- used$rows+as.integer(d$rows)
      }
      if(used$objects>maxObjects || used$bytes>maxBytes) .saved_error("resource_limit")
      raw <- state$cache[[d$sha256]]
      if(is.null(raw)) {
        raw <- transport$read(d,cancel);check(cancel,generation)
        .nv_need(is.raw(raw) && length(raw)<=.v2_limit(d$kind),"Transport byte limit")
        state$stats$fetched_objects <- state$stats$fetched_objects+1L
        state$stats$fetched_bytes <- state$stats$fetched_bytes+length(raw)
      } else state$stats$cache_hits <- state$stats$cache_hits+1L
      page <- .saved_page(raw,d,context[.saved_common()],assets);check(cancel,generation)
      # Cache only verified raw bytes, never mutable decoded objects or authority.
      if(cacheBytes>0L && length(raw)<=cacheBytes) {
        if(!is.null(state$cache[[d$sha256]])) {
          state$bytes <- state$bytes-length(state$cache[[d$sha256]])
          state$order <- state$order[state$order!=d$sha256];state$cache[[d$sha256]]<-NULL
        }
        while(length(state$order)>=64L || state$bytes+length(raw)>cacheBytes) {
          oldest <- state$order[[1]];state$order <- state$order[-1]
          state$bytes <- state$bytes-length(state$cache[[oldest]]);state$cache[[oldest]]<-NULL
        }
        state$cache[[d$sha256]]<-raw;state$order<-c(state$order,d$sha256);state$bytes<-state$bytes+length(raw)
      }
      c(list(descriptor=d,bytes=raw),page)
    }
    value <- work(get)
    check(cancel,generation)
    value$budget <- list(objects=used$objects,bytes=used$bytes,rows=used$rows)
    value
  },error=function(e) {
    clear()
    if(inherits(e,"achillesnext_read_error")) stop(e)
    .saved_error("integrity_failure")
  })
  scan <- function(branch,lower=NULL,upper=NULL,limit=1L,cursor=NULL,cancel=function()FALSE) run(cancel,function(get) {
    names <- c(data="data",metric_catalogue="catalogue",concept_catalogue="concepts",terminology="terminology")
    if(!.string(branch)||!branch%in%names(names)||!control(limit,1,16)||(!is.null(lower)&&!.saved_key(lower))||(!is.null(upper)&&!.saved_key(upper))||(!is.null(lower)&&!is.null(upper)&&.v2_less(upper,lower))) .saved_error("invalid_request")
    selection <- .v2_hash(.v2_bytes(.object(branch=branch,lower=lower,upper=upper)))
    after <- if(is.null(cursor))NULL else decode(cursor,selection)
    if(!is.null(after) && ((!is.null(lower)&&.v2_less(after,lower))||(!is.null(upper)&&.v2_less(upper,after)))) .saved_error("invalid_cursor")
    root <- get(context$root)$document
    allowed <- .v2_policy(root$disclosure$policy,assets)
    pages <- list();more <- FALSE;last <- NULL;seen <- context$root$sha256
    intersects <- function(lo,hi) (is.null(lower)||!.v2_less(hi,lower)) && (is.null(upper)||!.v2_less(upper,lo)) && (is.null(after)||.v2_less(after,hi))
    walk <- function(d,lo=NULL,hi=NULL,depth=0L) {
      if(!is.null(lo)&&!intersects(lo,hi)) return(invisible(NULL))
      if(length(pages)>=limit) {more<<-TRUE;return(invisible(NULL))}
      if(depth>8L || d$sha256%in%seen) .saved_error("integrity_failure")
      seen <<- c(seen,d$sha256);page <- get(d);doc <- page$document
      if(!is.null(lo)) .nv_need(identical(page$lo,lo)&&identical(page$hi,hi),"Index range mismatch")
      if(doc$kind=="index") {
        .nv_need(depth<8L && identical(doc$index_kind,branch),"Index depth/kind mismatch")
        for(child in doc$children) walk(child$object,child$lower_key,child$upper_key,depth+1L)
      } else {
        .nv_need(identical(doc$kind,branch))
        if(!intersects(page$lo,page$hi)) return(invisible(NULL))
        if(branch=="data" && !doc$metric_id%in%allowed) .nv_need(all(vapply(doc$rows,function(r)r$state=="suppressed",TRUE)),"Policy output leak")
        if(branch=="metric_catalogue") for(entry in doc$entries) if(!entry$metric_id%in%allowed)
          .nv_need(identical(entry$state,"suppressed") && identical(entry$rows,"0"),"Policy catalogue leak")
        pages[[length(pages)+1L]] <<- page;last <<- page$hi
      }
      invisible(NULL)
    }
    walk(root[[names[[branch]]]])
    # A cursor describes the last complete partition, never a numeric offset.
    nextCursor <- if(more && !is.null(last)) encode(.object(version=1L,context_sha256=contextHash,selection_sha256=selection,generation=state$generation,last_key=last)) else NULL
    list(pages=pages,cursor=nextCursor,complete=is.null(nextCursor))
  })
  list(root=function(cancel=function()FALSE)run(cancel,function(get)list(page=get(context$root))),scan=scan,
    close=function(){if(!state$closed){state$closed<-TRUE;clear()};invisible(NULL)},
    inspect=function()c(state$stats,list(cache_bytes=state$bytes,cache_objects=length(state$order),cache_allowed=transport$cacheAllowed,closed=state$closed,generation=state$generation)))
}
