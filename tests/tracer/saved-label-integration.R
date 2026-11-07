testSavedLabelIntegration <- function(details,schema,serve,release,root,policy,readDetails,role,ex,q) {
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');wire<-f('.v2_bytes');lit<-f('.store_literal')
  vocab<-paste0('term_vocab_',Sys.getpid());ex(paste0('CREATE SCHEMA ',vocab,'; CREATE TABLE ',vocab,'.concept(concept_id numeric,concept_name text,domain_id text,vocabulary_id text)'))
  on.exit(ex(paste0('DROP SCHEMA ',vocab,' CASCADE')),add=TRUE)
  label<-paste0('Diabetes ',paste(rep('x',400L),collapse=''))
  ex(paste0('INSERT INTO ',vocab,'.concept VALUES (0,',lit(label),",'Synthetic','Fixture'),(123,",lit(label),",'Condition','Fixture'),",
    '(456,',lit(paste0(label,' mellitus')) ,",'Unit','Fixture'),(777,NULL,'Unit','Fixture'),(1,",lit(paste0(label,' β blocker')),
    ",'Synthetic','Fixture'),(999,'Hidden outside scope','Synthetic','Fixture')"))
  known<-function(value)o(state='known',value=value,basis='synthetic-capture',assertion_id='fixture-assertion',reason_code=NULL)
  snapshot<-captureConceptSnapshot(details,vocab,file.path(root,'vocabulary.jsonl'),'fixture:export',release,known('fixture:vocabulary'),known('fixture-v1'))
  stopifnot(snapshot$rows=='6')
  fail<-function(work)stopifnot(tryCatch({work();FALSE},error=function(e)TRUE))
  before<-q(paste0('SELECT publication_id::text AS id FROM ',schema,'.achillesnext_current_publication'))$ID
  # A base2.0.0 store cannot silently publish the new format.
  fail(function()publishResultRelease(details,schema,release,file.path(root,'not-enabled'),'fixture-restricted','review-terms',policy,function(c)TRUE,savedTerminology=snapshot))
  stopifnot(!dir.exists(file.path(root,'not-enabled')))
  # Extension DDL and guard replacement roll back together on commit failure.
  commit<-f('.store_commit');on.exit(assignInNamespace('.store_commit',commit,ns='AchillesNext'),add=TRUE)
  assignInNamespace('.store_commit',function(jdbc)stop('synthetic precommit failure'),ns='AchillesNext')
  fail(function()enableSavedTerminology(details,schema));assignInNamespace('.store_commit',commit,ns='AchillesNext')
  stopifnot(is.na(q(paste0("SELECT to_regclass('",schema,".achillesnext_storage_extension')::text AS name"))$NAME))
  stopifnot(isTRUE(enableSavedTerminology(details,schema)),identical(enableSavedTerminology(details,schema),FALSE),inspectResultStore(details,schema)$storage_version=='2.0.0')
  ex(paste0('INSERT INTO ',vocab,".concept VALUES (123,'Conflicting name','Condition','Fixture')"))
  fail(function()captureConceptSnapshot(details,vocab,file.path(root,'duplicate.jsonl'),'fixture:export',release,known('fixture:vocabulary'),known('fixture-v1')))
  stopifnot(!file.exists(file.path(root,'duplicate.jsonl')))
  ex(paste0('DELETE FROM ',vocab,".concept WHERE concept_name='Conflicting name'"))
  fail(function()captureConceptSnapshot(details,vocab,file.path(root,'cancelled.jsonl'),'fixture:export',release,known('fixture:vocabulary'),known('fixture-v1'),cancel=function()TRUE))
  stopifnot(!file.exists(file.path(root,'cancelled.jsonl')))
  approved<-publishResultRelease(details,schema,release,file.path(root,'labelled'),'fixture-labelled','review-terms',policy,function(c) {
    stopifnot(c$contract_version=='2.1.0',c$saved_terminology$snapshot_sha256==snapshot$sha256);TRUE
  },savedTerminology=snapshot)
  validateResultArtifact(approved$export_dir)
  rootDoc<-f('.nv_json')(readBin(file.path(approved$export_dir,'objects',paste0(approved$root$sha256,'.json')),'raw',n=262145L))
  context<-c(rootDoc[f('.saved_common')()],o(root=approved$root,authorization_epoch='1',instance_id='labelled-fixture'))
  ex(paste0('INSERT INTO ',schema,".achillesnext_audience_grant VALUES ('fixture-labelled',",lit(role),",true)"))
  file<-openArtifactResultProvider(approved$export_dir,context,function(c)TRUE)
  db<-openDatabaseResultProvider(readDetails,serve,context,function(c)TRUE);on.exit({file$close();db$close()},add=TRUE)
  # Observe real adapter statements, without changing them or using source access.
  original<-f('.store_transaction');statements<-character();ns<-asNamespace('AchillesNext')
  observe<-function(details,schema,work,...)original(details,schema,function(tx) {
    one<-tx$one;tx$one<-function(sql){statements<<-c(statements,sql);one(sql)};work(tx)
  },...)
  unlockBinding('.store_transaction',ns);assign('.store_transaction',observe,ns);lockBinding('.store_transaction',ns)
  on.exit({unlockBinding('.store_transaction',ns);assign('.store_transaction',original,ns);lockBinding('.store_transaction',ns)},add=TRUE)
  same<-function(a,b){a$cursor<-b$cursor<-NULL;a$budget<-b$budget<-NULL;stopifnot(identical(wire(a),wire(b)))}
  a<-file$lookupConcepts(c('0','123','456','777','999'));b<-db$lookupConcepts(c('0','123','456','777','999'));same(a,b)
  stopifnot(a$concepts[[4]]$label_reason_code=='terminology.missing_label',a$concepts[[5]]$state=='not_saved',
    a$terminology$label_source$state=='known',a$terminology$vocabulary_release$value=='fixture-v1',
    a$terminology$capture$with_aggregate_release=='not_asserted')
  collect<-function(limit=25L,maxBytes=1048576L) {
    left<-right<-NULL;ids<-character();pages<-0L
    repeat {
      a<-file$searchConcepts('DIAB',limit=limit,maxBytes=maxBytes,cursor=left)
      b<-db$searchConcepts('DIAB',limit=limit,maxBytes=maxBytes,cursor=right);same(a,b)
      stopifnot(length(wire(a))<=maxBytes,length(wire(b))<=maxBytes,a$searched)
      ids<-c(ids,vapply(a$concepts,function(e)e$concept_tag$value,''));pages<-pages+1L
      if(a$complete)break
      left<-a$cursor;right<-b$cursor
    }
    stopifnot(identical(ids,c('0','123','456','1')));pages
  }
  stopifnot(collect(limit=1L)==4L)
  byteLimit<-length(wire(file$searchConcepts('DIAB',limit=1L)))+64L
  stopifnot(collect(maxBytes=byteLimit)>1L)
  for(query in c('β b','Hidden outside scope',"%'; SELECT * FROM person; --",'missing'))same(file$searchConcepts(query),db$searchConcepts(query))
  same(file$listMetrics(limit=3L),db$listMetrics(limit=3L))
  same(file$selectSavedRows('core.measurement.numeric_summary'),db$selectSavedRows('core.measurement.numeric_summary'))
  # Every object is stored/exported without serialization changes.
  f('.v2_directory')(approved$export_dir,function(d,bytes)stopifnot(identical(bytes,readResultObject(readDetails,serve,'fixture:export',approved$publication_id,'fixture-labelled',approved$root$sha256,if(d$kind=='root')NULL else d))))
  # Change only the DB grant; host callback and provider remain unchanged.
  ex(paste0('UPDATE ',schema,".achillesnext_audience_grant SET enabled=false WHERE scope_id='fixture-labelled' AND database_role=",lit(role)))
  for(work in list(function()db$searchConcepts('DIAB'),function()db$lookupConcepts('123'))) {
    e<-tryCatch({work();NULL},error=identity);stopifnot(inherits(e,'achillesnext_read_error'),e$code=='unavailable')
  }
  stopifnot(file$searchConcepts('DIAB')$state=='available',db$inspect()$cache_bytes==0L,
    all(grepl(paste0(' FROM "',serve,'".achillesnext_approved_pages WHERE '),statements,fixed=TRUE)),
    !any(grepl('achillesnext_approved_current|achillesnext_aggregate_cell|[.]concept ',statements)))
  # Restore the observer before producer/migration assertions.
  unlockBinding('.store_transaction',ns);assign('.store_transaction',original,ns);lockBinding('.store_transaction',ns)
  restricted<-policy;restricted$allow_metrics<-as.list(c('core.person.count','core.person.gender_count'))
  reduced<-publishResultRelease(details,schema,release,file.path(root,'labels-reduced'),'fixture-person','review-reduced',restricted,function(c)TRUE,savedTerminology=snapshot)
  doc<-f('.nv_json')(readBin(file.path(reduced$export_dir,'objects',paste0(reduced$root$sha256,'.json')),'raw',n=262145L))
  ctx<-c(doc[f('.saved_common')()],o(root=reduced$root,authorization_epoch='1',instance_id='reduced-labels'))
  p<-openArtifactResultProvider(reduced$export_dir,ctx,function(c)TRUE);on.exit(p$close(),add=TRUE)
  stopifnot(length(p$searchConcepts('diab')$concepts)==1L,p$lookupConcepts('123')$concepts[[1]]$state=='not_saved')
  cancelled<-FALSE
  fail(function()publishResultRelease(details,schema,release,file.path(root,'labels-cancelled'),'fixture-restricted','review-cancel',policy,
    function(c){cancelled<<-TRUE;TRUE},expectedRevision='1',savedTerminology=snapshot,cancel=function()cancelled))
  bad<-snapshot;bad$sha256<-strrep('0',64)
  fail(function()publishResultRelease(details,schema,release,file.path(root,'labels-bad-hash'),'fixture-restricted','review-bad',policy,function(c)TRUE,expectedRevision='1',savedTerminology=bad))
  fail(function()publishResultRelease(details,schema,release,file.path(root,'labels-denied'),'fixture-restricted','review-denied',policy,function(c)FALSE,expectedRevision='1',savedTerminology=snapshot))
  stopifnot(!dir.exists(file.path(root,'labels-cancelled')),!dir.exists(file.path(root,'labels-bad-hash')),!dir.exists(file.path(root,'labels-denied')),
    identical(q(paste0('SELECT publication_id::text AS id FROM ',schema,'.achillesnext_current_publication'))$ID,before))
  validateResultArtifact(file.path(root,'restricted'))
  cat('SAVED_LABEL_REAL_CAPTURE_EXTENSION_ROLLBACK_IDEMPOTENCE_PROJECTION_BOTH_MODES_PREFIX_BYTE_PAGES_EXACT_BYTES_SCOPE_REVOCATION_FAILURE_PRESERVATION_OK statements=',length(statements),'\n')
}
