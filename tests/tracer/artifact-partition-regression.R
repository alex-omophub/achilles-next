# A real full generated export includes both all-concept and per-concept capture
# rows. Reject rehashed changes to either a partition or the all-concepts total.
testArtifactPartition<-function(bundleDir,evidenceDir) {
  f<-function(n)get(n,asNamespace('AchillesNext'))
  testArtifactGroupStreams()
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

# Core concept-first order permits streaming. For a different registered order,
# an intervening concept must not split the original subtotal. Both paths keep
# zero buckets and add decimal counts beyond the exact range of doubles.
testArtifactGroupStreams <- function() {
  f <- function(name)get(name,asNamespace("AchillesNext"))
  root <- tempfile("artifact-groups-");stopifnot(dir.create(root))
  on.exit(unlink(root,recursive=TRUE))
  tag <- function(id) list(kind="id",value=id)
  for(ordered in c(TRUE,FALSE)) {
    path <- file.path(root,as.character(ordered));stopifnot(dir.create(path))
    for(mid in c("capture","partition","missing_zero")) stopifnot(dir.create(file.path(path,mid)))
    g <- f(".artifact_groups")(path,f(".v2_scratch_budget")(),ordered,function()NULL)
    g$add("capture",tag("1"),"9007199254740993");g$add("capture",tag("2"),"0")
    g$add("partition",tag("1"),"9007199254740992")
    if(!ordered) g$add("partition",tag("2"),"0")
    g$add("partition",tag("1"),"1")
    if(ordered) g$add("partition",tag("2"),"0")
    g$add("missing_zero",tag("1"),"9007199254740993")
    g$finish()
    stopifnot(isTRUE(g$equal("capture","partition")))
    mismatch <- tryCatch({g$equal("capture","missing_zero");""},error=conditionMessage)
    stopifnot(identical(mismatch,"Projected record partition does not reconcile"))
    if(ordered) {
      stopifnot(unlink(file.path(path,"partition","totals"))==0L)
      failure <- tryCatch({g$equal("capture","partition");NULL},error=identity)
      stopifnot(inherits(failure,"achillesnext_scratch_error"),failure$code=="io_failure")
    }
  }
}
