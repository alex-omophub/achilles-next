# Internal host-owned transports. A trusted approval callback is mandatory.
.saved_error <- function(code) stop(structure(list(message=paste("Saved result read failed:",code),call=NULL,code=code),class=c("achillesnext_read_error","error","condition")))
.saved_context <- function(context) {
  .v2_keys(context,c(.saved_common(),"root","authorization_epoch","instance_id"))
  .nv_need(!anyDuplicated(names(context)))
  for(n in c(.saved_common(),"authorization_epoch","instance_id")) .nv_need(.string(context[[n]]) && nchar(context[[n]],type="bytes")<=256L)
  .nv_need(context$contract_version=="2.0.0")
  .store_uuid(context$publication_id);.store_uuid(context$release_id)
  .v2_descriptor_check(context$root);.nv_need(context$root$kind=="root" && context$root$rows=="0")
  invisible(.profile_context(context));context
}
.saved_transport <- function(context,authorize,fetch,cacheAllowed=TRUE) {
  context <- .saved_context(context)
  .nv_need(is.function(authorize) && is.function(fetch) && is.logical(cacheAllowed) && length(cacheAllowed)==1L && !is.na(cacheAllowed))
  check <- function(cancel) {
    if(!is.function(cancel)) .saved_error("invalid_request")
    cancelled <- cancel()
    if(!identical(cancelled,TRUE) && !identical(cancelled,FALSE)) .saved_error("invalid_request")
    if(cancelled) .saved_error("aborted")
    allowed <- tryCatch(authorize(context),error=function(e)FALSE)
    if(!identical(allowed,TRUE)) .saved_error("inaccessible")
    cancelled <- cancel()
    if(!identical(cancelled,TRUE) && !identical(cancelled,FALSE)) .saved_error("invalid_request")
    if(cancelled) .saved_error("aborted")
    invisible(TRUE)
  }
  list(context=context,cacheAllowed=cacheAllowed,check=check,read=function(d,cancel) {
    check(cancel);.v2_descriptor_check(d)
    bytes <- tryCatch(fetch(d),error=function(e).saved_error("unavailable"))
    check(cancel);bytes
  })
}
.saved_artifact_transport <- function(directory,context,authorize) {
  .nv_need(.string(directory) && !nzchar(Sys.readlink(directory)))
  directory <- normalizePath(directory,mustWork=TRUE);.nv_need(dir.exists(directory))
  # The host pin, not mutable publication.json, selects every object.
  .saved_transport(context,authorize,function(d).v2_safe_file(directory,paste0("objects/",d$sha256,".json"),.v2_limit(d$kind)))
}
.saved_database_transport <- function(connectionDetails,servingSchema,context,authorize) {
  context <- .saved_context(context)
  .saved_transport(context,authorize,function(d)readResultObject(connectionDetails,servingSchema,
    context$source_id,context$publication_id,context$access_scope_id,context$root$sha256,
    if(d$kind=="root")NULL else d),cacheAllowed=FALSE)
  # No cached DB page can outlive its audience grant: each read rechecks the view.
}
