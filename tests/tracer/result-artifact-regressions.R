# Rehash every ancestor after mutation: these are semantic/schema regressions,
# not checksum tests. Called with a newly generated, approved full-inventory bundle.
testArtifactRegressions <- function(bundleDir, evidenceDir) {
 ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns)
 read<-function(path)jsonlite::fromJSON(path,simplifyVector=FALSE)
 midFor<-function(mode)switch(mode,'missing-ledger'='core.execution.output_status','missing-passport'='core.source.passport','missing-summary'='core.measurement.numeric_summary',NULL)
 for(mode in c('suppressed-ledger','suppressed-ledger-row','missing-ledger','missing-passport','missing-summary','passport-source','passport-profile','passport-schema','passport-consistency','observed-records','observed-people')) {
  path<-file.path(evidenceDir,mode);stopifnot(dir.create(path));stopifnot(all(file.copy(list.files(bundleDir,full.names=TRUE),path,recursive=TRUE)))
  pointer<-read(file.path(path,'publication.json'))
  rewrite<-function(d) {
   old<-file.path(path,'objects',paste0(d$sha256,'.json'));doc<-read(old)
   if(doc$kind=='root')for(k in c('catalogue','concepts','data','terminology'))doc[[k]]<-rewrite(doc[[k]])
   if(doc$kind=='index') {
    children<-lapply(doc$children,function(child){child$object<-rewrite(child$object);if(is.null(child$object))NULL else child})
    doc$children<-Filter(Negate(is.null),children)
    if(!length(doc$children)){unlink(old);return(NULL)}
   }
   if(doc$kind=='metric_catalogue'&&!is.null(midFor(mode)))for(i in seq_along(doc$entries)) {
    e<-doc$entries[[i]]
    if(e$metric_id==midFor(mode))doc$entries[[i]]$rows<-as.character(as.integer(e$rows)-1L)
   }
   if(doc$kind=='metric_catalogue'&&mode=='suppressed-ledger')for(i in seq_along(doc$entries)) {
    if(doc$entries[[i]]$metric_id=='core.execution.output_status') {
     doc$entries[[i]]$state<-'suppressed';doc$entries[[i]]$reason_code<-'fixture.policy_suppressed'
    }
   }
   if(doc$kind=='data') {
    if(doc$metric_id=='core.execution.output_status'&&mode%in%c('suppressed-ledger','suppressed-ledger-row'))for(i in seq_along(doc$rows)) {
     if(mode=='suppressed-ledger'||doc$rows[[i]]$dimensions$metric_id=='core.person.count') {
      doc$rows[[i]]$state<-'suppressed';doc$rows[[i]]$reason_code<-'fixture.policy_suppressed';doc$rows[[i]]["values"]<-list(NULL)
     }
    }
    if(mode=='missing-ledger'&&doc$metric_id=='core.execution.output_status')doc$rows<-Filter(function(r)r$dimensions$metric_id!='core.person.count',doc$rows)
    if(mode=='missing-passport'&&doc$metric_id=='core.source.passport')doc$rows<-list()
    if(mode=='missing-summary'&&doc$metric_id=='core.measurement.numeric_summary')doc$rows<-Filter(function(r)!(r$row_kind=='summary'&&identical(r$values$n,'6')),doc$rows)
    if(startsWith(mode,'passport-')&&doc$metric_id=='core.source.passport') {
     if(mode=='passport-source')doc$rows[[1]]$values$source_id<-'fixture:other'
     if(mode=='passport-profile')doc$rows[[1]]$values$profile$id<-'other-profile'
     if(mode=='passport-schema')doc$rows[[1]]$values$observed_schema$sha256<-strrep('f',64)
     if(mode=='passport-consistency')doc$rows[[1]]$values$consistency$within_run<-'unknown'
    }
    if(doc$metric_id=='observed.condition.capture_count') {
     if(mode=='observed-records')doc$rows[[1]]$values$record_count<-'5'
     if(mode=='observed-people')doc$rows[[1]]$values$person_count<-'3'
    }
    if(!length(doc$rows)){unlink(old);return(NULL)}
   }
   n<-if(doc$kind=='root')'0' else if(doc$kind=='index')f('.nv_sum')(vapply(doc$children,function(c)c$object$rows,'')) else as.character(length(if(doc$kind=='data')doc$rows else doc$entries))
   raw<-f('.v2_bytes')(doc);nextDesc<-f('.v2_descriptor')(raw,doc$kind,n)
   if(nextDesc$sha256!=d$sha256){writeBin(raw,file.path(path,'objects',paste0(nextDesc$sha256,'.json')));unlink(old)}
   nextDesc
  }
  pointer$root<-rewrite(pointer$root);writeBin(f('.v2_bytes')(pointer),file.path(path,'publication.json'))
  message<-tryCatch({f('.v2_directory')(path);'ACCEPTED'},error=conditionMessage)
  if(mode=='suppressed-ledger'){if(message!='ACCEPTED')stop(paste('Suppressed ledger rejected:',message),call.=FALSE);next}
  expected<-if(mode=='suppressed-ledger-row')'Missing ledger entry payload' else if(mode=='missing-ledger')'Incomplete output ledger' else if(mode=='missing-passport')'Missing projected singleton' else if(mode=='missing-summary')'Missing eligible summary' else if(startsWith(mode,'passport-'))'Passport context mismatch' else 'Observed counts exceed'
  stopifnot(message!='ACCEPTED',grepl(expected,message,fixed=TRUE))
 }
 cat('PR16_REHASHED_LEDGER_PASSPORT_SUMMARY_AND_OBSERVED_REGRESSIONS_OK\n')
}
