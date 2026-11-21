#' Read one immutable approved database page
#'
#' A trusted host supplies the complete pinned context. The database principal
#' must have SELECT on the achillesnext_approved_pages view and an enabled audience grant.
#' This function reads no CDM or aggregate tables and never resolves current.
#' @param connectionDetails PostgreSQL serving-principal connection details.
#' @param servingSchema Schema containing achillesnext_approved_pages.
#' @param sourceId Expected source identity.
#' @param publicationId Pinned publication UUID.
#' @param accessScopeId Expected institution-controlled audience.
#' @param rootSha256 Pinned root hash from a trusted current descriptor.
#' @param descriptor Expected child descriptor, or NULL to read the root.
#' @return Exact UTF-8 JSON bytes as an R raw vector.
#' @export
readResultObject <- function(connectionDetails,servingSchema,sourceId,publicationId,accessScopeId,rootSha256,descriptor=NULL) {
  tryCatch({
    bytes <- .read_approved_page_bytes(connectionDetails, servingSchema, sourceId, publicationId,
                                       accessScopeId, rootSha256, descriptor)
    expected <- descriptor %||% .object(sha256=rootSha256,bytes=as.character(length(bytes)),kind="root",rows="0")
    doc <- .v2_verified_bytes(bytes,expected)
    .nv_need(.term_version(doc$contract_version)&&doc$publication_id==publicationId&&doc$source_id==sourceId&&doc$access_scope_id==accessScopeId)
    invisible(.profile_context(doc))
    bytes
  },error=function(e)stop("Approved result page unavailable or invalid",call.=FALSE))
}

# Only the verified public reader and the saved provider's page verifier consume these bytes.
.read_approved_page_bytes <- function(connectionDetails, servingSchema, sourceId, publicationId,
                                      accessScopeId, rootSha256, descriptor=NULL) {
  .nv_need(.string(sourceId)&&.string(accessScopeId)&&.string(rootSha256)&&grepl("^[0-9a-f]{64}$",rootSha256))
  .store_uuid(publicationId)
  if(!is.null(descriptor)) {
    .v2_descriptor_check(descriptor)
    .nv_need(descriptor$kind%in%c("index","data","metric_catalogue","concept_catalogue","terminology"))
  }
  sha <- if(is.null(descriptor))rootSha256 else descriptor$sha256
  kind <- if(is.null(descriptor))"root" else descriptor$kind
  text <- .store_transaction(connectionDetails, servingSchema, function(tx) {
    tx$one(paste0("SELECT encode(payload,'hex') FROM ",tx$schema,".achillesnext_approved_pages WHERE publication_id=",.store_uuid(publicationId),
      " AND source_id=",.store_literal(sourceId)," AND scope_id=",.store_literal(accessScopeId)," AND root_sha256=",.store_literal(rootSha256),
      " AND sha256=",.store_literal(sha)," AND kind=",.store_literal(kind)," AND octet_length(payload)<=",.v2_limit(kind)))
  }, readOnly=TRUE, disconnect=.disconnect_approved_page_reader)
  at <- seq.int(1L, nchar(text), 2L)
  as.raw(strtoi(substring(text, at, at+1L), 16L))
}

# R may handle SIGPIPE by unwinding the stack. Deliver any socket-close signal
# after the Java call returns so that it cannot unwind through a live JNI frame.
.with_serving_disconnect_guard <- function(work) {
  changed <- FALSE
  on.exit(if (changed) tryCatch(.Call(C_unblock_serving_sigpipe), error=function(e) {
    if (!inherits(e, "simpleError") ||
        !identical(conditionMessage(e), gettext("ignoring SIGPIPE signal", domain="R"))) stop(e)
    # R's signal handler can itself leave SIGPIPE blocked after its nonlocal jump.
    .Call(C_unblock_serving_sigpipe)
  }))
  suspendInterrupts(changed <- .Call(C_block_serving_sigpipe))
  work()
}

.disconnect_approved_page_reader <- function(connection, close=DatabaseConnector::disconnect) {
  .with_serving_disconnect_guard(function() {
    close(connection)
    rJava::.jcheck()
    .nv_need(identical(rJava::.jcall(connection@jConnection, "Z", "isClosed"), TRUE),
             "Approved page connection remained open")
    invisible(TRUE)
  })
}
