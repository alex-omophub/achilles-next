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
.v2_directory <- function(directory, visit=function(descriptor,bytes)NULL,check=function()NULL,maxScratchBytes=1024^3,proof=NULL) {
  budget<-.v2_scratch_budget(maxScratchBytes)
  .nv_need(is.function(check));check()
  rootDir <- normalizePath(directory,mustWork=TRUE)
  .nv_need(dir.exists(rootDir) && !nzchar(Sys.readlink(directory)),"Artifact must be a directory")
  scratch <- tempfile("achilles-validate-")
  ownsScratch<-FALSE;rows<-NULL;concepts<-NULL
  on.exit(.v2_scratch_cleanup(list(function()if(!is.null(rows))rows$close(),
    function()if(!is.null(concepts))concepts$close(),
    function()if(ownsScratch){
      .v2_scratch_io(function().nv_need(unlink(scratch,recursive=TRUE)==0L&&!dir.exists(scratch)))
      live<-budget$inspect();budget$release(live$bytes,live$files)
    })))
  # Register cleanup before mkdir; claim only a successfully created directory
  # before allowing pending asynchronous interrupts to be delivered.
  suspendInterrupts({
    .v2_scratch_io(function().nv_need(dir.create(scratch,mode="0700")))
    ownsScratch<-TRUE;allowInterrupts(Sys.sleep(0))
  })
  .v2_scratch_io(function().nv_need(dir.create(file.path(scratch,"seen"),mode="0700")))
  if(is.null(proof)) {
    .v2_scratch_io(function().nv_need(dir.create(file.path(scratch,"groups"),mode="0700")))
    # Claim each new spool before allowing asynchronous interruption.
    suspendInterrupts({concepts<-.v2_spool(file.path(scratch,"concepts"),check,budget);allowInterrupts(Sys.sleep(0))})
  }
  termKey<-function(key).v2_hash(charToRaw(key))
  relations <- rootDocument <- NULL
  makeRelations <- function() .artifact_relations(rootDocument,context,assets,catalogue,rows,scratch,budget,check)
  inspectRow <- function(mid,row,frame,dimensions) {
    if(is.null(relations)) relations <<- makeRelations()
    relations$inspect(mid,row,frame,dimensions)
  }
  safe <- function(path,limit) {
    check();bytes<-.v2_safe_file(rootDir,path,limit);check();bytes
  }
  strict <- function(bytes) {
    doc <- .nv_json(bytes);.nv_need(identical(bytes,.v2_bytes(doc)),"Noncanonical page bytes");doc
  }
  pointer <- strict(safe("publication.json",262144L))
  .v2_keys(pointer,c("contract_version","publication_id","source_id","access_scope_id","root"))
  .nv_need(.term_version(pointer$contract_version))
  context <- NULL;assets <- NULL;catalogue <- list();counts <- list();sums <- list();last <- list()
  personPartitions <- c("core.person.gender_count","core.person.birth_year_count","core.person.race_count",
    "core.person.ethnicity_count","core.person.birth_year_gender_count","core.person.race_ethnicity_count",
    "core.density.domain_count","core.density.domain_presence_count")
  read <- function(d,expectedKind,depth=0L) {
    check()
    .v2_descriptor_check(d)
    mark <- file.path(scratch,"seen",d$sha256);.nv_need(!file.exists(mark),"Repeated page or cycle")
    .v2_scratch_file(mark,raw(),budget);raw <- safe(paste0("objects/",d$sha256,".json"),.v2_limit(d$kind))
    if(!is.null(proof)&&d$kind=="data"&&expectedKind=="data") {
      range <- proof$read(d,raw,context)
      mid <- range$metric_id;counts[[mid]] <<- .nv_add(counts[[mid]],d$rows)
      visit(d,raw);return(range)
    }
    dataLeaf <- d$kind=="data" && expectedKind=="data"
    if(dataLeaf) {
      leaf <- .v2_artifact_data_leaf(raw,d,context,assets,check)
      doc <- leaf$doc
    } else doc <- .v2_verified_bytes(raw,d)
    common <- c("contract_version","publication_id","release_id","source_id","profile_id","profile_revision","profile_sha256","access_scope_id")
    if(is.null(context)) {
      context <<- doc[common]
      .nv_need(identical(doc$contract_version,pointer$contract_version) && d$kind=="root","Unsupported root contract")
      .nv_need(doc$publication_id==pointer$publication_id && doc$source_id==pointer$source_id && doc$access_scope_id==pointer$access_scope_id)
      .store_uuid(doc$publication_id);.store_uuid(doc$release_id)
      assets <<- .profile_context(doc)
      counts <<- stats::setNames(rep(list("0"),length(assets$metrics)),names(assets$metrics));sums <<- counts
      if(!is.null(proof)) .nv_need(doc$contract_version=="2.0.0","Unexpected witnessed contract") else
      for(mid in names(assets$metrics)) .v2_scratch_io(function().nv_need(dir.create(file.path(scratch,"groups",mid),mode="0700")))
    }
    .nv_need(identical(.json(doc[common]),.json(context)) && doc$kind==d$kind,"Page context mismatch")
    visit(d,raw)
    if(d$kind=="root") {
      .nv_need(expectedKind=="root" && d$rows=="0")
      .v2_keys(doc,c(common,"kind","scope_kind","publication_state","eligible_for_current_pointer","expected_metric_count","generated_at","source_schema","source_consistency","disclosure","catalogue","concepts","data","terminology",if(doc$contract_version=="2.1.0")"saved_terminology"))
      if(doc$contract_version=="2.1.0").term_metadata(doc$saved_terminology)
      .nv_need(doc$publication_state=="ready" && isTRUE(doc$eligible_for_current_pointer) && .nv_date(doc$generated_at,TRUE))
      .nv_need(identical(doc$expected_metric_count,as.character(length(assets$metrics))),"Invalid expected metric count")
      .v2_keys(doc$disclosure,c("approval_id","policy","policy_sha256"));.nv_need(.string(doc$disclosure$approval_id))
      .v2_policy(doc$disclosure$policy,assets)
      .nv_need(doc$disclosure$policy_sha256==.v2_hash(.v2_bytes(doc$disclosure$policy)) && doc$scope_kind==doc$disclosure$policy$scope_kind)
      .v2_keys(doc$source_schema,c("sha256","declared_cdm_version"))
      .nv_need(.string(doc$source_schema$sha256) && grepl("^[0-9a-f]{64}$",doc$source_schema$sha256) && .string(doc$source_schema$declared_cdm_version) && nchar(doc$source_schema$declared_cdm_version)<=256L)
      schema <- assets$metadata;.nv_schema(doc$source_consistency,schema$`$defs`$consistency,schema)
      .nv_need(!doc$source_consistency$reusable,"No reusable source identity in this artifact contract")
      if(is.null(proof)) {
        .v2_descriptor_check(doc$data)
        suspendInterrupts({
          rows <<- .v2_validation_rows(file.path(scratch,"rows"),check,budget,doc$data$rows)
          allowInterrupts(Sys.sleep(0))
        })
      }
      rootDocument <<- doc
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
      mid <- doc$metric_id;keys <- leaf$keys
      .nv_need(is.null(last[[mid]])||.v2_less(last[[mid]],keys[[1L]]),"Duplicate row coverage")
      last[[mid]] <<- keys[[length(keys)]]
      counts[[mid]] <<- .nv_add(counts[[mid]],d$rows)
      sumPeople <- !isTRUE(assets$is_core) || mid=="core.person.count" || mid %in% personPartitions
      hashes <- character(length(keys));values <- vector("list",length(keys))
      for(i in seq_along(doc$rows)) {
        check()
        row <- doc$rows[[i]]
        if(sumPeople && !is.null(row$values$person_count)) sums[[mid]] <<- .nv_add(sums[[mid]],row$values$person_count)
        hashes[[i]] <- row$row_key
        values[[i]] <- inspectRow(mid,row,leaf$frames[[i]],leaf$dimensions[[i]])
        if(context$contract_version=="2.1.0")for(id in .term_row_ids(row)) {
          hash<-termKey(id);.nv_need(concepts$has(hash),"Missing retained concept metadata")
          concepts$flags(hash,1L)
        }
      }
      rows$putMany(hashes,values,duplicateMessage="Repeated row identity")
    } else {
      .v2_keys(doc,c(common,"kind","entries"));.nv_need(.nv_array(doc$entries)&&length(doc$entries)<=2048L)
      keys <- vapply(doc$entries,function(entry) {
        check()
        .nv_need(length(.v2_bytes(entry))<=65536L)
        if(d$kind=="metric_catalogue") {
          .v2_dataset(entry,assets);mid <- entry$metric_id;.nv_need(is.null(catalogue[[mid]]),"Duplicate metric")
          catalogue[[mid]] <<- entry;return(mid)
        }
        key<-.term_entry(entry,d$kind,doc$contract_version)
        if(context$contract_version=="2.1.0") {
          id<-.v2_component(entry$concept_tag,"concept_tag");hash<-termKey(id)
          if(d$kind=="concept_catalogue") {
            .nv_need(!concepts$has(hash),"Duplicate concept ID");concepts$put(hash,.v2_bytes(entry))
          } else {
            .nv_need(concepts$has(hash)&&identical(concepts$get(hash),.v2_bytes(entry)),"Name index/ID label mismatch")
            .nv_need(concepts$flags(hash,2L),"Duplicate name-index ID")
          }
        }
        key
      },"")
    }
    .nv_need(length(keys)>0L && as.character(length(keys))==d$rows,"Leaf row count mismatch")
    if(!dataLeaf && length(keys)>1L) for(i in seq_len(length(keys)-1L)) .nv_need(.v2_less(keys[[i]],keys[[i+1L]]),"Unordered leaf")
    list(lo=keys[[1]],hi=keys[[length(keys)]])
  }
  root <- read(pointer$root,"root")
  if(context$contract_version=="2.1.0")concepts$walk(function(key,raw) {
    check()
    flags<-concepts$flags(key)
    .nv_need(bitwAnd(flags,1L)!=0L,"Concept metadata outside retained scope")
    entry<-.nv_json(raw)
    .nv_need(identical(bitwAnd(flags,2L)!=0L,entry$label_state=="available"),"Missing or extra name-index entry")
  })
  .nv_need(setequal(names(catalogue),names(assets$metrics)),"Incomplete catalogue")
  allowed <- .v2_policy(root$disclosure$policy,assets)
  for(mid in names(catalogue)) {
    check()
    d <- catalogue[[mid]];.nv_need(d$rows==counts[[mid]],"Missing data coverage")
    if(mid%in%assets$singletons && d$state!="suppressed") .nv_need(d$rows=="1","Missing projected singleton")
    if(mid=="core.execution.output_status" && d$state!="suppressed") .nv_need(d$rows=="142","Incomplete output ledger coverage")
    if(!mid %in% allowed) .nv_need(d$state=="suppressed" && d$rows=="0","Policy output leak")
  }
  inventory <- function() {
    .v2_directory_entries(rootDir,function(name){check();.nv_need(name%in%c("objects","publication.json"),"Undeclared artifact file")})
    .nv_need(!nzchar(Sys.readlink(file.path(rootDir,"objects"))),"Symlinked object directory")
    .v2_directory_entries(file.path(rootDir,"objects"),function(name) {
      check()
      .nv_need(grepl("^[0-9a-f]{64}[.]json$",name) && file.exists(file.path(scratch,"seen",sub("[.]json$","",name))),"Undeclared artifact object")
    })
  }
  if(!is.null(proof)) {
    proof$finish(root,catalogue);inventory();check()
    return(invisible(root))
  }
  if(is.null(relations)) relations <- makeRelations()
  result <- relations$finish()
  capabilities <- result$capabilities;ledger <- result$ledger
  suppressed <- result$suppressed;captureTotals <- result$captureTotals
  if(isTRUE(assets$is_core)) {
    .v2_ledger_check(catalogue,ledger)
    .v2_capability_check(catalogue,capabilities,requireEvidence=FALSE)
  } else .profile_artifact_checks(catalogue,sums,assets)
  available <- function(mid)!is.null(catalogue[[mid]]) && !catalogue[[mid]]$state%in%c("suppressed","unsupported") && !isTRUE(suppressed[[mid]])
  # Capture totals count records, whose typed concept buckets are disjoint.
  # Do not add person counts or reconcile totals against suppressed evidence.
  for(mid in names(captureTotals)) if(available(mid) && !is.null(captureTotals[[mid]]$all))
    .nv_need(identical(captureTotals[[mid]]$all,captureTotals[[mid]]$parts),"Projected all-concepts record total does not reconcile")
  if(available("core.person.count")) for(mid in personPartitions) {
    if(available(mid)) .nv_need(sums[[mid]]==sums[["core.person.count"]],"Projected PERSON partition does not reconcile")
  }
  relations$reconcile(available)
  inventory()
  check();invisible(root)
}
# Only for a graph that completed .v2_directory in this publication attempt.
# The approved root digest binds every descendant descriptor. Verify the exact
# bytes again when sending them to the store, parsing only branching pages.
.publication_pages <- function(directory, root, pointer, visit, check) {
  check()
  path <- normalizePath(directory, mustWork = TRUE)
  .nv_need(!nzchar(Sys.readlink(directory)) && !nzchar(Sys.readlink(file.path(path, "objects"))),
    "Unsafe publication directory")
  checkPointer <- function() .nv_need(identical(.v2_safe_file(path, "publication.json", 262144L), pointer),
    "Publication pointer changed after admission")
  checkPointer()
  pages <- 0
  walk <- function(descriptor) {
    check()
    .v2_descriptor_check(descriptor)
    bytes <- .v2_safe_file(path, paste0("objects/",descriptor$sha256,".json"), as.integer(descriptor$bytes))
    .nv_need(identical(as.character(length(bytes)),descriptor$bytes) &&
      identical(.v2_hash(bytes),descriptor$sha256), "Publication object changed after admission")
    pages <<- pages + 1
    visit(descriptor, bytes)
    if (descriptor$kind == "root") {
      doc <- .nv_json(bytes)
      for (child in doc[c("catalogue","concepts","data","terminology")]) walk(child)
    } else if (descriptor$kind == "index") {
      doc <- .nv_json(bytes)
      for (child in doc$children) walk(child$object)
    }
    invisible(NULL)
  }
  walk(root)
  # Admission proved uniqueness and reachability. Every expected filename was
  # just read by its digest, so any additional entry increases the inventory.
  entries <- 0
  .v2_directory_entries(path,function(name) {
    check(); .nv_need(name %in% c("publication.json","objects"), "Undeclared artifact file")
  })
  .v2_directory_entries(file.path(path,"objects"),function(name) {
    check(); entries <<- entries + 1
    .nv_need(entries <= pages && grepl("^[0-9a-f]{64}[.]json$",name), "Undeclared artifact object")
  })
  .nv_need(entries == pages, "Publication object inventory changed")
  checkPointer(); check()
  invisible(NULL)
}
#' Validate an exact-byte approved artifact without Node
#' @param bundleDir Directory containing publication.json and objects.
#' @param maxScratchBytes Maximum total logical bytes of validation scratch files.
#' @param cancel Boolean cooperative cancellation predicate.
#' @export
validateResultArtifact <- function(bundleDir,maxScratchBytes=1024^3,cancel=function()FALSE) {
  .v2_scratch_limit(maxScratchBytes);.term_check(cancel)
  tryCatch({.v2_directory(bundleDir,check=function().term_check(cancel),maxScratchBytes=maxScratchBytes);invisible(TRUE)},error=function(e) {
    if(inherits(e,"achillesnext_scratch_error")||inherits(e,"achillesnext_read_error"))stop(e)
    stop("Result artifact validation failed",call.=FALSE)
  })
}
