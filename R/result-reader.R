#' Read one immutable approved database page
#'
#' A trusted host supplies the complete pinned context. The database principal
#' must have SELECT on the approved_pages view and an enabled audience grant.
#' This function reads no CDM or aggregate tables and never resolves current.
#' @param connectionDetails PostgreSQL serving-principal connection details.
#' @param servingSchema Schema containing approved_pages.
#' @param sourceId Expected source identity.
#' @param publicationId Pinned publication UUID.
#' @param accessScopeId Expected institution-controlled audience.
#' @param rootSha256 Pinned root hash from a trusted current descriptor.
#' @param descriptor Expected child descriptor, or NULL to read the root.
#' @return Exact UTF-8 JSON bytes as an R raw vector.
#' @export
readResultObject <- function(connectionDetails,servingSchema,sourceId,publicationId,accessScopeId,rootSha256,descriptor=NULL) {
  tryCatch(.store_transaction(connectionDetails,servingSchema,function(tx) {
    .nv_need(.string(sourceId)&&.string(accessScopeId)&&.string(rootSha256)&&grepl("^[0-9a-f]{64}$",rootSha256))
    .store_uuid(publicationId)
    if(!is.null(descriptor)) {
      .v2_keys(descriptor,c("sha256","bytes","kind","rows"))
      .nv_need(.string(descriptor$sha256)&&grepl("^[0-9a-f]{64}$",descriptor$sha256)&&.v2_count(descriptor$bytes)&&.v2_count(descriptor$rows))
      .nv_need(descriptor$kind%in%c("index","data","metric_catalogue","concept_catalogue","terminology"))
      .nv_need(.nv_unsigned_cmp(descriptor$bytes,as.character(.v2_limit(descriptor$kind)))<=0)
    }
    sha <- if(is.null(descriptor))rootSha256 else descriptor$sha256
    kind <- if(is.null(descriptor))"root" else descriptor$kind
    text <- tx$one(paste0("SELECT encode(payload,'hex') FROM ",tx$schema,".approved_pages WHERE publication_id=",.store_uuid(publicationId),
      " AND source_id=",.store_literal(sourceId)," AND scope_id=",.store_literal(accessScopeId)," AND root_sha256=",.store_literal(rootSha256),
      " AND sha256=",.store_literal(sha)," AND kind=",.store_literal(kind)," AND octet_length(payload)<=",.v2_limit(kind)))
    at <- seq.int(1L,nchar(text),2L);bytes <- as.raw(strtoi(substring(text,at,at+1L),16L))
    .nv_need(.v2_hash(bytes)==sha && (is.null(descriptor)||as.character(length(bytes))==descriptor$bytes))
    doc <- .nv_json(bytes)
    .nv_need(doc$contract_version=="2.0.0"&&doc$publication_id==publicationId&&doc$source_id==sourceId&&doc$access_scope_id==accessScopeId)
    .nv_need(doc$profile_sha256==.v2_assets()$hash)
    bytes
  },readOnly=TRUE),error=function(e)stop("Approved result page unavailable or invalid",call.=FALSE))
}
