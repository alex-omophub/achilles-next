# Shared exact-byte guards. These establish page integrity, not release admission.
.v2_descriptor_check <- function(d) {
  .v2_keys(d,c("sha256","bytes","kind","rows"))
  .nv_need(!anyDuplicated(names(d)) && .string(d$sha256) && grepl("^[0-9a-f]{64}$",d$sha256),"Invalid object hash")
  .nv_need(.string(d$kind) && d$kind %in% c("root","index","data","metric_catalogue","concept_catalogue","terminology"),"Unknown page kind")
  for(n in c("bytes","rows")) .nv_need(.v2_count(d[[n]]) && nchar(d[[n]],type="bytes")<=512L,"Invalid descriptor count")
  .nv_need(.nv_unsigned_cmp(d$bytes,as.character(.v2_limit(d$kind)))<=0L,"Descriptor byte limit")
  invisible(d)
}
# Metric catalogue entries share a closed object layout and repeat values such
# as completeness and scope. Encode identical values once within this page.
.saved_catalogue_frames <- function(entries) {
  fields <- names(entries[[1L]])
  uniform <- length(entries)>1L && length(fields)>0L && length(fields)<=16L && !anyDuplicated(fields) &&
    all(vapply(entries,function(entry) identical(names(entry),fields),TRUE))
  if(!uniform) return(vapply(entries,.json,"",USE.NAMES=FALSE))

  frames <- rep("",length(entries))
  separator <- "{"
  for(field in sort(fields,method="radix")) {
    values <- lapply(entries,`[[`,field)
    first <- values[[1L]]
    same <- vapply(values,identical,TRUE,y=first,num.eq=FALSE)
    encoded <- rep(.json(first),length(values))
    if(any(!same)) encoded[!same] <- vapply(values[!same],.json,"",USE.NAMES=FALSE)
    frames <- paste0(frames,separator,.json(field),":",encoded)
    separator <- ","
  }
  paste0(frames,"}")
}

