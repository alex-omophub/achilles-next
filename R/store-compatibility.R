# A version marker is a compatibility precondition, not content validation or a
# proof that an arbitrary schema implements this store. Never attempt a repair.
.store_version <- function(tx) {
  versions<-character()
  tx$stream(paste0("SELECT CASE WHEN octet_length(version::text)<=32 THEN version::text ELSE NULL END FROM ",
    tx$schema,".achillesnext_storage_version LIMIT 2"),function(version) {
      .nv_need(.string(version),"Invalid store version marker");versions<<-c(versions,version)
    })
  .nv_need(identical(versions,"2.0.0"),"Unsupported or ambiguous store version");versions[[1L]]
}
#' Inspect the restricted result store's version without modifying it
#' @inheritParams initializeResultStore
#' @return Version-match diagnostics only; no content validation, write-privilege
#'   check, migration, source access or publication occurs. Missing, denied,
#'   multiple and unsupported version markers fail closed.
#' @export
inspectResultStore <- function(connectionDetails,resultsSchema) {
  tryCatch(.store_transaction(connectionDetails,resultsSchema,function(tx) {
    version<-.store_version(tx)
    .object(results_schema=resultsSchema,storage_version=version,required_storage_version="2.0.0",
      version_compatible=TRUE,result_data_validated=FALSE,write_privileges_verified=FALSE,upgrade_performed=FALSE)
  },readOnly=TRUE),error=function(e)stop("Result store version unavailable or unsupported; no migration performed",call.=FALSE))
}
