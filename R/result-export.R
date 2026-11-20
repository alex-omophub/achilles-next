# Approval pages are built once. Both transports retain these exact bytes.
.v2_descriptor <- function(bytes, kind, rows) .object(sha256=.v2_hash(bytes),bytes=as.character(length(bytes)),kind=kind,rows=rows)
.v2_limit <- function(kind) switch(kind,root=262144L,index=262144L,data=4194304L,1048576L)
.v2_tree <- function(kind, context, emit) {
  fanout<-if(identical(context$contract_version,"2.1.0")&&kind=="terminology")32L else 128L
  levels <- list(); total <- "0"
  node <- function(children) {
    d <- emit(c(context,.object(kind="index",index_kind=kind,children=children)),"index",.nv_sum(vapply(children,function(c)c$object$rows,"")))
    .object(lower_key=children[[1]]$lower_key,upper_key=children[[length(children)]]$upper_key,object=d)
  }
  add <- function(item, level=1L) {
    .nv_need(level <= 8L,"Index depth limit")
    while(length(levels)<level) levels[[length(levels)+1L]] <<- list()
    bucket <- levels[[level]]
    if(length(bucket)) .nv_need(.v2_less(bucket[[length(bucket)]]$upper_key,item$lower_key),"Overlapping page ranges")
    .nv_need(length(bucket)<fanout,"Index depth limit")
    bucket[[length(bucket)+1L]] <- item
    if(length(bucket)==fanout && level<8L) {levels[[level]] <<- list();add(node(bucket),level+1L)} else levels[[level]] <<- bucket
  }
  finish <- function() {
    if(!length(levels)) return(emit(c(context,.object(kind="index",index_kind=kind,children=list())),"index","0"))
    level <- 1L
    repeat {
      bucket <- levels[[level]]; higher <- level<length(levels) && any(vapply(levels[seq.int(level+1L,length(levels))],length,1L)>0L)
      if(length(bucket)) {
        if(!higher) return(if(length(bucket)==1L) bucket[[1]]$object else node(bucket)$object)
        levels[[level]] <<- list();add(node(bucket),level+1L)
      }
      level <- level+1L; .nv_need(level<=length(levels),"Invalid index frontier")
    }
  }
  list(add=function(desc,lo,hi)add(.object(lower_key=lo,upper_key=hi,object=desc)),finish=finish)
}
# Split a canonical empty data envelope so already validated row frames can be
# inserted without encoding those rows again. Offsets are UTF-8 byte offsets.
.v2_data_envelope <- function(context,metricId,version) {
  envelope <- .v2_bytes(c(context,.object(kind="data",metric_id=metricId,metric_version=version,rows=list())))
  marker <- regexpr('"rows":[]',rawToChar(envelope),fixed=TRUE,useBytes=TRUE)[1L]
  .nv_need(marker>0L,"Missing data rows envelope")
  start <- marker+7L
  list(prefix=envelope[seq_len(start)],suffix=envelope[seq.int(start+1L,length(envelope))])
}
.v2_pages <- function(kind, context, emit, metricId=NULL,assets=.v2_assets()) {
  tree <- .v2_tree(kind,context,emit); rows <- list(); bytes <- 0L
  first <- last <- NULL
  data <- kind=="data"
  if(data) envelope <- .v2_data_envelope(context,metricId,assets$metrics[[metricId]]$version)
  flush <- function() {
    if(!length(rows)) return(invisible(NULL))
    if(data) {
      content <- do.call(c,rows)
      length(content) <- length(content)-1L # omit the last separator
      value <- c(envelope$prefix,content,envelope$suffix)
    } else value <- c(context,.object(kind=kind,entries=rows))
    d <- emit(value,kind,as.character(length(rows)));tree$add(d,first,last)
    rows <<- list();bytes <<- 0L
  }
  add <- function(row,key) {
    if(data) {
      n <- length(row)
      .nv_need(is.raw(row)&&n>1L&&n<=65536L&&row[[n]]==as.raw(10L),"Invalid canonical row frame")
      row[[n]] <- as.raw(44L)
    } else {
      n <- length(.v2_bytes(row));.nv_need(n<=65536L,"Row resource limit")
    }
    # Count the original frame bytes to retain the existing page boundaries.
    if(length(rows) && (length(rows)>=2048L || bytes+n+8192L>.v2_limit(kind))) flush()
    if(!length(rows)) first <<- key
    last <<- key;rows[[length(rows)+1L]] <<- row;bytes <<- bytes+n
  }
  list(add=add,finish=function(){flush();tree$finish()})
}
.v2_policy <- function(policy,assets=.v2_assets()) {
  .v2_keys(policy,c("id","revision","scope_kind","allow_metrics"))
  .nv_need(.string(policy$id) && grepl("^[a-z0-9_.:-]{1,96}$",policy$id) && .string(policy$revision) && nchar(policy$revision)<=96L)
  .nv_need(policy$scope_kind %in% c("restricted","distributable"))
  .nv_need(.nv_array(policy$allow_metrics) && all(vapply(policy$allow_metrics,.string,TRUE)) && !anyDuplicated(unlist(policy$allow_metrics)))
  allow <- unlist(policy$allow_metrics);.nv_need(all(allow %in% names(assets$metrics)))
  # A policy omitting a denominator omits dependent outputs as well. Values are
  # physically absent, never hidden only by the renderer.
  repeat {
    nextAllow <- Filter(function(mid) {
      d <- .analysis_dependency(mid,assets)
      is.null(d) || d %in% allow
    },allow)
    if(setequal(nextAllow,allow)) break
    allow <- nextAllow
  }
  # Source output-status metadata describes the entire source inventory. A
  # partial projection uses its own catalogue and omits that source ledger.
  if(length(allow)<length(assets$metrics)) allow <- setdiff(allow,"core.execution.output_status")
  allow
}
# All publication SQL and streamed validation/producer rows share cancellation.
# This also covers existing validators without weakening their predicates.
.publication_tx <- function(tx,cancel) {
  check<-function().term_check(cancel)
  execute<-tx$execute;one<-tx$one;stream<-tx$stream
  tx$execute<-function(sql){check();value<-execute(sql);check();value}
  tx$one<-function(sql){check();value<-one(sql);check();value}
  tx$stream<-function(sql,visit){check();value<-stream(sql,function(text){check();visit(text);check()});check();value}
  tx
}
.store_build_pages <- function(tx, validated, publicationId, scopeId, approvalId, policy, directory,savedTerminology=NULL,cancel=function()FALSE,maxExportBytes=1024^3,maxSnapshotBytes=1024^3,proof=NULL) {
  .term_check(cancel)
  writer<-.export_writer(maxExportBytes,function().term_check(cancel))
  assets <- validated$assets %||% .v2_assets();allow <- .v2_policy(policy,assets);c <- validated$context
  metadata<-if(is.null(savedTerminology))NULL else .term_load(tx,savedTerminology,c,cancel,maxSnapshotBytes=maxSnapshotBytes)
  version<-if(is.null(metadata))"2.0.0" else "2.1.0"
  context <- .object(contract_version=version,publication_id=publicationId,release_id=c$release_id,source_id=c$source_id,
    profile_id=c$profile_id,profile_revision=c$profile_revision,profile_sha256=c$profile_sha256,access_scope_id=scopeId)
  emit <- function(doc,kind,rows) {
    .term_check(cancel)
    raw <- if(is.raw(doc))doc else .v2_bytes(doc)
    .nv_need(length(raw)<=.v2_limit(kind),"Page resource limit")
    d <- .v2_descriptor(raw,kind,rows)
    path <- file.path(directory,"objects",paste0(d$sha256,".json"))
    .nv_need(!file.exists(path),"Duplicate page coverage")
    writer$write(path,raw);.term_check(cancel);d
  }
  catalogue <- .v2_pages("metric_catalogue",context,emit,assets=assets)
  data <- .v2_tree("data",context,emit)
  project <- function(mid,d) {
    .term_check(cancel)
    if(!mid %in% allow) {d$state <- "suppressed";d$reason_code <- "policy.output_omitted";d$rows <- "0"}
    catalogue$add(d,mid)
    if(d$rows=="0") return(NULL)
    pages <- .v2_pages("data",context,emit,mid,assets)
    list(add=function(row,key) pages$add(row,paste0(mid,"|",key)),
      finish=function(first,last) data$add(pages$finish(),paste0(mid,"|",first),paste0(mid,"|",last)))
  }
  .store_scan_release(tx,validated,project,metadata,proof)
  if(!is.null(proof)) .publication_complete_checks(tx,c$release_id)
  # Flat saved concept browse is built only from retained typed dimensions. No
  # vocabulary/source lookups at publication or viewing time, and no raw text.
  concepts <- .v2_pages("concept_catalogue",context,emit,assets=assets)
  terms <- .v2_pages("terminology",context,emit,assets=assets)
  if(length(allow)) {
    ids <- paste(vapply(allow,.store_literal,""),collapse=",")
    # Use the same signed-integer/C-order codec as data selectors. Source IDs
    # are never sorted as ordinary decimal strings ("10" before "2").
    code <- "CASE WHEN left(tag->>'value',1)='-' THEN 'I0'||lpad((999999-length(substr(tag->>'value',2)))::text,6,'0')||':'||translate(substr(tag->>'value',2),'0123456789','9876543210') ELSE 'I1'||lpad(length(tag->>'value')::text,6,'0')||':'||(tag->>'value') END"
    sql <- paste0("WITH tags AS (SELECT DISTINCT CASE WHEN jsonb_typeof(v.value)='object' THEN v.value ELSE jsonb_build_object('kind','id','value',v.value#>>'{}') END AS tag FROM ",tx$schema,".achillesnext_aggregate_cell c CROSS JOIN LATERAL jsonb_each(c.dimensions) v WHERE c.release_id=",.store_uuid(c$release_id)," AND c.metric_id IN (",ids,") AND c.state<>'suppressed' AND ((right(v.key,4)='_tag' AND v.value->>'kind'='id') OR (right(v.key,11)='_concept_id' AND jsonb_typeof(v.value)='string' AND v.value#>>'{}'<>'null'))) SELECT jsonb_build_object('tag',tag,'key',",code,")::text FROM tags ORDER BY (",code,") COLLATE \"C\"")
    if(!is.null(metadata)) .term_project(tx,sql,context,concepts,terms,cancel) else tx$stream(sql,function(text) {
      .term_check(cancel)
      item <- .store_decode(text);tag <- item$tag;key <- .v2_component(tag,"concept_tag")
      .nv_need(identical(key,item$key),"Concept index codec mismatch")
      entry <- .object(concept_tag=tag,label=NULL,label_state="unavailable")
      concepts$add(entry,key);terms$add(c(entry,.object(domain_id=NULL)),key)
    })
  }
  root <- c(context,.object(kind="root",scope_kind=policy$scope_kind,publication_state="ready",eligible_for_current_pointer=TRUE,
    expected_metric_count=as.character(length(assets$metrics)),generated_at=.stamp(),source_schema=.object(sha256=c$observed_schema_sha256,declared_cdm_version=c$declared_cdm_version),source_consistency=.object(within_run=c$consistency_basis,reusable=FALSE,reason_code="source.reuse_not_asserted"),
    disclosure=.object(approval_id=approvalId,policy=policy,policy_sha256=.v2_hash(.v2_bytes(policy))),
    catalogue=catalogue$finish(),concepts=concepts$finish(),data=data$finish(),terminology=terms$finish()),
    if(!is.null(metadata)).object(saved_terminology=metadata))
  descriptor <- emit(root,"root","0")
  .term_check(cancel)
  writer$write(file.path(directory,"publication.json"),.v2_bytes(.object(contract_version=version,publication_id=publicationId,source_id=c$source_id,access_scope_id=scopeId,root=descriptor)))
  descriptor
}
.publication_failure <- function(code,state,publicationId,releaseId,root=NULL,promotionRequested=FALSE) {
  stop(structure(list(message=paste0("Result publication failed [",code,"]"),call=NULL,reason_code=code,
    outcome=state$outcome,publication_id=publicationId,release_id=releaseId,
    root_sha256=if(is.null(root))NULL else root$sha256,
    publication_changed=if(state$outcome=="unknown")NULL else state$outcome=="committed",
    current_changed=if(!promotionRequested)FALSE else if(state$outcome=="unknown")NULL else state$outcome=="committed",
    rollback_state=state$rollback_state,disconnect_state=state$disconnect_state),
    class=c("AchillesPublicationFailure","error","condition")))
}
#' Publish an approved projection and exact-byte export
#'
#' Validates the sealed registered-profile release, builds bounded immutable pages,
#' requires institutional approval, exports and optionally advances database current.
#' No source/CDM SQL is executed. Output directories must be new.
#' @inheritParams initializeResultStore
#' @param releaseId UUID of an already validated release.
#' @param exportDir New approved artifact directory, outside source/staging storage.
#' @param accessScopeId Institution-controlled audience identifier.
#' @param approvalId Institution-controlled approval record identifier.
#' @param policy Closed list: id, revision, scope_kind, allow_metrics (list of IDs).
#' @param institutionalPolicy Function approving the exact candidate descriptor and policy.
#' @param expectedRevision Exact current revision string, or NULL to prepare without promotion.
#' @param maxExportBytes Maximum total serialized bytes of staged objects and publication.json.
#' @export
publishResultRelease <- function(connectionDetails,resultsSchema,releaseId,exportDir,accessScopeId,approvalId,policy,institutionalPolicy,expectedRevision=NULL,savedTerminology=NULL,cancel=function()FALSE,maxScratchBytes=1024^3,maxExportBytes=1024^3,maxSnapshotBytes=1024^3) {
  .v2_scratch_limit(maxScratchBytes);.export_limit(maxExportBytes);.term_bound_limit(maxSnapshotBytes)
  .nv_need(.string(exportDir) && !file.exists(exportDir),"Export directory must be new")
  .nv_need(.string(accessScopeId) && grepl("^[a-z0-9_.:-]{1,128}$",accessScopeId),"Invalid audience identifier")
  .nv_need(.string(approvalId) && grepl("^[A-Za-z0-9_.:-]{1,128}$",approvalId),"Invalid approval identifier")
  .nv_need(is.function(institutionalPolicy),"An explicit institutional policy callback is required")
  if(!is.null(expectedRevision)) .nv_need(.v2_count(expectedRevision) && nchar(expectedRevision)<=18L,"Invalid expected revision")
  .term_check(cancel)
  .store_uuid(releaseId)
  state<-new.env(parent=emptyenv());state$outcome<-"not_committed";state$rollback_state<-"not_required";state$disconnect_state<-"not_required"
  pub<-.store_new_uuid();root<-NULL
  parent <- tryCatch(normalizePath(dirname(exportDir),mustWork=TRUE),error=function(e)stop("Export parent directory is unavailable",call.=FALSE))
  destination <- file.path(parent,basename(exportDir))
  lock <- file.path(parent,paste0(".achilles-export-lock-",.hash(destination)))
  stage<-NULL;ownsLock<-FALSE;ownsStage<-FALSE;ownsDestination<-FALSE
  cleanup<-function() {
    remove<-function(path).v2_scratch_io(function().nv_need(unlink(path,recursive=TRUE)==0L&&!file.exists(path)&&!dir.exists(path)))
    .v2_scratch_cleanup(list(function()if(state$outcome=="not_committed"&&ownsStage){remove(stage);ownsStage<<-FALSE},
      function()if(state$outcome=="not_committed"&&ownsDestination){remove(destination);ownsDestination<<-FALSE},
      function()if(ownsLock){remove(lock);ownsLock<<-FALSE}))
  }
  on.exit(suspendInterrupts(.v2_scratch_capture(cleanup)),add=TRUE)
  captured<-.v2_scratch_capture(function() {
    suspendInterrupts({
      .nv_need(dir.create(lock,mode="0700",showWarnings=FALSE),"Export destination is locked");ownsLock<<-TRUE
      allowInterrupts(Sys.sleep(0))
    })
    .nv_need(!file.exists(destination),"Export directory must be new")
    stage<<-tempfile(".achilles-export-",tmpdir=parent)
    suspendInterrupts({
      .nv_need(dir.create(stage,mode="0700",showWarnings=FALSE));ownsStage<<-TRUE
      allowInterrupts(Sys.sleep(0))
    })
    .nv_need(dir.create(file.path(stage,"objects"),mode="0700",showWarnings=FALSE),"Cannot prepare export objects")
    .store_transaction(connectionDetails,resultsSchema,function(tx) {
    .term_check(cancel);tx<-.publication_tx(tx,cancel)
    validated <- .store_validation_context(tx,releaseId);.nv_need(validated$context$state=="validated","Validate the release before publication")
    .term_check(cancel)
    proof <- .publication_data_proof(validated,policy,savedTerminology,pub,accessScopeId)
    root <<- .store_build_pages(tx,validated,pub,accessScopeId,approvalId,policy,stage,savedTerminology,cancel,maxExportBytes=maxExportBytes,maxSnapshotBytes=maxSnapshotBytes,proof=proof)
    admittedRoot<-.v2_directory(stage,check=function().term_check(cancel),maxScratchBytes=maxScratchBytes,proof=proof)
    .nv_need(identical(.v2_hash(.v2_bytes(admittedRoot)),root$sha256),"Admitted publication root mismatch")
    pointer<-.v2_bytes(.object(contract_version=admittedRoot$contract_version,publication_id=pub,
      source_id=validated$context$source_id,access_scope_id=accessScopeId,root=root))
    candidate <- .object(publication_id=pub,release_id=releaseId,source_id=validated$context$source_id,access_scope_id=accessScopeId,
      approval_id=approvalId,policy=policy,root=root)
    if(!is.null(savedTerminology))candidate<-c(candidate,.object(contract_version="2.1.0",saved_terminology=admittedRoot$saved_terminology))
    .term_check(cancel)
    approved <- tryCatch(isTRUE(institutionalPolicy(candidate)),error=function(e)FALSE)
    .nv_need(approved,"Institutional policy did not approve the candidate")
    receipt <- tx$one(paste0("SELECT receipt_id::text FROM ",tx$schema,".achillesnext_validation_receipt WHERE release_id=",.store_uuid(releaseId)," AND passed AND content_revision=",validated$context$content_revision," AND profile_sha256=",.store_literal(validated$context$profile_sha256)," ORDER BY validated_at DESC LIMIT 1"))
    tx$execute(paste0("INSERT INTO ",tx$schema,".achillesnext_publication VALUES (",.store_uuid(pub),",",.store_uuid(releaseId),",",.store_uuid(receipt),",",.store_literal(accessScopeId),",",.store_literal(.v2_hash(.v2_bytes(policy))),",",.store_literal(approvalId),",",.store_literal(root$sha256),",'building',now(),null)"))
    # Walk validated reachable objects; never enumerate or reserialize payloads.
    .publication_pages(stage,root,pointer,function(desc,bytes) {
      .term_check(cancel)
      hex <- paste(sprintf("%02x",as.integer(bytes)),collapse="")
      tx$execute(paste0("INSERT INTO ",tx$schema,".achillesnext_page_object VALUES (",.store_uuid(pub),",",.store_literal(desc$sha256),",",.store_literal(desc$kind),",decode('",hex,"','hex'))"))
    },check=function().term_check(cancel))
    tx$execute(paste0("UPDATE ",tx$schema,".achillesnext_publication SET state='ready',approved_at=now() WHERE publication_id=",.store_uuid(pub)))
    # Reserve a NEW directory atomically. A directory rename could replace a
    # foreign empty destination created after an earlier existence check.
    suspendInterrupts({
      .nv_need(dir.create(destination,mode="0700",showWarnings=FALSE),"Cannot reserve export destination")
      ownsDestination<<-TRUE
      allowInterrupts(Sys.sleep(0))
    })
    .nv_need(dir.create(file.path(destination,"objects"),mode="0700",showWarnings=FALSE),"Cannot prepare export objects")
    # All pages were already admitted and inserted in this transaction. Stream
    # only their fixed-size IDs; move bytes locally without a whole-file list.
    tx$stream(paste0("SELECT sha256::text FROM ",tx$schema,".achillesnext_page_object WHERE publication_id=",.store_uuid(pub)," ORDER BY sha256"),function(sha) {
      .nv_need(.string(sha)&&grepl("^[a-f0-9]{64}$",sha),"Invalid export object identity")
      name<-paste0(sha,".json")
      .nv_need(suppressWarnings(file.rename(file.path(stage,"objects",name),file.path(destination,"objects",name))),"Cannot install export object")
      .nv_need(identical(.v2_hash(.v2_safe_file(destination,paste0("objects/",name),.v2_limit("data"))),sha),
        "Installed publication object differs from approved bytes")
    })
    .nv_need(identical(.v2_safe_file(stage,"publication.json",262144L),pointer),"Publication pointer changed before installation")
    # No provider can admit a partially installed destination: pointer is last.
    .nv_need(suppressWarnings(file.rename(file.path(stage,"publication.json"),file.path(destination,"publication.json"))),"Cannot install export pointer")
    .nv_need(identical(.v2_safe_file(destination,"publication.json",262144L),pointer),"Installed publication pointer mismatch")
    suspendInterrupts({
      .v2_scratch_io(function().nv_need(unlink(stage,recursive=TRUE)==0L&&!dir.exists(stage)))
      ownsStage<<-FALSE
      allowInterrupts(Sys.sleep(0))
    })
    # The pointer lock covers only the final CAS, after all validation/file I/O.
    revision <- if(is.null(expectedRevision)) NULL else tx$one(paste0("SELECT ",tx$schema,".promote_publication(",.store_uuid(pub),",",expectedRevision,"::bigint)::text"))
    .term_check(cancel)
    list(publication_id=pub,root=root,revision=revision,export_dir=destination)
    },isolation=2L,state=state)
  })
  clean<-.v2_scratch_capture(function()suspendInterrupts(cleanup()))
  if(!captured$ok||!clean$ok) {
    if(state$outcome=="unknown").publication_failure("publication.commit_unknown",state,pub,releaseId,root,!is.null(expectedRevision))
    if(state$outcome=="committed") {
      code<-if(!clean$ok||state$disconnect_state!="confirmed")"publication.cleanup_failed" else
        if(inherits(captured$failure,"interrupt"))"publication.cancelled" else "publication.post_commit_failed"
      .publication_failure(code,state,pub,releaseId,root,!is.null(expectedRevision))
    }
    if(!clean$ok||!state$rollback_state%in%c("confirmed","not_required")||!state$disconnect_state%in%c("confirmed","not_required"))
      .publication_failure("publication.cleanup_failed",state,pub,releaseId,root,!is.null(expectedRevision))
    failure<-captured$failure
    if(inherits(failure,"achillesnext_scratch_error")||inherits(failure,"achillesnext_export_error")||inherits(failure,"achillesnext_terminology_error"))stop(failure)
    if(inherits(failure,"interrupt")).publication_failure("publication.cancelled",state,pub,releaseId,root,!is.null(expectedRevision))
    if(grepl("Current publication conflict",conditionMessage(failure),fixed=TRUE))stop("Current publication conflict",call.=FALSE)
    stop("Result publication failed; prior current preserved",call.=FALSE)
  }
  captured$value
}
