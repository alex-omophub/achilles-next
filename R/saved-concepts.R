# Saved terminology access. Contract 2.0.0 has no approved labels/name index.
# Keep that absence explicit; never use source SQL, IDs-as-names or fuzzy scans.
.saved_concept_methods <- function(reader,identity,bounded,input) {
  info <- .object(state="unavailable",reason_code="terminology.labels_not_saved",
    matching="unavailable",
    label_source=.object(state="unavailable",reason_code="terminology.label_source_not_saved"),
    vocabulary_release=.object(state="unavailable",reason_code="terminology.vocabulary_release_not_saved"))
  lookup <- function(conceptIds,limit=25L,cursor=NULL,maxBytes=1048576L,cancel=function()FALSE) {
    reader$session(function(api) {
      if(!is.character(conceptIds)||length(conceptIds)<1L||length(conceptIds)>100L||anyNA(conceptIds)||
         anyDuplicated(conceptIds)||any(nchar(conceptIds,type="bytes")>513L)||
         !bounded(limit,100L)||!bounded(maxBytes,8388608L)) .saved_error("invalid_request")
      # The signed integer codec validates canonical strings and preserves IDs
      # larger than an R double can represent. Null/all are not concept IDs.
      keys <- input(function()vapply(conceptIds,function(id).v2_component(id,"integer"),""))
      order <- order(keys,method="radix");keys<-unname(keys[order]);conceptIds<-unname(conceptIds[order])
      selector <- .v2_hash(.v2_bytes(.object(operation="lookup_concepts",concept_ids=as.list(conceptIds),limit=limit,max_bytes=maxBytes)))
      after <- api$decode(cursor,selector)
      api$root() # Check pinned root/authority even when the concept tree is empty.
      entries <- list();complete<-TRUE;entryBytes<-0L
      build <- function(items,complete).object(state="available",reason_code=NULL,context=identity,
        terminology=info,concepts=items,complete=complete,
        cursor=if(complete)NULL else api$cursor(selector,.v2_component(items[[length(items)]]$concept_tag,"concept_tag")),
        generation_requested=FALSE)
      headerBytes<-api$measure(build(list(),TRUE))
      for(i in seq_along(keys)) {
        api$check();key<-keys[[i]]
        if(!is.null(after)&&!.v2_less(after,key))next
        if(length(entries)>=limit){complete<-FALSE;break}
        found<-NULL
        api$walk("concept_catalogue",lower=key,upper=key,visit=function(doc) {
          for(entry in doc$entries) {
            api$check()
            if(identical(.v2_component(entry$concept_tag,"concept_tag"),key)) {
              .nv_need(is.null(found),"Duplicate concept coverage");found<<-entry
            }
          }
          TRUE
        })
        item <- if(is.null(found)) .object(concept_tag=.object(kind="id",value=conceptIds[[i]]),
          label=NULL,label_state="unavailable",state="not_saved",reason_code="concept.not_saved") else
          c(found,.object(state="available",reason_code=NULL))
        entries[[length(entries)+1L]]<-item;entryBytes<-entryBytes+length(.v2_bytes(item))
        if(headerBytes+entryBytes>maxBytes){complete<-i==length(keys);break}
      }
      .saved_fit_page(entries,complete,build,api$measure,maxBytes)
    },cancel,responseLimit=maxBytes)
  }
  search <- function(query,limit=25L,cursor=NULL,maxBytes=1048576L,cancel=function()FALSE) {
    reader$session(function(api) {
      if(!.string(query)||nchar(query,type="bytes")>256L||!validUTF8(query)||
         !nzchar(trimws(query))||grepl("[[:cntrl:]]",query)||
         !bounded(limit,100L)||!bounded(maxBytes,8388608L)) .saved_error("invalid_request")
      # There are no valid search continuations for this physical contract.
      if(!is.null(cursor)) .saved_error("invalid_cursor")
      api$root() # A real serving-view read still enforces live DB revocation.
      .object(state="unavailable",reason_code="terminology.name_index_not_saved",context=identity,
        terminology=info,query=query,searched=FALSE,concepts=list(),complete=TRUE,cursor=NULL,generation_requested=FALSE)
    },cancel,responseLimit=maxBytes)
  }
  list(lookupConcepts=lookup,searchConcepts=search)
}
