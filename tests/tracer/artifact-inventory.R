# Rehash the mutated root and pointer so rejection tests type semantics, not bytes.
testArtifactInventory <- function(bundleDir,evidenceDir) {
  ns <- asNamespace("AchillesNext");f <- function(n)get(n,ns)
  validateResultArtifact(bundleDir)
  pointer <- jsonlite::fromJSON(file.path(bundleDir,"publication.json"),simplifyVector=FALSE)
  root <- f(".nv_json")(readBin(file.path(bundleDir,"objects",paste0(pointer$root$sha256,".json")),"raw",n=262145L))
  n <- as.integer(root$expected_metric_count)
  for(value in list(n,as.list(root$expected_metric_count),NULL)) {
    path <- tempfile("inventory-",tmpdir=evidenceDir);stopifnot(dir.create(path))
    stopifnot(all(file.copy(list.files(bundleDir,full.names=TRUE),path,recursive=TRUE)))
    changed <- root;changed["expected_metric_count"] <- list(value)
    bytes <- f(".v2_bytes")(changed);nextPointer <- pointer
    nextPointer$root <- f(".v2_descriptor")(bytes,"root","0")
    unlink(file.path(path,"objects",paste0(pointer$root$sha256,".json")))
    writeBin(bytes,file.path(path,"objects",paste0(nextPointer$root$sha256,".json")))
    writeBin(f(".v2_bytes")(nextPointer),file.path(path,"publication.json"))
    message <- tryCatch({f(".v2_directory")(path);"ACCEPTED"},error=conditionMessage)
    stopifnot(identical(message,"Invalid expected metric count"))
  }
  cat("REHASHED_ARTIFACT_INVENTORY_REQUIRES_EXACT_STRING_OK\n")
}
