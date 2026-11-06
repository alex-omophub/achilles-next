# A real full generated export includes both all-concept and per-concept capture
# rows. Accept those, but reject a rehashed per-concept partition count change.
testArtifactPartition<-function(bundleDir,evidenceDir) {
  f<-function(n)get(n,asNamespace('AchillesNext'))
  validateResultArtifact(bundleDir)
  path<-file.path(evidenceDir,'wrong-record-partition');stopifnot(dir.create(path))
  stopifnot(all(file.copy(list.files(bundleDir,full.names=TRUE),path,recursive=TRUE)))
  pointer<-jsonlite::fromJSON(file.path(path,'publication.json'),simplifyVector=FALSE)
  changed<-FALSE
  rewrite<-function(d) {
    old<-file.path(path,'objects',paste0(d$sha256,'.json'))
    doc<-jsonlite::fromJSON(old,simplifyVector=FALSE)
    if(doc$kind=='root')for(k in c('catalogue','data','concepts','terminology'))doc[[k]]<-rewrite(doc[[k]])
    if(doc$kind=='index')for(i in seq_along(doc$children))doc$children[[i]]$object<-rewrite(doc$children[[i]]$object)
    if(doc$kind=='data' && doc$metric_id=='core.condition.source_count' && !changed) {
      doc$rows[[1]]$values$record_count<-f('.nv_add')(doc$rows[[1]]$values$record_count,'1');changed<<-TRUE
    }
    raw<-f('.v2_bytes')(doc);nextDescriptor<-f('.v2_descriptor')(raw,d$kind,d$rows)
    if(nextDescriptor$sha256!=d$sha256){writeBin(raw,file.path(path,'objects',paste0(nextDescriptor$sha256,'.json')));unlink(old)}
    nextDescriptor
  }
  pointer$root<-rewrite(pointer$root);stopifnot(changed)
  writeBin(f('.v2_bytes')(pointer),file.path(path,'publication.json'))
  message<-tryCatch({f('.v2_directory')(path);'ACCEPTED'},error=conditionMessage)
  stopifnot(message=='Projected record partition does not reconcile')
  cat('FULL_SCOPE_ALL_BUCKET_ACCEPTED_REHASHED_PARTITION_MISMATCH_REJECTED_OK\n')
}