# Reuse each canonical entry for both its size check and the exact page comparison.
.saved_metric_catalogue_bytes <- function(doc) {
  .v2_keys(doc,c(.saved_common(),"kind","entries"))
  .nv_need(.nv_array(doc$entries) && length(doc$entries)>0L && length(doc$entries)<=2048L)
  entries <- .saved_catalogue_frames(doc$entries)
  .nv_need(all(nchar(enc2utf8(entries),type="bytes")+1L<=65536L),"Catalogue entry byte limit")
  array <- paste0("[",paste(entries,collapse=","),"]")
  fields <- vapply(sort(names(doc),method="radix"),function(key) {
    value <- if(key=="entries") array else .json(doc[[key]])
    paste0(.json(key),":",value)
  },"",USE.NAMES=FALSE)
  charToRaw(enc2utf8(paste0("{",paste(fields,collapse=","),"}\n")))
}
.v2_verified_bytes <- function(bytes,d,context=NULL,encodePage=.v2_bytes) {
  .v2_descriptor_check(d)
  .nv_need(is.raw(bytes) && length(bytes)<=.v2_limit(d$kind) && identical(as.character(length(bytes)),d$bytes) && .v2_hash(bytes)==d$sha256,"Page integrity mismatch")
  doc <- .nv_json(bytes)
  .nv_need(identical(bytes,encodePage(doc)) && identical(doc$kind,d$kind),"Noncanonical or wrong-kind page")
  if(!is.null(context)) .nv_need(identical(.json(doc[names(context)]),.json(context)),"Page context mismatch")
  doc
}
.v2_safe_file <- function(directory,path,limit) {
  target <- file.path(directory,path)
  .nv_need(utils::file_test("-f",target) && !nzchar(Sys.readlink(target)) && identical(normalizePath(target,mustWork=TRUE),target),"Unsafe artifact file")
  n <- file.info(target)$size
  .nv_need(!is.na(n) && n>=2L && n<=limit,"Artifact byte limit")
  bytes <- readBin(target,"raw",n=n+1L)
  .nv_need(length(bytes)==n,"Artifact changed during read");bytes
}
.saved_common <- function() c("contract_version","publication_id","release_id","source_id","profile_id","profile_revision","profile_sha256","access_scope_id")
.saved_page <- function(bytes,d,context,assets) {
  if(d$kind=="data") {
    .v2_descriptor_check(d)
    .nv_need(is.raw(bytes) && length(bytes)<=.v2_limit(d$kind),"Transport byte limit")
    leaf <- .v2_artifact_data_leaf(bytes,d,context,assets,check=function()NULL,retainFrames=FALSE)
    return(list(document=leaf$doc,lo=leaf$keys[[1]],hi=leaf$keys[[length(leaf$keys)]]))
  }
  catalogue <- d$kind=="metric_catalogue"
  encode <- if(catalogue) .saved_metric_catalogue_bytes else .v2_bytes
  doc <- .v2_verified_bytes(bytes,d,context,encode);common <- .saved_common()
  keys <- character()
  if(d$kind=="root") {
    .nv_need(.term_version(doc$contract_version))
    .v2_keys(doc,c(common,"kind","scope_kind","publication_state","eligible_for_current_pointer","expected_metric_count","generated_at","source_schema","source_consistency","disclosure","catalogue","concepts","data","terminology",if(doc$contract_version=="2.1.0")"saved_terminology"))
    if(doc$contract_version=="2.1.0").term_metadata(doc$saved_terminology)
    .nv_need(d$rows=="0" && identical(doc$publication_state,"ready") && isTRUE(doc$eligible_for_current_pointer) && .nv_date(doc$generated_at,TRUE))
    .nv_need(identical(doc$expected_metric_count,as.character(length(assets$metrics))))
    .v2_keys(doc$disclosure,c("approval_id","policy","policy_sha256"))
    .nv_need(.string(doc$disclosure$approval_id) && .string(doc$scope_kind) && .string(doc$disclosure$policy$scope_kind) && .string(doc$disclosure$policy_sha256))
    .v2_policy(doc$disclosure$policy,assets)
    .nv_need(doc$scope_kind==doc$disclosure$policy$scope_kind && doc$disclosure$policy_sha256==.v2_hash(.v2_bytes(doc$disclosure$policy)))
    .v2_keys(doc$source_schema,c("sha256","declared_cdm_version"))
    .nv_need(.string(doc$source_schema$sha256) && grepl("^[0-9a-f]{64}$",doc$source_schema$sha256) && .string(doc$source_schema$declared_cdm_version) && nchar(doc$source_schema$declared_cdm_version)<=256L)
    .nv_schema(doc$source_consistency,assets$metadata$`$defs`$consistency,assets$metadata)
    .nv_need(!doc$source_consistency$reusable)
    for(n in c("catalogue","concepts","data","terminology")) {
      .v2_descriptor_check(doc[[n]])
      kind <- c(catalogue="metric_catalogue",concepts="concept_catalogue",data="data",terminology="terminology")[[n]]
      .nv_need(doc[[n]]$kind%in%c("index",kind))
    }
  } else if(d$kind=="index") {
    .v2_keys(doc,c(common,"kind","index_kind","children"))
    .nv_need(.string(doc$index_kind) && doc$index_kind%in%c("data","metric_catalogue","concept_catalogue","terminology") && .nv_array(doc$children) && length(doc$children)<=128L)
    total <- "0";previous <- NULL
    for(child in doc$children) {
      .v2_keys(child,c("lower_key","upper_key","object"))
      for(n in c("lower_key","upper_key")) .nv_need(.saved_key(child[[n]],doc$contract_version),"Invalid index range")
      .nv_need(!.v2_less(child$upper_key,child$lower_key) && (is.null(previous)||.v2_less(previous,child$lower_key)),"Overlapping index coverage")
      .v2_descriptor_check(child$object)
      .nv_need(child$object$kind%in%c("index",doc$index_kind) && child$object$rows!="0")
      total <- .nv_add(total,child$object$rows);previous <- child$upper_key
    }
    .nv_need(total==d$rows,"Index row count mismatch")
    if(length(doc$children)) keys <- c(doc$children[[1]]$lower_key,previous)
  } else {
    .v2_keys(doc,c(common,"kind","entries"))
    .nv_need(.nv_array(doc$entries) && length(doc$entries)>0L && length(doc$entries)<=2048L)
    keys <- vapply(doc$entries,function(entry) {
      if(catalogue) {
        .nv_need(.string(entry$state) && .string(entry$conditional_support$state))
        .v2_dataset(entry,assets);return(entry$metric_id)
      }
      .nv_need(length(.v2_bytes(entry))<=65536L)
      .term_entry(entry,d$kind,doc$contract_version)
    },"")
  }
  if(!d$kind%in%c("root","index")) .nv_need(as.character(length(keys))==d$rows,"Leaf row count mismatch")
  if(!d$kind%in%c("root","index") && length(keys)>1L) for(i in seq_len(length(keys)-1L)) .nv_need(.v2_less(keys[[i]],keys[[i+1L]]),"Unordered page")
  list(document=doc,lo=if(length(keys))keys[[1]] else NULL,hi=if(length(keys))keys[[length(keys)]] else NULL)
}
.saved_key <- function(x,version="2.0.0") .string(x) && nchar(x,type="bytes")<=(if(identical(version,"2.1.0"))4096L else 2048L) && grepl("^[ -~]+$",x)
