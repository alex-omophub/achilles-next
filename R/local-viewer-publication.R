# The selected folder supplies bytes. The host's publication receipt or
# authorization callback supplies authority for the immutable root.
.viewer_receipt <- function(x) {
  .v2_keys(x, c("publication_id", "root", "revision", "export_dir"))
  .store_uuid(x$publication_id)
  .v2_descriptor_check(x$root)
  .nv_need(identical(x$root$kind, "root") && identical(x$root$rows, "0") &&
    .string(x$export_dir) && (is.null(x$revision) || .v2_count(x$revision)),
    "Supply the result returned by publishResultRelease()")
  x
}

.viewer_publication <- function(directory, receipt, authorize) {
  tryCatch({
    if (is.null(receipt) && is.null(authorize))
      .viewer_error("inaccessible", "Open the approved publication returned by publishResultRelease(), or supply its authorization callback.")
    .nv_need(dir.exists(directory) && !nzchar(Sys.readlink(directory)))
    path <- normalizePath(directory, mustWork = TRUE)
    pointerBytes <- .v2_safe_file(path, "publication.json", .v2_limit("root"))
    pointer <- .nv_json(pointerBytes)
    .v2_keys(pointer, c("contract_version", "publication_id", "source_id", "access_scope_id", "root"))
    .nv_need(identical(pointerBytes, .v2_bytes(pointer)))
    if (!.term_version(pointer$contract_version))
      .viewer_error("incompatible", "This publication version is unsupported.")
    d <- pointer$root
    .v2_descriptor_check(d)
    .nv_need(identical(d$kind, "root") && identical(d$rows, "0"))
    if (!is.null(receipt) && (!identical(receipt$publication_id, pointer$publication_id) ||
        !.nv_equal(receipt$root, d))) .viewer_error("inaccessible", "The selected publication differs from the approved receipt.")
    bytes <- .v2_safe_file(path, paste0("objects/", d$sha256, ".json"), .v2_limit("root"))
    root <- .v2_verified_bytes(bytes, d, pointer[c("contract_version", "publication_id", "source_id", "access_scope_id")])
    if (!identical(root$profile_id, "core-characterization-v2"))
      .viewer_error("incompatible", "This viewer requires the core characterization profile.")
    context <- c(root[.saved_common()], .object(root=d, authorization_epoch="1", instance_id=.store_new_uuid()))
    allowed <- function(candidate) identical(candidate, context) &&
      (is.null(authorize) || identical(tryCatch(authorize(candidate), error=function(e) FALSE), TRUE))
    if (!allowed(context)) .viewer_error("inaccessible", "This publication is not authorized for the viewer.")
    # Check the ready state, disclosure policy and registered profile before
    # reporting a successful open. Descendants are checked on bounded reads.
    .saved_page(bytes, d, context[.saved_common()], .profile_context(context))
    provider <- openArtifactResultProvider(path, context, allowed)
    list(status=.object(state="ready", message=NULL), provider=provider)
  }, AchillesViewerError=function(e) list(status=.object(state=e$state, message=e$message)),
  error=function(e) list(status=.object(state="invalid", message="The approved publication pointer or root could not be verified.")))
}

.viewer_publication_read <- function(snapshot, key, query, reportMetric) {
  if (is.null(snapshot$provider)) {
    code <- switch(snapshot$status$state, inaccessible="inaccessible", incompatible="incompatible", "integrity_failure")
    .saved_error(code)
  }
  if (key == "api/people.json") {
    if (nzchar(query)) .saved_error("invalid_request")
    return(snapshot$provider$selectSavedRows("core.person.count", maxRows=1L, maxBytes=1048576L))
  }
  cursor <- NULL
  if (nzchar(query)) {
    # Native cursors use unreserved URL characters, so encodeURIComponent
    # leaves them intact. No other query keys or cursor encodings are accepted.
    if (nchar(query, type="bytes") > 8199L || !grepl("^cursor=[A-Za-z0-9_.-]+\\z", query, perl=TRUE))
      .saved_error("invalid_request")
    cursor <- substring(query, 8L)
  }
  if (key == "api/catalogue.json")
    return(snapshot$provider$listMetrics(limit=12L, cursor=cursor, maxBytes=1048576L))
  snapshot$provider$selectSavedRows(reportMetric, maxRows=12L, maxBytes=1048576L, cursor=cursor)
}
