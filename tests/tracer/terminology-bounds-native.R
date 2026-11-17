# Tiny real-vocabulary quota proof reused by the existing 2.1 serving fixture.
testTerminologyBoundsIntegration <- function(details,schema,release,root,policy,q,ex,vocab,snapshot) {
  f<-function(n)get(n,asNamespace('AchillesNext'));lit<-f('.store_literal')
  header<-f('.term_snapshot')(snapshot,function(...)NULL)
  size<-file.info(snapshot$path)$size;bytes<-readBin(snapshot$path,'raw',n=size+1)
  stamp<-f('.stamp');on.exit(assignInNamespace('.stamp',stamp,ns='AchillesNext'),add=TRUE)
  assignInNamespace('.stamp',function()header$capture$captured_at,ns='AchillesNext')
  fail<-function(work,code) {
    error<-tryCatch({work();NULL},error=identity)
    stopifnot(inherits(error,'achillesnext_terminology_error'),identical(error$code,code),
      is.null(error$call),is.null(error$parent),!grepl(root,conditionMessage(error),fixed=TRUE),
      !grepl('PRIVATE_',conditionMessage(error),fixed=TRUE))
  }
  capture<-function(path,cap)captureConceptSnapshot(details,vocab,path,header$source_id,release,
    header$label_source,header$vocabulary_release,maxOutputBytes=cap)
  for(cap in c(size,size+1)) {
    path<-file.path(root,paste0('bounded-capture-',cap,'.jsonl'));got<-capture(path,cap)
    stopifnot(identical(names(got),c('path','sha256','rows')),got$sha256==snapshot$sha256,got$rows==snapshot$rows,
      identical(readBin(path,'raw',n=size+1),bytes));unlink(path)
  }
  for(cap in c(0,size-1)) {
    path<-file.path(root,paste0('bounded-capture-fail-',cap));fail(function()capture(path,cap),'output_byte_limit')
    stopifnot(!file.exists(path))
  }
  # Real SQL replaces an oversized Unicode document before JDBC retrieval.
  ex(paste0('INSERT INTO ',vocab,".concept VALUES (99999,repeat('β',5000),'Synthetic','Fixture')"))
  removed<-FALSE;on.exit(if(!removed)ex(paste0('DELETE FROM ',vocab,'.concept WHERE concept_id=99999')),add=TRUE)
  path<-file.path(root,'bounded-capture-utf8');fail(function()capture(path,size+65536),'row_limit')
  stopifnot(!file.exists(path));ex(paste0('DELETE FROM ',vocab,'.concept WHERE concept_id=99999'));removed<-TRUE
  # Successful exact and +1 input budgets retain the unchanged 2.1 wire.
  for(cap in c(size,size+1)) {
    approved<-0L;path<-file.path(root,paste0('bounded-snapshot-',cap))
    result<-publishResultRelease(details,schema,release,path,'fixture-bounded-labels','review-bounded-terms',policy,
      function(candidate){approved<<-approved+1L;stopifnot(candidate$contract_version=='2.1.0',candidate$saved_terminology$snapshot_sha256==snapshot$sha256);TRUE},
      savedTerminology=snapshot,maxSnapshotBytes=cap)
    stopifnot(approved==1L);validateResultArtifact(result$export_dir)
  }
  before<-q(paste0('SELECT publication_id::text AS id FROM ',schema,'.achillesnext_current_publication'))
  counts<-function()q(paste0('SELECT (SELECT count(*)::text FROM ',schema,'.achillesnext_publication) AS publications,',
    '(SELECT count(*)::text FROM ',schema,'.achillesnext_page_object) AS pages'))
  prior<-counts()
  for(cap in c(0,size-1)) {
    approved<-0L;path<-file.path(root,paste0('bounded-snapshot-fail-',cap))
    fail(function()publishResultRelease(details,schema,release,path,'fixture-restricted','review-bounded-terms',policy,
      function(candidate){approved<<-approved+1L;TRUE},expectedRevision='1',savedTerminology=snapshot,maxSnapshotBytes=cap),'input_byte_limit')
    stopifnot(approved==0L,!dir.exists(path),identical(counts(),prior),
      identical(q(paste0('SELECT publication_id::text AS id FROM ',schema,'.achillesnext_current_publication')),before))
  }
  validateResultArtifact(file.path(root,'restricted'))
  cat('TERMINOLOGY_NATIVE_EXACT_PLUS_ONE_INPUT_OUTPUT_ZERO_MINUS_ONE_UTF8_SENTINEL_21_ADMISSION_PRIOR_PRESERVATION_OK\n')
}
