# Streaming directory iteration avoids allocating a complete million-file list.
.v2_directory_entries <- function(directory, visit) {
  rJava::.jinit()
  path <- rJava::.jcall("java/nio/file/Paths","Ljava/nio/file/Path;","get",directory,rJava::.jarray(character()))
  stream <- rJava::.jcall("java/nio/file/Files","Ljava/nio/file/DirectoryStream;","newDirectoryStream",path)
  on.exit(rJava::.jcall(stream,"V","close"))
  iterator <- rJava::.jcall(stream,"Ljava/util/Iterator;","iterator")
  while(rJava::.jcall(iterator,"Z","hasNext")) {
    value <- rJava::.jcall(iterator,"Ljava/lang/Object;","next")
    visit(basename(rJava::.jcall(value,"S","toString")))
  }
  invisible(NULL)
}
.v2_directory <- function(directory, visit=function(descriptor,bytes)NULL) {
  rootDir <- normalizePath(directory,mustWork=TRUE)
  .nv_need(dir.exists(rootDir) && !nzchar(Sys.readlink(directory)),"Artifact must be a directory")
  scratch <- tempfile("achilles-validate-");.nv_need(dir.create(scratch,mode="0700"));on.exit(unlink(scratch,recursive=TRUE))
  dir.create(file.path(scratch,"seen"),mode="0700");dir.create(file.path(scratch,"rows"),mode="0700")
  dir.create(file.path(scratch,"groups"),mode="0700")
  for(mid in names(.v2_assets()$metrics)) dir.create(file.path(scratch,"groups",mid),mode="0700")
  suppressed <- list()
  groupPath <- function(mid,key)file.path(scratch,"groups",mid,.v2_hash(.v2_bytes(key)))
  accumulate <- function(mid,key,value) {
    path <- groupPath(mid,key);old <- if(file.exists(path))readLines(path,warn=FALSE) else "0"
    writeLines(.nv_add(old,value),path)
  }
  safe <- function(path,limit) {
    target <- file.path(rootDir,path)
    .nv_need(utils::file_test("-f",target) && !nzchar(Sys.readlink(target)) && identical(normalizePath(target,mustWork=TRUE),target),"Unsafe artifact file")
    n <- file.info(target)$size;.nv_need(!is.na(n) && n>=2 && n<=limit,"Artifact byte limit")
    raw <- readBin(target,"raw",n=n+1);.nv_need(length(raw)==n,"Artifact changed during read");raw
  }
  strict <- function(bytes) {
    doc <- .nv_json(bytes);.nv_need(identical(bytes,.v2_bytes(doc)),"Noncanonical page bytes");doc
  }
  pointer <- strict(safe("publication.json",262144L))
  .v2_keys(pointer,c("contract_version","publication_id","source_id","access_scope_id","root"))
  .nv_need(pointer$contract_version=="2.0.0")
  context <- NULL;catalogue <- list();counts <- stats::setNames(rep(list("0"),142),names(.v2_assets()$metrics))
  sums <- stats::setNames(rep(list("0"),142),names(.v2_assets()$metrics));last <- list()
  spool <- function(hash) file.path(scratch,"rows",hash)
  read <- function(d,expectedKind,depth=0L) {
    .v2_keys(d,c("sha256","bytes","kind","rows"))
    .nv_need(.string(d$sha256) && grepl("^[0-9a-f]{64}$",d$sha256) && .v2_count(d$bytes) && .v2_count(d$rows))
    .nv_need(d$kind %in% c("root","index","metric_catalogue","concept_catalogue","terminology","data"))
    .nv_need(.nv_unsigned_cmp(d$bytes,as.character(.v2_limit(d$kind)))<=0L,"Descriptor byte limit")
    mark <- file.path(scratch,"seen",d$sha256);.nv_need(!file.exists(mark),"Repeated page or cycle")
    .nv_need(file.create(mark));raw <- safe(paste0("objects/",d$sha256,".json"),.v2_limit(d$kind))
    .nv_need(as.character(length(raw))==d$bytes && .v2_hash(raw)==d$sha256,"Page integrity mismatch")
    doc <- strict(raw)
    common <- c("contract_version","publication_id","release_id","source_id","profile_id","profile_revision","profile_sha256","access_scope_id")
    if(is.null(context)) {
      context <<- doc[common]
      .nv_need(identical(doc$contract_version,"2.0.0") && d$kind=="root","Unsupported root contract")
      .nv_need(doc$publication_id==pointer$publication_id && doc$source_id==pointer$source_id && doc$access_scope_id==pointer$access_scope_id)
      .store_uuid(doc$publication_id);.store_uuid(doc$release_id)
      a <- .v2_assets();.nv_need(doc$profile_id==a$profile$profile_id && doc$profile_revision==a$profile$revision && doc$profile_sha256==a$hash)
    }
    .nv_need(identical(.json(doc[common]),.json(context)) && doc$kind==d$kind,"Page context mismatch")
    visit(d,raw)
    if(d$kind=="root") {
      .nv_need(expectedKind=="root" && d$rows=="0")
      .v2_keys(doc,c(common,"kind","scope_kind","publication_state","eligible_for_current_pointer","expected_metric_count","generated_at","source_consistency","disclosure","catalogue","concepts","data","terminology"))
      .nv_need(doc$publication_state=="ready" && isTRUE(doc$eligible_for_current_pointer) && doc$expected_metric_count=="142" && .nv_date(doc$generated_at,TRUE))
      .v2_keys(doc$disclosure,c("approval_id","policy","policy_sha256"));.nv_need(.string(doc$disclosure$approval_id))
      .v2_policy(doc$disclosure$policy)
      .nv_need(doc$disclosure$policy_sha256==.v2_hash(.v2_bytes(doc$disclosure$policy)) && doc$scope_kind==doc$disclosure$policy$scope_kind)
      schema <- .v2_assets()$metadata;.nv_schema(doc$source_consistency,schema$`$defs`$consistency,schema)
      .nv_need(!doc$source_consistency$reusable,"No reusable source identity in this artifact contract")
      read(doc$catalogue,"metric_catalogue");read(doc$concepts,"concept_catalogue");read(doc$data,"data");read(doc$terminology,"terminology")
      return(doc)
    }
    if(d$kind=="index") {
      .v2_keys(doc,c(common,"kind","index_kind","children"))
      .nv_need(doc$index_kind==expectedKind && .nv_array(doc$children) && length(doc$children)<=128L && depth<8L,"Index resource limit")
      rows <- "0";lo <- NULL;hi <- NULL
      for(child in doc$children) {
        .v2_keys(child,c("lower_key","upper_key","object"));.nv_need(.string(child$lower_key) && .string(child$upper_key))
        .nv_need(is.null(hi)||.v2_less(hi,child$lower_key),"Overlapping index coverage")
        range <- read(child$object,expectedKind,depth+1L)
        .nv_need(identical(range$lo,child$lower_key)&&identical(range$hi,child$upper_key),"Index range mismatch")
        if(is.null(lo)) lo <- range$lo
        hi <- range$hi;rows <- .nv_add(rows,child$object$rows)
      }
      .nv_need(rows==d$rows,"Index row count mismatch");return(list(lo=lo,hi=hi))
    }
    .nv_need(d$kind==expectedKind,"Wrong page kind")
    if(d$kind=="data") {
      .v2_keys(doc,c(common,"kind","metric_id","metric_version","rows"))
      mid <- doc$metric_id;m <- .v2_assets()$metrics[[mid]]
      .nv_need(!is.null(m)&&doc$metric_version==m$version&&.nv_array(doc$rows)&&length(doc$rows)<=2048L)
      keys <- character()
      for(row in doc$rows) {
        key <- paste0(mid,"|",.v2_row(mid,row));.nv_need(is.null(last[[mid]])||.v2_less(last[[mid]],key),"Duplicate row coverage")
        last[[mid]] <<- key;keys <- c(keys,key)
        counts[[mid]] <<- .nv_add(counts[[mid]],"1")
        if(!is.null(row$values$person_count)) sums[[mid]] <<- .nv_add(sums[[mid]],row$values$person_count)
        path <- spool(row$row_key);.nv_need(!file.exists(path),"Repeated row identity")
        writeBin(.v2_bytes(c(.object(metric_id=mid),row)),path)
      }
    } else {
      .v2_keys(doc,c(common,"kind","entries"));.nv_need(.nv_array(doc$entries)&&length(doc$entries)<=2048L)
      keys <- vapply(doc$entries,function(entry) {
        .nv_need(length(.v2_bytes(entry))<=65536L)
        if(d$kind=="metric_catalogue") {
          .v2_dataset(entry);mid <- entry$metric_id;.nv_need(is.null(catalogue[[mid]]),"Duplicate metric")
          catalogue[[mid]] <<- entry;return(mid)
        }
        .v2_keys(entry,c("concept_tag","label","label_state",if(d$kind=="terminology")"domain_id"))
        .v2_component(entry$concept_tag,"concept_tag")
        .nv_need(entry$label_state=="unavailable" && is.null(entry$label),"Unapproved terminology fields")
        if(d$kind=="terminology") .nv_need(is.null(entry$domain_id))
        .v2_component(entry$concept_tag,"concept_tag")
      },"")
    }
    .nv_need(length(keys)>0L && as.character(length(keys))==d$rows,"Leaf row count mismatch")
    if(length(keys)>1L) for(i in seq_len(length(keys)-1L)) .nv_need(.v2_less(keys[[i]],keys[[i+1L]]),"Unordered leaf")
    list(lo=keys[[1]],hi=keys[[length(keys)]])
  }
  root <- read(pointer$root,"root")
  capabilities <- list()
  .nv_need(setequal(names(catalogue),names(.v2_assets()$metrics)),"Incomplete catalogue")
  allowed <- .v2_policy(root$disclosure$policy)
  for(mid in names(catalogue)) {
    d <- catalogue[[mid]];.nv_need(d$rows==counts[[mid]],"Missing data coverage")
    if(!mid %in% allowed) .nv_need(d$state=="suppressed" && d$rows=="0","Policy output leak")
  }
  # Disk-spooled second pass validates references without an in-memory row map.
  .v2_directory_entries(file.path(scratch,"rows"),function(name) {
    row <- .nv_json(readBin(spool(name),"raw",n=131073L));mid <- row$metric_id;row$metric_id <- NULL
    for(ref in row$denominator_refs) {
      .nv_need(file.exists(spool(ref$row_key)),"Missing projected denominator")
      target <- .nv_json(readBin(spool(ref$row_key),"raw",n=131073L))
      .nv_need(target$metric_id==ref$metric_id && target$state!="suppressed" && identical(target$values[[ref$field]],ref$value),"Invalid projected denominator")
      .v2_denominator_check(mid,row,function(id,key) {
        .nv_need(id==target$metric_id&&key==target$row_key);target$dimensions
      })
    }
    if(!length(row$denominator_refs)) .v2_denominator_check(mid,row,function(...)NULL)
    d <- catalogue[[mid]]
    if(mid=="core.source.capabilities" && row$state!="suppressed") capabilities[[row$dimensions$probe_id]] <<- row$values
    if(mid=="core.execution.output_status" && row$state!="suppressed") {
      target <- catalogue[[row$dimensions$metric_id]]
      .nv_need(row$values$state==target$state && identical(row$values$reason_code,target$reason_code) && identical(row$values$required,target$required),"Projected ledger mismatch")
    }
    if(row$state=="suppressed") suppressed[[mid]] <<- TRUE
    if(!is.null(row$values$record_count) && "concept_tag"%in%names(row$dimensions) &&
      (!grepl(".capture_count",mid,fixed=TRUE)||row$dimensions$period_kind=="full_scope")) accumulate(mid,row$dimensions$concept_tag,row$values$record_count)
    if(row$row_kind=="summary" && row$state!="suppressed") {
      eligible <- row;eligible$row_kind <- "eligibility_counts";eligible$dimensions <- c(row$dimensions,.object(eligibility_reason="eligible"))
      key <- .v2_row_identity(.v2_assets()$rows[[mid]],eligible)
      .nv_need(file.exists(spool(key)),"Missing projected eligibility count")
      value <- .nv_json(readBin(spool(key),"raw",n=131073L))
      .nv_need(value$state!="suppressed" && identical(value$values$record_count %||% value$values$person_count,row$values$n),"Projected summary n does not reconcile")
    }
    if(d$state=="suppressed") .nv_need(row$state=="suppressed")
    if(d$state%in%c("empty_source","empty_population")) .nv_need(row$state%in%c(d$state,"suppressed"))
  })
  .v2_capability_check(catalogue,capabilities)
  available <- function(mid)!is.null(catalogue[[mid]]) && !catalogue[[mid]]$state%in%c("suppressed","unsupported") && !isTRUE(suppressed[[mid]])
  if(available("core.person.count")) for(mid in c("core.person.gender_count","core.person.birth_year_count","core.person.race_count","core.person.ethnicity_count","core.person.birth_year_gender_count","core.person.race_ethnicity_count","core.density.domain_count","core.density.domain_presence_count")) {
    if(available(mid)) .nv_need(sums[[mid]]==sums[["core.person.count"]],"Projected PERSON partition does not reconcile")
  }
  for(domain in c("condition","drug","procedure","visit","device","observation","death","specimen","measurement")) {
    cap <- paste0("core.",domain,".capture_count");if(!available(cap)) next
    for(suffix in c("source_count","type_count","representation_count","unit_count","coded_value_count","operator_count","numeric_eligibility_count","observation_qualification_count","range_status_count","status_type_count")) {
      mid <- paste0("core.",domain,".",suffix);if(!available(mid)) next
      for(pair in list(c(mid,cap),c(cap,mid))) .v2_directory_entries(file.path(scratch,"groups",pair[[1]]),function(key) {
        a <- file.path(scratch,"groups",pair[[1]],key);b <- file.path(scratch,"groups",pair[[2]],key)
        .nv_need(file.exists(b)&&identical(readLines(a,warn=FALSE),readLines(b,warn=FALSE)),"Projected record partition does not reconcile")
      })
    }
  }
  .v2_directory_entries(rootDir,function(name) .nv_need(name%in%c("objects","publication.json"),"Undeclared artifact file"))
  .nv_need(!nzchar(Sys.readlink(file.path(rootDir,"objects"))),"Symlinked object directory")
  .v2_directory_entries(file.path(rootDir,"objects"),function(name) {
    .nv_need(grepl("^[0-9a-f]{64}[.]json$",name) && file.exists(file.path(scratch,"seen",sub("[.]json$","",name))),"Undeclared artifact object")
  })
  invisible(root)
}
#' Validate an exact-byte approved artifact without Node
#' @param bundleDir Directory containing publication.json and objects.
#' @export
validateResultArtifact <- function(bundleDir) {
  tryCatch({.v2_directory(bundleDir);invisible(TRUE)},error=function(e) stop("Result artifact validation failed",call.=FALSE))
}
