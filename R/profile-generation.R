.profile_sql <- function(path,schema) {
  sql <- paste(readLines(system.file(path,package="AchillesNext",mustWork=TRUE),warn=FALSE),collapse="\n")
  sql <- gsub("{{cdm_schema}}",paste0('"',schema,'"'),sql,fixed=TRUE)
  .nv_need(!grepl("{{",sql,fixed=TRUE),"Unbound registered SQL token");sql
}
#' Plan an installed registered analysis profile
#' @param profileId ID of a separately installed profile.
#' @param cdmSchema Source schema identifier.
#' @param sourceId Institution-controlled source identifier, 1 to 256 UTF-8 bytes.
#' @param declaredCdmVersion Declared CDM version, 5.3, 5.4 or 5.5.
#' @return A deterministic source-free plan with profile and executable identities.
#' @export
planAnalysisProfile <- function(profileId,cdmSchema,sourceId,declaredCdmVersion) {
  .nv_need(.batch_identifier(cdmSchema) && .string(sourceId) && nchar(enc2utf8(sourceId),type="bytes")%in%1:256 &&
    .string(declaredCdmVersion) && declaredCdmVersion%in%c("5.3","5.4","5.5"),"Invalid analysis source configuration")
  assets <- .profile_assets(profileId);.nv_need(!isTRUE(assets$is_core),"Use the core characterization planner for this profile")
  pending <- names(assets$metrics);order <- character()
  while(length(pending)) {
    ready <- Filter(function(id){target <- .analysis_dependency(id,assets);is.null(target)||target%in%order},pending)
    .nv_need(length(ready)>0L,"Cyclic analysis dependencies");order <- c(order,ready);pending <- setdiff(pending,ready)
  }
  entry <- assets$entry;registry <- .profile_registry()
  plan <- .object(format_version="1.0.0",engine="postgresql",source=.object(cdm_schema=cdmSchema,source_id=sourceId,declared_cdm_version=declaredCdmVersion),
    profile=.object(id=profileId,revision=assets$profile$revision,sha256=assets$hash),metric_order=as.list(order),
    definitions=.object(registry_sha256=registry$hash,assets_sha256=registry$files[unlist(entry[c("profile","rows","analysis","producer_sql","check_sql")])],runtime=.run_definitions()),
    execution="planning_only",reuse="recompute_no_durable_source_identity")
  plan$plan_sha256 <- .hash(.json(plan));plan
}
.profile_preflight <- function(tx,assets,schema) {
  inputs <- sort(unique(unlist(lapply(assets$metrics,function(m)unlist(m$inputs)))))
  metadata <- list()
  for(input in inputs) {
    parts <- strsplit(input,".",fixed=TRUE)[[1]]
    .nv_need(length(parts)==2L && all(vapply(parts,.batch_identifier,TRUE)),"Invalid registered input")
    value <- .store_decode(tx$one(paste0("SELECT COALESCE((SELECT jsonb_build_object('type',data_type,'nullable',is_nullable) FROM information_schema.columns WHERE table_schema=",.store_literal(schema),
      " AND table_name=",.store_literal(parts[[1]])," AND column_name=",.store_literal(parts[[2]]),"),'null'::jsonb)::text")))
    .nv_need(!is.null(value) && value$type%in%c("smallint","integer","bigint"),"Registered input missing, inaccessible or not an exact integer")
    metadata[[input]] <- value
  }
  .hash(.json(metadata))
}
#' Generate exact aggregates for an installed registered analysis profile
#' @inheritParams planAnalysisProfile
#' @param connectionDetails PostgreSQL DatabaseConnector connection details.
#' @param resultsSchema Initialized writable aggregate schema, separate from source.
#' @param maxRows Maximum aggregate rows, from 1 to 1000000; no patient rows are fetched.
#' @param queryTimeoutSeconds Per-statement timeout, including the source aggregate.
#' @return A complete building release; seal, validate and explicitly approve it separately.
#' @export
generateAnalysisProfile <- function(connectionDetails,cdmSchema,sourceId,resultsSchema,declaredCdmVersion,profileId,maxRows=10000L,queryTimeoutSeconds=60L) {
  plan <- planAnalysisProfile(profileId,cdmSchema,sourceId,declaredCdmVersion);assets <- .profile_assets(profileId)
  .nv_need(!identical(cdmSchema,resultsSchema),"Separate source and result schemas are required")
  .nv_need(is.numeric(maxRows)&&length(maxRows)==1L&&is.finite(maxRows)&&maxRows>=1&&maxRows<=1000000&&maxRows==floor(maxRows),"Invalid aggregate row budget")
  .store_transaction(connectionDetails,resultsSchema,function(tx) {
    s <- tx$schema;lit <- .store_literal
    .nv_need(tx$one(paste0("SELECT count(*)::text FROM ",s,".achillesnext_profile_registry WHERE profile_sha256=",lit(assets$hash)))=="1","Install the registered profile in the result store first")
    schemaHash <- .profile_preflight(tx,assets,cdmSchema)
    check <- .store_decode(tx$one(.profile_sql(assets$entry$check_sql,cdmSchema)))
    .analysis_keys(check,c("valid","source_count"));.nv_need(isTRUE(check$valid)&&.v2_count(check$source_count),"Invalid registered source membership")
    empty <- check$source_count=="0";state <- if(empty)"empty_source" else "computed";reason <- if(empty)"source.empty" else NULL
    release <- .store_new_uuid();run <- .store_new_uuid();source <- .store_new_uuid()
    unknown <- .object(state="unknown",value=NULL,basis=NULL,assertion_id=NULL,reason_code="source.no_verified_release")
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_source_release VALUES (",.store_uuid(source),",",lit(sourceId),",",lit(.json(unknown)),"::jsonb,",lit(.json(unknown)),"::jsonb,",lit(schemaHash),",",lit(declaredCdmVersion),",now())"))
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_analysis_run(run_id,source_release_id,request_sha256,profile_id,profile_revision,profile_sha256,state,consistency_basis,started_at) VALUES (",
      .store_uuid(run),",",.store_uuid(source),",",lit(plan$plan_sha256),",",lit(profileId),",",lit(assets$profile$revision),",",lit(assets$hash),",'running','single_repeatable_read',now())"))
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_result_release VALUES (",.store_uuid(release),",",.store_uuid(run),",'building',",length(assets$metrics),",0,NULL)"))
    counts <- stats::setNames(rep(list("0"),length(assets$metrics)),names(assets$metrics));targets <- list();seen <- 0L
    for(mid in names(assets$metrics)) {
      m <- assets$metrics[[mid]]
      values <- c(.store_uuid(release),vapply(c(mid,m$version,m$population,m$grain,assets$rows[[mid]]$row_schema_id,.v2_hash(.v2_bytes(m)),state),lit,""),
        if(is.null(reason))"NULL" else lit(reason),"true","'{\"state\":\"supported\",\"reason_code\":null}'::jsonb","0","'{\"scope_kind\":\"standard_full\",\"complete\":true,\"excluded_record_count\":\"0\",\"reason_code\":null}'::jsonb")
      tx$execute(paste0("INSERT INTO ",s,".achillesnext_dataset VALUES (",paste(values,collapse=","),")"))
    }
    order <- paste(vapply(seq_along(plan$metric_order),function(i)paste0("WHEN ",lit(plan$metric_order[[i]])," THEN ",i),""),collapse=" ")
    sql <- paste0("SELECT doc FROM (",.profile_sql(assets$entry$producer_sql,cdmSchema),") q(doc) ORDER BY CASE doc::jsonb->>'metric_id' ",order," ELSE 2147483647 END")
    tx$stream(sql,function(text) {
      seen <<- seen+1L;.nv_need(seen<=maxRows && nchar(text,type="bytes")<=65536L,"Registered aggregate resource limit")
      item <- .store_decode(text);.analysis_keys(item,c("metric_id","dimensions","row_kind","values"));mid <- item$metric_id
      .nv_need(.string(mid)&&mid%in%names(assets$metrics),"Unregistered generated metric")
      row <- .object(row_key="",dimensions=item$dimensions,row_kind=item$row_kind,state=state,reason_code=reason,values=item$values,denominator_refs=list())
      spec <- .analysis_denominator(mid,row,assets,forKey=TRUE)
      if(!is.null(spec)) {
        target <- targets[[spec$metric_id]];.nv_need(!is.null(target),"Missing generated singleton dependency")
        row$denominator_refs <- lapply(spec$measures,function(m).object(measure=m$source,metric_id=spec$metric_id,row_key=target$row_key,field=m$target,value=target$values[[m$target]]))
        .v2_denominator_check(mid,row,function(id,key)target$dimensions,assets)
      }
      row$row_key <- .v2_row_identity(assets$rows[[mid]],row);.store_put_row(tx,release,mid,row,assets)
      counts[[mid]] <<- .nv_add(counts[[mid]],"1")
      if(mid%in%assets$singletons) {.nv_need(counts[[mid]]=="1","Duplicate generated singleton");targets[[mid]] <<- row}
    })
    for(mid in names(counts)) tx$execute(paste0("UPDATE ",s,".achillesnext_dataset SET row_count=",counts[[mid]]," WHERE release_id=",.store_uuid(release)," AND metric_id=",lit(mid)))
    .nv_need(all(vapply(counts[assets$singletons],function(n)n=="1",TRUE)),"Missing generated singleton")
    .profile_store_checks(tx,release,NULL,assets)
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_operation VALUES (",.store_uuid(run),",'registered.generate',",lit(.hash(.json(plan$definitions))),",'succeeded','[]','{}'); UPDATE ",s,".achillesnext_analysis_run SET state='succeeded',finished_at=now() WHERE run_id=",.store_uuid(run)))
    list(release_id=release,profile_id=profileId,state="building",publishable=FALSE,aggregate_rows=as.character(seen),profile_complete=TRUE)
  },queryTimeoutSeconds=queryTimeoutSeconds)
}
