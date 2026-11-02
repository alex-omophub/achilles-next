# A closed installed registry. No caller-supplied paths, SQL, schemas or callbacks.
.profile_registry <- function() {
  if(exists("registered_profiles",.validation_cache,inherits=FALSE)) return(get("registered_profiles",.validation_cache))
  file <- function(p) system.file(p,package="AchillesNext",mustWork=TRUE)
  lock <- jsonlite::fromJSON(file("analysis/registered-profile-lock.json"),simplifyVector=FALSE)
  .analysis_keys(lock,"sha256");.nv_need(.nv_object(lock$sha256) && length(lock$sha256)<=128L)
  for(path in names(lock$sha256)) {
    .nv_need(grepl("^[a-z0-9/-]+[.](json|sql)$",path) && !grepl("..",path,fixed=TRUE),"Unsafe registered path")
    .nv_need(identical(digest::digest(file=file(path),algo="sha256"),lock$sha256[[path]]),"Registered profile integrity failure")
  }
  path <- "analysis/registered-profiles-v1.json"
  .nv_need(path%in%names(lock$sha256),"Unbound profile registry")
  doc <- jsonlite::fromJSON(file(path),simplifyVector=FALSE)
  .analysis_keys(doc,c("format_version","profiles"))
  .nv_need(identical(doc$format_version,"1.0.0") && .nv_object(doc$profiles) &&
    length(doc$profiles)>0L && length(doc$profiles)<=16L && !anyDuplicated(names(doc$profiles)),"Unsupported profile registry")
  for(id in names(doc$profiles)) {
    .nv_need(grepl("^[a-z][a-z0-9-]{1,95}$",id) && id!="core-characterization-v2","Invalid registered profile identity")
    entry <- doc$profiles[[id]]
    .analysis_keys(entry,c("revision","profile","rows","analysis","producer_sql","check_sql","singletons","partitions"))
    .nv_need(.string(entry$revision) && all(vapply(entry[c("profile","rows","analysis","producer_sql","check_sql")],
      function(p).string(p)&&p%in%names(lock$sha256),TRUE)),"Unbound profile assets")
  }
  result <- list(profiles=doc$profiles,hash=lock$sha256[[path]],files=lock$sha256)
  assign("registered_profiles",result,.validation_cache);result
}
.profile_assets <- function(profileId,revision=NULL,hash=NULL) {
  .nv_need(.string(profileId),"Unregistered runtime profile")
  if(profileId=="core-characterization-v2") assets <- .v2_assets() else {
    registry <- .profile_registry();entry <- registry$profiles[[profileId]]
    .nv_need(!is.null(entry),"Unregistered runtime profile")
    key <- paste0("profile:",profileId)
    if(exists(key,.validation_cache,inherits=FALSE)) assets <- get(key,.validation_cache) else {
      read <- function(p)jsonlite::fromJSON(system.file(p,package="AchillesNext",mustWork=TRUE),simplifyVector=FALSE)
      profile <- read(entry$profile);rows <- read(entry$rows);analysis <- read(entry$analysis);base <- .v2_assets()
      .nv_need(identical(profile$profile_id,profileId) && identical(profile$revision,entry$revision) &&
        identical(rows$profile_sha256,registry$files[[entry$profile]]) && identical(analysis$profile_sha256,rows$profile_sha256),"Registered profile identity mismatch")
      ids <- vapply(profile$metrics,function(m)m$id,"")
      .nv_need(length(ids)>0L && length(ids)<=128L && !anyDuplicated(ids) &&
        all(grepl("^[a-z][a-z0-9_.]{1,127}$",ids)) && identical(ids,vapply(rows$metrics,function(m)m$id,"")),"Invalid registered metric inventory")
      .nv_need(!any(grepl("^(core|observed)[.]",ids)),"Reserved core metric namespace")
      # The initial contribution seam supports exact PERSON count partitions.
      # Other row/measure/conditional kinds need an explicit future contract.
      for(i in seq_along(ids)) {
        m <- profile$metrics[[i]];s <- rows$metrics[[i]]
        .nv_need(identical(m$availability,"required_when_table_readable") && identical(m$population,"person_table") &&
          identical(m$version,s$version) && identical(m$dimensions,s$dimensions) &&
          identical(names(s$value_keys_by_row_kind),"counts") && identical(unlist(s$value_keys_by_row_kind$counts),"person_count") &&
          !length(s$extra_dimensions_by_row_kind) && all(unlist(s$dimensions)%in%names(base$dimensions)),"Unsupported registered metric shape")
      }
      .nv_need(.nv_array(entry$singletons) && !anyDuplicated(unlist(entry$singletons)) &&
        all(unlist(entry$singletons)%in%ids) && .nv_array(entry$partitions),"Invalid registered constraints")
      for(pair in entry$partitions) {
        .analysis_keys(pair,c("metric_id","target_metric_id"))
        .nv_need(.string(pair$metric_id) && pair$metric_id%in%ids && .string(pair$target_metric_id) &&
          pair$target_metric_id%in%unlist(entry$singletons) && pair$metric_id!=pair$target_metric_id,"Invalid registered partition")
      }
      .nv_need(setequal(ids,c(unlist(entry$singletons),vapply(entry$partitions,function(p)p$metric_id,""))),"Unconstrained registered output")
      for(mid in unlist(entry$singletons)) .nv_need(!length(rows$metrics[[match(mid,ids)]]$dimensions),"Singleton must have source grain")
      definition <- .analysis_validate(analysis,profile,rows)
      for(mid in ids) {
        ref <- definition$analyses[[mid]]$denominator
        if(!is.null(ref)) .nv_need(ref$metric_id%in%unlist(entry$singletons) &&
          !length(definition$rules[[ref$rule]]$dimensions),"Unsupported registered dependency shape")
      }
      assets <- list(profile=profile,hash=rows$profile_sha256,is_core=FALSE,
        metrics=stats::setNames(profile$metrics,ids),rows=stats::setNames(rows$metrics,ids),metadata=base$metadata,dimensions=base$dimensions,
        analysis=list(definitions=definition,hash=registry$files[[entry$analysis]]),
        singletons=unlist(entry$singletons),partitions=entry$partitions,entry=entry)
      assign(key,assets,.validation_cache)
    }
  }
  .nv_need((is.null(revision)||identical(revision,assets$profile$revision)) &&
    (is.null(hash)||identical(hash,assets$hash)),"Unregistered runtime profile revision or hash")
  assets
}
.profile_store_checks <- function(tx,release,datasets,assets) {
  for(pair in assets$partitions) {
    if(any(vapply(datasets[c(pair$metric_id,pair$target_metric_id)],function(d)d$state=="suppressed",TRUE))) next
    prefix <- paste0("SELECT COALESCE(sum(person_count),0)::text FROM ",tx$schema,".achillesnext_aggregate_cell WHERE release_id=",.store_uuid(release)," AND metric_id=")
    .nv_need(identical(tx$one(paste0(prefix,.store_literal(pair$metric_id))),tx$one(paste0(prefix,.store_literal(pair$target_metric_id)))),"Registered partition does not reconcile")
  }
}
.profile_context <- function(context) {
  .nv_need(all(vapply(context[c("profile_id","profile_revision","profile_sha256")],.string,TRUE)) &&
    all(c("profile_id","profile_revision","profile_sha256")%in%names(context)),"Missing registered profile context")
  .profile_assets(context$profile_id,context$profile_revision,context$profile_sha256)
}
.profile_artifact_checks <- function(catalogue,sums,assets) {
  for(pair in assets$partitions) {
    if(any(vapply(catalogue[c(pair$metric_id,pair$target_metric_id)],function(d)d$state=="suppressed",TRUE))) next
    .nv_need(identical(sums[[pair$metric_id]],sums[[pair$target_metric_id]]),"Projected registered partition does not reconcile")
  }
}
.profile_registration_sql <- function(schema,profileId) {
  assets <- .profile_assets(profileId);.nv_need(!isTRUE(assets$is_core),"Core profile is registered by store initialization")
  path <- system.file(assets$entry$profile,package="AchillesNext",mustWork=TRUE)
  bytes <- readBin(path,"raw",n=file.info(path)$size)
  hex <- paste(sprintf("%02x",as.integer(bytes)),collapse="")
  paste0("WITH input AS (SELECT decode('",hex,"','hex') AS b), parsed AS ",
    "(SELECT b,convert_from(b,'UTF8')::jsonb AS d FROM input) INSERT INTO ",schema,
    ".achillesnext_profile_registry SELECT encode(sha256(b),'hex'),d->>'profile_id',d->>'revision',b,d FROM parsed ON CONFLICT (profile_sha256) DO NOTHING")
}
#' Register an installed analysis definition in an existing result store
#' @param connectionDetails PostgreSQL store-owner DatabaseConnector details.
#' @param resultsSchema Existing initialized aggregate schema.
#' @param profileId ID of an installed registered profile.
#' @return Invisibly, the registered profile hash.
#' @export
registerAnalysisProfile <- function(connectionDetails,resultsSchema,profileId) {
  assets <- .profile_assets(profileId)
  .nv_need(!isTRUE(assets$is_core),"Core profile is registered by store initialization")
  .store_transaction(connectionDetails,resultsSchema,function(tx)tx$execute(.profile_registration_sql(tx$schema,profileId)))
  invisible(assets$hash)
}
