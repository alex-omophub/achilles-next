# Real server commits, observed independently after restoring every fault seam.
testPublicationOutcomeNative<-function(details,schema,release,root,q) {
  f<-function(n)get(n,asNamespace('AchillesNext'));lit<-f('.store_literal');o<-f('.object')
  commit<-f('.store_commit');transaction<-f('.store_transaction');disconnect<-get('disconnect',asNamespace('DatabaseConnector'))
  restore<-function(){assignInNamespace('.store_commit',commit,ns='AchillesNext');assignInNamespace('.store_transaction',transaction,ns='AchillesNext');assignInNamespace('disconnect',disconnect,ns='DatabaseConnector')}
  on.exit(restore(),add=TRUE)
  policy<-list(id='fixture-outcome',revision='1',scope_kind='restricted',allow_metrics=list('core.person.count'))
  proof<-list();uuid<-'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  for(mode in c('precommit','ack_lost','disconnect','commit_sigint','return_sigint')) {
    if(.Platform$OS.type!='unix'&&grepl('sigint',mode))next
    scope<-paste0('fixture-outcome-',gsub('_','-',mode,fixed=TRUE))
    seed<-publishResultRelease(details,schema,release,file.path(root,paste0('outcome-seed-',mode)),scope,'seed',policy,function(...)TRUE,'0')
    pointer<-function()q(paste0('SELECT publication_id::text AS id,revision::text AS revision FROM ',schema,'.achillesnext_current_publication WHERE scope_id=',lit(scope)))
    pages<-function(id)q(paste0("SELECT sha256,encode(payload,'hex') AS bytes FROM ",schema,'.achillesnext_page_object WHERE publication_id=',lit(id),' ORDER BY sha256'))
    oldPointer<-pointer();oldPages<-pages(seed$publication_id);destination<-file.path(root,paste0('outcome-attempt-',mode))
    if(mode=='precommit')assignInNamespace('.store_transaction',function(details,schema,work,...)transaction(details,schema,function(tx){work(tx);stop('PRIVATE_PRECOMMIT_SQL')},...),ns='AchillesNext')
    if(mode%in%c('ack_lost','commit_sigint'))assignInNamespace('.store_commit',function(jdbc) {
      commit(jdbc)
      if(mode=='ack_lost')stop('PRIVATE_COMMIT_SQL')
      stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)
    },ns='AchillesNext')
    if(mode=='disconnect')assignInNamespace('disconnect',function(connection,...) {disconnect(connection,...);stop('PRIVATE_DISCONNECT_PATH')},ns='DatabaseConnector')
    if(mode=='return_sigint')assignInNamespace('.store_transaction',function(...) {
      value<-transaction(...);stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0);value
    },ns='AchillesNext')
    error<-tryCatch({publishResultRelease(details,schema,release,destination,scope,'attempt',policy,function(...)TRUE,'1');NULL},error=identity,interrupt=identity)
    restore()
    stopifnot(inherits(error,'condition'),!grepl('PRIVATE_',conditionMessage(error),fixed=TRUE),identical(oldPages,pages(seed$publication_id)))
    if(mode=='precommit') {
      stopifnot(identical(pointer(),oldPointer),!dir.exists(destination),conditionMessage(error)=='Result publication failed; prior current preserved')
      proof[[mode]]<-o(outcome='not_committed',prior_current_preserved=TRUE,prior_bytes_preserved=TRUE,owned_export_removed=TRUE)
    } else {
      expectedOutcome<-if(mode=='ack_lost')'unknown' else 'committed'
      stopifnot(inherits(error,'AchillesPublicationFailure'),error$outcome==expectedOutcome,
        error$reason_code==if(mode=='ack_lost')'publication.commit_unknown' else if(mode=='disconnect')'publication.cleanup_failed' else 'publication.cancelled',
        is.character(error$publication_id),length(error$publication_id)==1L,!is.na(error$publication_id),grepl(uuid,error$publication_id),
        identical(error$release_id,release),is.character(error$root_sha256),length(error$root_sha256)==1L,!is.na(error$root_sha256),grepl('^[0-9a-f]{64}$',error$root_sha256),
        is.null(error$call),is.null(error$parent),is.null(error$export_dir),dir.exists(destination))
      actualPointer<-pointer();stopifnot(nrow(actualPointer)==1L,actualPointer$ID==error$publication_id,actualPointer$REVISION=='2')
      actualPages<-pages(error$publication_id);stopifnot(nrow(actualPages)>0L)
      for(i in seq_len(nrow(actualPages))) {
        bytes<-readBin(file.path(destination,'objects',paste0(actualPages$SHA256[[i]],'.json')),'raw',n=4194305L)
        stopifnot(identical(paste(sprintf('%02x',as.integer(bytes)),collapse=''),actualPages$BYTES[[i]]))
      }
      validateResultArtifact(destination)
      pointerFile<-f('.nv_json')(readBin(file.path(destination,'publication.json'),'raw',n=262145L))
      stopifnot(pointerFile$publication_id==error$publication_id,pointerFile$root$sha256==error$root_sha256)
      if(mode=='ack_lost')stopifnot(is.null(error$publication_changed),is.null(error$current_changed)) else
        stopifnot(identical(error$publication_changed,TRUE),identical(error$current_changed,TRUE))
      proof[[mode]]<-o(outcome=error$outcome,reason_code=error$reason_code,publication_id=error$publication_id,
        root_sha256=error$root_sha256,observed_current_revision=actualPointer$REVISION,prior_bytes_preserved=TRUE,
        new_export_retained=TRUE,new_export_exact_database_bytes=TRUE,complete_artifact_admitted=TRUE)
    }
  }
  writeBin(f('.v2_bytes')(o(status='passed',cases=proof)),file.path(root,'publication-outcomes.json'))
  cat('PUBLICATION_REAL_COMMIT_ACK_LOSS_DISCONNECT_SIGINT_RETAIN_EXACT_APPROVED_EXPORTS_OK\n')
}
