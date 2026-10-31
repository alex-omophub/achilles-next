# Approval pages are built once. Both transports retain these exact bytes.
.v2_descriptor <- function(bytes, kind, rows) .object(sha256=.v2_hash(bytes),bytes=as.character(length(bytes)),kind=kind,rows=rows)
.v2_limit <- function(kind) switch(kind,root=262144L,index=262144L,data=4194304L,1048576L)
.v2_tree <- function(kind, context, emit) {
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
    .nv_need(length(bucket)<128L,"Index depth limit")
    bucket[[length(bucket)+1L]] <- item
    if(length(bucket)==128L && level<8L) {levels[[level]] <<- list();add(node(bucket),level+1L)} else levels[[level]] <<- bucket
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
.v2_pages <- function(kind, context, emit, metricId=NULL) {
  tree <- .v2_tree(kind,context,emit); rows <- list(); keys <- character(); bytes <- 0L
  envelope <- function(rs) c(context,.object(kind=kind),if(kind=="data") .object(metric_id=metricId,metric_version=.v2_assets()$metrics[[metricId]]$version,rows=rs) else .object(entries=rs))
  flush <- function() {
    if(!length(rows)) return(invisible(NULL))
    d <- emit(envelope(rows),kind,as.character(length(rows)));tree$add(d,keys[[1]],keys[[length(keys)]])
    rows <<- list();keys <<- character();bytes <<- 0L
  }
  add <- function(row,key) {
    n <- length(.v2_bytes(row));.nv_need(n<=65536L,"Row resource limit")
    # A conservative envelope reserve avoids encoding an oversized candidate.
    if(length(rows) && (length(rows)>=2048L || bytes+n+8192L>.v2_limit(kind))) flush()
    rows[[length(rows)+1L]] <<- row;keys <<- c(keys,key);bytes <<- bytes+n
  }
  list(add=add,finish=function(){flush();tree$finish()})
}
.v2_policy <- function(policy) {
  .v2_keys(policy,c("id","revision","scope_kind","allow_metrics"))
  .nv_need(.string(policy$id) && grepl("^[a-z0-9_.:-]{1,96}$",policy$id) && .string(policy$revision) && nchar(policy$revision)<=96L)
  .nv_need(policy$scope_kind %in% c("restricted","distributable"))
  .nv_need(.nv_array(policy$allow_metrics) && all(vapply(policy$allow_metrics,.string,TRUE)) && !anyDuplicated(unlist(policy$allow_metrics)))
  allow <- unlist(policy$allow_metrics);.nv_need(all(allow %in% names(.v2_assets()$metrics)))
  # A policy omitting a denominator omits dependent outputs as well. Values are
  # physically absent, never hidden only by the renderer.
  repeat {
    nextAllow <- Filter(function(mid) {
      d <- .v2_assets()$metrics[[mid]]$denominator
      is.null(d) || strsplit(d," ",fixed=TRUE)[[1]][1] %in% allow
    },allow)
    if(setequal(nextAllow,allow)) break
    allow <- nextAllow
  }
  # Source output-status metadata describes the entire source inventory. A
  # partial projection uses its own catalogue and omits that source ledger.
  if(length(allow)<length(.v2_assets()$metrics)) allow <- setdiff(allow,"core.execution.output_status")
  allow
}
.store_build_pages <- function(tx, validated, publicationId, scopeId, approvalId, policy, directory) {
  allow <- .v2_policy(policy);c <- validated$context;datasets <- validated$datasets
  context <- .object(contract_version="2.0.0",publication_id=publicationId,release_id=c$release_id,source_id=c$source_id,
    profile_id=c$profile_id,profile_revision=c$profile_revision,profile_sha256=c$profile_sha256,access_scope_id=scopeId)
  emit <- function(doc,kind,rows) {
    raw <- .v2_bytes(doc);.nv_need(length(raw)<=.v2_limit(kind),"Page resource limit")
    d <- .v2_descriptor(raw,kind,rows)
    path <- file.path(directory,"objects",paste0(d$sha256,".json"))
    .nv_need(!file.exists(path),"Duplicate page coverage")
    writeBin(raw,path);Sys.chmod(path,"0600");d
  }
  catalogue <- .v2_pages("metric_catalogue",context,emit)
  data <- .v2_tree("data",context,emit)
  for(mid in sort(names(datasets),method="radix")) {
    d <- datasets[[mid]]
    if(!mid %in% allow) {d$state <- "suppressed";d$reason_code <- "policy.output_omitted";d$rows <- "0"}
    catalogue$add(d,mid)
    if(d$rows=="0") next
    pages <- .v2_pages("data",context,emit,mid)
    .store_rows(tx,c$release_id,mid,function(row,key) pages$add(row,paste0(mid,"|",key)))
    desc <- pages$finish()
    # The page tree carries the exact range, not a truncated metric label.
    bounds <- .store_decode(tx$one(paste0("SELECT jsonb_build_object('lo',min(sort_key COLLATE \"C\"),'hi',max(sort_key COLLATE \"C\"))::text FROM ",tx$schema,".aggregate_cell WHERE release_id=",.store_uuid(c$release_id)," AND metric_id=",.store_literal(mid))))
    data$add(desc,paste0(mid,"|",bounds$lo),paste0(mid,"|",bounds$hi))
  }
  # Flat saved concept browse is built only from retained typed dimensions. No
  # vocabulary/source lookups at publication or viewing time, and no raw text.
  concepts <- .v2_pages("concept_catalogue",context,emit)
  terms <- .v2_pages("terminology",context,emit)
  if(length(allow)) {
    ids <- paste(vapply(allow,.store_literal,""),collapse=",")
    # Use the same signed-integer/C-order codec as data selectors. Source IDs
    # are never sorted as ordinary decimal strings ("10" before "2").
    code <- "CASE WHEN left(tag->>'value',1)='-' THEN 'I0'||lpad((999999-length(substr(tag->>'value',2)))::text,6,'0')||':'||translate(substr(tag->>'value',2),'0123456789','9876543210') ELSE 'I1'||lpad(length(tag->>'value')::text,6,'0')||':'||(tag->>'value') END"
    sql <- paste0("WITH tags AS (SELECT DISTINCT CASE WHEN jsonb_typeof(v.value)='object' THEN v.value ELSE jsonb_build_object('kind','id','value',v.value#>>'{}') END AS tag FROM ",tx$schema,".aggregate_cell c CROSS JOIN LATERAL jsonb_each(c.dimensions) v WHERE c.release_id=",.store_uuid(c$release_id)," AND c.metric_id IN (",ids,") AND c.state<>'suppressed' AND ((right(v.key,4)='_tag' AND v.value->>'kind'='id') OR (right(v.key,11)='_concept_id' AND jsonb_typeof(v.value)='string'))) SELECT jsonb_build_object('tag',tag,'key',",code,")::text FROM tags ORDER BY (",code,") COLLATE \"C\"")
    tx$stream(sql,function(text) {
      item <- .store_decode(text);tag <- item$tag;key <- .v2_component(tag,"concept_tag")
      .nv_need(identical(key,item$key),"Concept index codec mismatch")
      entry <- .object(concept_tag=tag,label=NULL,label_state="unavailable")
      concepts$add(entry,key);terms$add(c(entry,.object(domain_id=NULL)),key)
    })
  }
  root <- c(context,.object(kind="root",scope_kind=policy$scope_kind,publication_state="ready",eligible_for_current_pointer=TRUE,
    expected_metric_count="142",generated_at=.stamp(),source_consistency=.object(within_run=c$consistency_basis,reusable=FALSE,reason_code="source.reuse_not_asserted"),
    disclosure=.object(approval_id=approvalId,policy=policy,policy_sha256=.v2_hash(.v2_bytes(policy))),
    catalogue=catalogue$finish(),concepts=concepts$finish(),data=data$finish(),terminology=terms$finish()))
  descriptor <- emit(root,"root","0")
  writeBin(.v2_bytes(.object(contract_version="2.0.0",publication_id=publicationId,source_id=c$source_id,access_scope_id=scopeId,root=descriptor)),file.path(directory,"publication.json"))
  Sys.chmod(file.path(directory,"publication.json"),"0600")
  descriptor
}
#' Publish an approved projection and exact-byte export
#'
#' Validates the sealed core-profile release, builds bounded immutable pages,
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
#' @export
publishResultRelease <- function(connectionDetails,resultsSchema,releaseId,exportDir,accessScopeId,approvalId,policy,institutionalPolicy,expectedRevision=NULL) {
  .nv_need(.string(exportDir) && !file.exists(exportDir),"Export directory must be new")
  .nv_need(.string(accessScopeId) && grepl("^[a-z0-9_.:-]{1,128}$",accessScopeId),"Invalid audience identifier")
  .nv_need(.string(approvalId) && grepl("^[A-Za-z0-9_.:-]{1,128}$",approvalId),"Invalid approval identifier")
  .nv_need(is.function(institutionalPolicy),"An explicit institutional policy callback is required")
  .v2_policy(policy)
  if(!is.null(expectedRevision)) .nv_need(.v2_count(expectedRevision) && nchar(expectedRevision)<=18L,"Invalid expected revision")
  parent <- normalizePath(dirname(exportDir),mustWork=TRUE);destination <- file.path(parent,basename(exportDir))
  lock <- file.path(parent,paste0(".achilles-export-lock-",.hash(destination)))
  .nv_need(dir.create(lock,mode="0700"),"Export destination is locked")
  on.exit(unlink(lock,recursive=TRUE),add=TRUE)
  .nv_need(!file.exists(destination),"Export directory must be new")
  stage <- tempfile(".achilles-export-",tmpdir=parent);.nv_need(dir.create(stage,mode="0700"));dir.create(file.path(stage,"objects"),mode="0700")
  finished <- FALSE;ownsDestination <- FALSE
  on.exit(if(!finished) {
    unlink(stage,recursive=TRUE)
    if(ownsDestination) unlink(destination,recursive=TRUE)
  },add=TRUE)
  result <- tryCatch(.store_transaction(connectionDetails,resultsSchema,function(tx) {
    validated <- .store_validate(tx,releaseId);.nv_need(validated$context$state=="validated","Validate the release before publication")
    pub <- .store_new_uuid();root <- .store_build_pages(tx,validated,pub,accessScopeId,approvalId,policy,stage)
    .v2_directory(stage)
    candidate <- .object(publication_id=pub,release_id=releaseId,source_id=validated$context$source_id,access_scope_id=accessScopeId,
      approval_id=approvalId,policy=policy,root=root)
    approved <- tryCatch(isTRUE(institutionalPolicy(candidate)),error=function(e)FALSE)
    .nv_need(approved,"Institutional policy did not approve the candidate")
    receipt <- tx$one(paste0("SELECT receipt_id::text FROM ",tx$schema,".validation_receipt WHERE release_id=",.store_uuid(releaseId)," AND passed AND content_revision=",validated$context$content_revision," AND profile_sha256=",.store_literal(validated$context$profile_sha256)," ORDER BY validated_at DESC LIMIT 1"))
    tx$execute(paste0("INSERT INTO ",tx$schema,".publication VALUES (",.store_uuid(pub),",",.store_uuid(releaseId),",",.store_uuid(receipt),",",.store_literal(accessScopeId),",",.store_literal(.v2_hash(.v2_bytes(policy))),",",.store_literal(approvalId),",",.store_literal(root$sha256),",'building',now(),null)"))
    # Walk validated reachable objects; never enumerate or reserialize payloads.
    .v2_directory(stage,function(desc,bytes) {
      hex <- paste(sprintf("%02x",as.integer(bytes)),collapse="")
      tx$execute(paste0("INSERT INTO ",tx$schema,".page_object VALUES (",.store_uuid(pub),",",.store_literal(desc$sha256),",",.store_literal(desc$kind),",decode('",hex,"','hex'))"))
    })
    tx$execute(paste0("UPDATE ",tx$schema,".publication SET state='ready',approved_at=now() WHERE publication_id=",.store_uuid(pub)))
    .nv_need(!file.exists(destination) && file.rename(stage,destination),"Cannot finalize approved export")
    ownsDestination <<- TRUE
    # The pointer lock covers only the final CAS, after all validation/file I/O.
    revision <- if(is.null(expectedRevision)) NULL else tx$one(paste0("SELECT ",tx$schema,".promote_publication(",.store_uuid(pub),",",expectedRevision,"::bigint)::text"))
    list(publication_id=pub,root=root,revision=revision,export_dir=destination)
  },isolation=2L),error=function(e) {
    if(ownsDestination && dir.exists(destination)) unlink(destination,recursive=TRUE)
    if(grepl("Current publication conflict",conditionMessage(e),fixed=TRUE)) stop("Current publication conflict",call.=FALSE)
    stop("Result publication failed; prior current preserved",call.=FALSE)
  })
  finished <- TRUE;result
}
