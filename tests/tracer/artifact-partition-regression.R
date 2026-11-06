# A real full generated export includes both all-concept and per-concept capture
# rows. Reject rehashed changes to either a partition or the all-concepts total.
testArtifactPartition<-function(bundleDir,evidenceDir) {
  f<-function(n)get(n,asNamespace('AchillesNext'))
  validateResultArtifact(bundleDir)
  for(mode in c('record-partition','capture-total')) {
    path<-file.path(evidenceDir,paste0('wrong-',mode));stopifnot(dir.create(path))
    stopifnot(all(file.copy(list.files(bundleDir,full.names=TRUE),path,recursive=TRUE)))
    pointer<-jsonlite::fromJSON(file.path(path,'publication.json'),simplifyVector=FALSE)
    changed<-FALSE
    rewrite<-function(d) {
      old<-file.path(path,'objects',paste0(d$sha256,'.json'))
      doc<-jsonlite::fromJSON(old,simplifyVector=FALSE)
      if(doc$kind=='root')for(k in c('catalogue','data','concepts','terminology'))doc[[k]]<-rewrite(doc[[k]])
      if(doc$kind=='index')for(i in seq_along(doc$children))doc$children[[i]]$object<-rewrite(doc$children[[i]]$object)
      if(mode=='record-partition' && doc$kind=='data' && doc$metric_id=='core.condition.source_count' && !changed) {
        doc$rows[[1]]$values$record_count<-f('.nv_add')(doc$rows[[1]]$values$record_count,'1');changed<<-TRUE
      }
      if(mode=='capture-total' && doc$kind=='data' && doc$metric_id=='core.condition.capture_count' && !changed) {
        for(i in seq_along(doc$rows))if(doc$rows[[i]]$dimensions$period_kind=='full_scope' && doc$rows[[i]]$dimensions$concept_tag$kind=='all') {
          doc$rows[[i]]$values$record_count<-f('.nv_add')(doc$rows[[i]]$values$record_count,'1');changed<<-TRUE;break
        }
      }
      raw<-f('.v2_bytes')(doc);nextDescriptor<-f('.v2_descriptor')(raw,d$kind,d$rows)
      if(nextDescriptor$sha256!=d$sha256){writeBin(raw,file.path(path,'objects',paste0(nextDescriptor$sha256,'.json')));unlink(old)}
      nextDescriptor
    }
    pointer$root<-rewrite(pointer$root);stopifnot(changed)
    writeBin(f('.v2_bytes')(pointer),file.path(path,'publication.json'))
    message<-tryCatch({f('.v2_directory')(path);'ACCEPTED'},error=conditionMessage)
    stopifnot(message==if(mode=='record-partition')'Projected record partition does not reconcile' else 'Projected all-concepts record total does not reconcile')
  }
  cat('FULL_SCOPE_ALL_BUCKET_ACCEPTED_REHASHED_PARTITION_AND_TOTAL_MISMATCHES_REJECTED_OK\n')
}
