# Saved terminology only: version 2.0.0 has no names; opt-in 2.1.0 has a
# separately ordered approved name index. Neither path queries vocabulary SQL.
.saved_concept_methods <- function(reader,identity,bounded,input) {
  unavailable <- .object(state="unavailable",reason_code="terminology.labels_not_saved",
    matching="unavailable",
    label_source=.object(state="unavailable",reason_code="terminology.label_source_not_saved"),
    vocabulary_release=.object(state="unavailable",reason_code="terminology.vocabulary_release_not_saved"))
  info<-function(api) {
    root<-api$root()
    if(root$contract_version=="2.0.0")unavailable else c(.object(state="available",reason_code=NULL),root$saved_terminology)
  }
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
      metadata<-info(api) # Check authority even when the concept tree is empty.
      entries <- list();complete<-TRUE;entryBytes<-0L
      build <- function(items,complete).object(state="available",reason_code=NULL,context=identity,
        terminology=metadata,concepts=items,complete=complete,
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
      metadata<-info(api) # Even unavailable search enforces the live DB view.
      if(metadata$state=="unavailable") {
        if(!is.null(cursor)).saved_error("invalid_cursor")
        return(.object(state="unavailable",reason_code="terminology.name_index_not_saved",context=identity,
          terminology=metadata,query=query,searched=FALSE,concepts=list(),complete=TRUE,cursor=NULL,generation_requested=FALSE))
      }
      normalized<-.term_normalize(query)
      selector<-.v2_hash(.v2_bytes(.object(operation="search_concepts",query=normalized,
        matching=metadata$matching,limit=limit,max_bytes=maxBytes)))
      after<-api$decode(cursor,selector);lower<-.term_prefix(normalized);upper<-paste0(lower,"~")
      entries<-list();entryBytes<-0L
      build<-function(items,complete).object(state="available",reason_code=NULL,context=identity,
        terminology=metadata,query=query,normalized_query=normalized,searched=TRUE,concepts=items,
        complete=complete,cursor=if(complete)NULL else api$cursor(selector,.term_name_key(items[[length(items)]])),generation_requested=FALSE)
      headerBytes<-api$measure(build(list(),TRUE))
      done<-api$walk("terminology",lower=lower,upper=upper,after=after,visit=function(doc) {
        for(entry in doc$entries) {
          api$check();key<-.term_name_key(entry)
          if(.v2_less(key,lower)||.v2_less(upper,key)||(!is.null(after)&&!.v2_less(after,key)))next
          if(length(entries)>=limit)return(FALSE)
          .nv_need(startsWith(.term_normalize(entry$label),normalized),"Name range mismatch")
          id<-.v2_component(entry$concept_tag,"concept_tag");found<-NULL
          api$walk("concept_catalogue",lower=id,upper=id,visit=function(page) {
            for(candidate in page$entries) {
              api$check()
              if(identical(.v2_component(candidate$concept_tag,"concept_tag"),id)) {
                .nv_need(is.null(found),"Duplicate concept ID");found<<-candidate
              }
            }
            TRUE
          })
          .nv_need(!is.null(found)&&identical(.v2_bytes(found),.v2_bytes(entry)),"Name index/ID label mismatch")
          entries[[length(entries)+1L]]<<-entry;entryBytes<<-entryBytes+length(.v2_bytes(entry))
          if(headerBytes+entryBytes>maxBytes)return(FALSE)
        }
        TRUE
      })
      .saved_fit_page(entries,done$complete,build,api$measure,maxBytes)
    },cancel,responseLimit=maxBytes)
  }
  list(lookupConcepts=lookup,searchConcepts=search)
}
