# Semantic access to admitted immutable results; no generation or source queries.
.saved_range <- function(mid,filters,kind,assets) {
  schema <- assets$rows[[mid]]
  dims <- c(unlist(schema$dimensions),unlist(schema$extra_dimensions_by_row_kind[[kind]]))
  parts <- character()
  for(n in dims) {if(!n%in%names(filters))break;parts<-c(parts,.v2_component(filters[[n]],n))}
  if(length(parts)==length(dims)) {
    key <- paste0(mid,"|",paste(c(parts,paste0("E:",kind)),collapse="|"))
    return(list(lower=key,upper=key))
  }
  prefix <- paste0(mid,"|",if(length(parts))paste0(paste(parts,collapse="|"),"|") else "")
  list(lower=prefix,upper=paste0(prefix,"~"))
}
# Fit a verified prefix, including its evidence, cursor and final read counters.
.saved_fit_page <- function(items,complete,build,measure,maxBytes) {
  repeat {
    value <- build(items,complete)
    if(measure(value)<=maxBytes)return(value)
    if(length(items)<=1L).saved_error("resource_limit")
    items <- items[-length(items)];complete <- FALSE
  }
}
.saved_provider <- function(transport,readBudget=list()) {
  .nv_need(is.list(readBudget) && (!length(readBudget)||(.nv_object(readBudget)&&!anyDuplicated(names(readBudget))&&all(names(readBudget)%in%c("cacheBytes","maxObjects","maxBytes","maxRows")))),"Invalid read budget")
  reader <- do.call(.saved_reader,c(list(transport=transport),readBudget))
  assets <- .profile_context(transport$context)
  identity <- transport$context[c(.saved_common(),"authorization_epoch","instance_id")]
  bounded <- function(x,maximum)is.numeric(x)&&length(x)==1L&&!is.na(x)&&is.finite(x)&&x==floor(x)&&x>=1L&&x<=maximum
  input <- function(work)tryCatch(work(),error=function(e){if(inherits(e,"achillesnext_read_error"))stop(e);.saved_error("invalid_request")})
  # A catalogue entry is read under the same aggregate operation budget as rows.
  catalogue <- function(api,mid,memo) {
    if(!is.null(memo[[mid]])) return(memo[[mid]])
    result <- NULL
    api$walk("metric_catalogue",lower=mid,upper=mid,visit=function(doc) {
      for(entry in doc$entries)if(identical(entry$metric_id,mid)) {
        .nv_need(is.null(result),"Duplicate metric coverage");result<<-entry
      }
      TRUE
    })
    .nv_need(!is.null(result),"Missing metric catalogue entry")
    memo[[mid]] <- result;result
  }
  metrics <- function(limit=25L,cursor=NULL,maxBytes=1048576L,cancel=function()FALSE) {
    reader$session(function(api) {
      if(!bounded(limit,100L)||!bounded(maxBytes,8388608L)) .saved_error("invalid_request")
      selector <- .v2_hash(.v2_bytes(.object(operation="list_metrics",limit=limit,max_bytes=maxBytes)))
      after <- api$decode(cursor,selector);entries<-list();entryBytes<-0L
      build <- function(items,complete).object(state="available",reason_code=NULL,context=identity,metrics=items,
        complete=complete,cursor=if(complete)NULL else api$cursor(selector,items[[length(items)]]$metric_id),generation_requested=FALSE)
      headerBytes <- api$measure(build(list(),TRUE))
      done <- api$walk("metric_catalogue",after=after,visit=function(doc) {
        for(entry in doc$entries) {
          api$check()
          if(!is.null(after)&&!.v2_less(after,entry$metric_id))next
          if(length(entries)>=limit)return(FALSE)
          item<-c(entry,.object(capability=.saved_capability(entry$metric_id,assets)))
          entries[[length(entries)+1L]] <<- item
          entryBytes <<- entryBytes+length(.v2_bytes(item))
          if(headerBytes+entryBytes>maxBytes)return(FALSE)
        }
        TRUE
      })
      .saved_fit_page(entries,done$complete,build,api$measure,maxBytes)
    },cancel,responseLimit=maxBytes)
  }
  select <- function(metricId,filters=list(),rowKind=NULL,population=NULL,maxRows=100L,maxBytes=1048576L,cursor=NULL,cancel=function()FALSE) {
    reader$session(function(api) {
      if(!bounded(maxRows,1000L)||!bounded(maxBytes,8388608L)) .saved_error("invalid_request")
      if(is.list(filters)&&!length(filters)&&is.null(names(filters)))filters<-.object()
      capability <- input(function().saved_capability(metricId,assets))
      kind <- rowKind %||% if("summary"%in%unlist(capability$row_kinds))"summary" else capability$row_kinds[[1]]
      shape <- input(function().saved_selection(metricId,filters,kind,population,maxRows,maxBytes,check=api$check,assets=assets))
      selector <- .v2_hash(.v2_bytes(.object(operation="select_saved_rows",request=shape$request)))
      after <- api$decode(cursor,selector)
      catMemo <- new.env(parent=emptyenv());dataset <- catalogue(api,metricId,catMemo)
      response <- function(state,reason,rows=list(),dependencies=list(),nextCursor=NULL,complete=TRUE)
        .object(state=state,reason_code=reason,context=identity,dataset=dataset,capability=capability,
          selection=shape$request,rows=rows,dependencies=dependencies,cursor=nextCursor,complete=complete,
          generation_requested=FALSE,transformations="none")
      if(dataset$state%in%c("suppressed","unsupported"))return(response(dataset$state,dataset$reason_code))
      if(shape$state=="additional_batch_job_required")return(response(shape$state,shape$reason_code))
      checkRow <- function(entry,row) {
        .nv_need(!entry$state%in%c("suppressed","unsupported"),"Inaccessible dependency")
        if(entry$state%in%c("empty_source","empty_population")) .nv_need(row$state%in%c(entry$state,"suppressed"),"Dataset row state mismatch")
      }
      # Resolve only exact declared dependencies. Hashes are checked against keys
      # derived from installed definitions, never used as arbitrary object paths.
      allRows<-new.env(parent=emptyenv());queue<-list();links<-list();recordBytes<-list();parent<-NULL
      add <- function(mid,row) {
        id<-paste0(mid,"|",row$row_key)
        if(!exists(id,allRows,inherits=FALSE)) {
          if(length(queue)>=3000L).saved_error("resource_limit")
          record<-.object(metric_id=mid,metric_version=assets$metrics[[mid]]$version,row=row)
          assign(id,record,allRows);queue[[length(queue)+1L]]<<-record
          recordBytes[[id]]<<-length(.v2_bytes(record))
        }
        id
      }
      exact <- function(mid,dimensions,kind,expectedKey=NULL) {
        witness<-.object(dimensions=dimensions,row_kind=kind)
        rowKey<-.v2_row_identity(assets$rows[[mid]],witness)
        .nv_need(is.null(expectedKey)||identical(expectedKey,rowKey),"Wrong dependency identity")
        id<-paste0(mid,"|",rowKey)
        links[[parent]] <<- unique(c(links[[parent]],id))
        if(exists(id,allRows,inherits=FALSE))return(get(id,allRows,inherits=FALSE)$row)
        entry<-catalogue(api,mid,catMemo);target<-NULL
        .nv_need(!entry$state%in%c("suppressed","unsupported"),"Inaccessible dependency")
        key<-paste0(mid,"|",.v2_sort(assets$rows[[mid]],witness))
        api$walk("data",lower=key,upper=key,visit=function(doc) {
          .nv_need(identical(doc$metric_id,mid))
          for(row in doc$rows)if(identical(row$row_key,rowKey)) {
            .nv_need(is.null(target),"Duplicate dependency");target<<-row
          }
          TRUE
        })
        .nv_need(!is.null(target),"Missing dependency");checkRow(entry,target)
        add(mid,target);target
      }
      index<-1L
      expand <- function(candidate) {
        add(metricId,candidate)
        while(index<=length(queue)) {
          api$check();record<-queue[[index]];mid<-record$metric_id;row<-record$row
          parent <<- paste0(mid,"|",row$row_key)
          spec<-.analysis_denominator(mid,row,assets,forKey=TRUE)
          .v2_denominator_check(mid,row,function(id,key) {
            .nv_need(!is.null(spec)&&identical(id,spec$metric_id))
            target<-exact(id,spec$dimensions,"counts",key)
            refs<-Filter(function(r)identical(r$metric_id,id)&&identical(r$row_key,key),row$denominator_refs)
            for(ref in refs).nv_need(target$state!="suppressed"&&identical(target$values[[ref$field]],ref$value),"Dependency value mismatch")
            target$dimensions
          },assets)
          if(row$state!="suppressed" && row$row_kind=="summary") {
            dimensions<-c(row$dimensions,.object(eligibility_reason="eligible"))
            target<-exact(mid,dimensions,"eligibility_counts")
            .nv_need(target$state!="suppressed"&&identical(target$values$record_count %||% target$values$person_count,row$values$n),"Summary eligibility mismatch")
          }
          if(row$state!="suppressed" && row$row_kind=="eligibility_counts" && identical(row$dimensions$eligibility_reason,"eligible")) {
            dimensions<-row$dimensions;dimensions$eligibility_reason<-NULL
            target<-exact(mid,dimensions,"summary")
            .nv_need(target$state=="suppressed"||identical(target$values$n,row$values$record_count %||% row$values$person_count),"Eligibility summary mismatch")
          }
          index<<-index+1L
        }
      }
      build <- function(items,complete) {
        primary<-vapply(items,function(r)paste0(metricId,"|",r$row_key),"")
        reached<-primary;at<-1L
        while(at<=length(reached)) {
          api$check();reached<-unique(c(reached,links[[reached[[at]]]]));at<-at+1L
        }
        deps<-lapply(sort(setdiff(reached,primary),method="radix"),function(n)get(n,allRows,inherits=FALSE))
        last<-paste0(metricId,"|",.v2_sort(assets$rows[[metricId]],items[[length(items)]]))
        response("available",NULL,items,deps,if(complete)NULL else api$cursor(selector,last),complete)
      }
      headerBytes<-api$measure(response("available",NULL))
      bounds <- .saved_range(metricId,filters,kind,assets)
      rows <- list();primaryBytes<-0L
      done <- api$walk("data",lower=bounds$lower,upper=bounds$upper,after=after,visit=function(doc) {
        .nv_need(identical(doc$metric_id,metricId))
        for(row in doc$rows) {
          api$check();key<-paste0(metricId,"|",.v2_sort(assets$rows[[metricId]],row))
          if((!is.null(after)&&!.v2_less(after,key)) || !identical(row$row_kind,kind))next
          if(!all(vapply(names(filters),function(n)identical(.json(row$dimensions[[n]]),.json(filters[[n]])),TRUE)))next
          if(length(rows)>=maxRows)return(FALSE)
          checkRow(dataset,row);n<-length(.v2_bytes(row))
          if(primaryBytes+n>maxBytes) {
            if(!length(rows)).saved_error("resource_limit")
            return(FALSE)
          }
          rows[[length(rows)+1L]] <<- row;primaryBytes <<- primaryBytes+n
          expand(row)
          primary<-vapply(rows,function(r)paste0(metricId,"|",r$row_key),"")
          deps<-setdiff(ls(allRows,all.names=TRUE),primary)
          # A lower bound avoids repeatedly encoding a growing complete response.
          if(headerBytes+primaryBytes+sum(unlist(recordBytes[deps]))>maxBytes)return(FALSE)
        }
        TRUE
      })
      if(!length(rows))return(response("not_saved","selection.no_saved_rows"))
      .saved_fit_page(rows,done$complete,build,api$measure,maxBytes)
    },cancel,responseLimit=maxBytes)
  }
  c(list(listMetrics=metrics,selectSavedRows=select),
    .saved_concept_methods(reader,identity,bounded,input),list(close=reader$close,inspect=reader$inspect))
}
#' Open semantic access to an admitted artifact
#' @export
openArtifactResultProvider <- function(bundleDir,context,authorize,readBudget=list())
  .saved_provider(.saved_artifact_transport(bundleDir,context,authorize),readBudget)
#' Open semantic access through approved PostgreSQL serving views
#' @export
openDatabaseResultProvider <- function(connectionDetails,servingSchema,context,authorize,readBudget=list())
  .saved_provider(.saved_database_transport(connectionDetails,servingSchema,context,authorize),readBudget)
