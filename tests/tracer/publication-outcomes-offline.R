# Public publication lifecycle with real transaction control, fake JDBC payloads.
# Full approved bytes and actual server COMMIT are covered by the native fixture.
library(AchillesNext)
local({
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);o<-f('.object')
  if(!methods::isClass('AchillesPublicationTestConnection'))methods::setClass('AchillesPublicationTestConnection',slots=c(jConnection='environment'))
  prior<-list(connect=get('connect',asNamespace('DatabaseConnector')),disconnect=get('disconnect',asNamespace('DatabaseConnector')),
    jcall=get('.jcall',asNamespace('rJava')),commit=f('.store_commit'))
  on.exit({assignInNamespace('connect',prior$connect,ns='DatabaseConnector');assignInNamespace('disconnect',prior$disconnect,ns='DatabaseConnector')
    assignInNamespace('.jcall',prior$jcall,ns='rJava');assignInNamespace('.store_commit',prior$commit,ns='AchillesNext')},add=TRUE)
  root<-tempfile('publication-outcomes-');stopifnot(dir.create(root));on.exit(unlink(root,recursive=TRUE),add=TRUE)
  details<-structure(list(dbms='postgresql'),class='ConnectionDetails');release<-'10000000-0000-4000-8000-000000000001'
  modes<-c('ack_lost','before_commit','disconnect','precommit','rollback_fail','precommit_disconnect','rollback_warn','disconnect_warn','success','empty_destination_race','object_move_fail','pointer_move_fail')
  if(.Platform$OS.type=='unix')modes<-c(modes,'lock_sigint','stage_sigint','rename_sigint','commit_sigint','return_sigint','connect_sigint','destination_sigint')
  stopifnot(!anyDuplicated(modes))
  signal<-function(){stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)}
  for(mode in modes) {
    jdbc<-new.env(parent=emptyenv());connection<-methods::new('AchillesPublicationTestConnection',jConnection=jdbc)
    committed<-FALSE;disconnects<-0L;rollbacks<-0L
    assignInNamespace('connect',function(...){if(mode=='connect_sigint')signal();connection},ns='DatabaseConnector')
    assignInNamespace('disconnect',function(...) {disconnects<<-disconnects+1L;if(mode%in%c('disconnect','precommit_disconnect'))stop('PRIVATE_DISCONNECT_PATH');if(mode=='disconnect_warn')warning('PRIVATE_DISCONNECT_WARNING');invisible(NULL)},ns='DatabaseConnector')
    assignInNamespace('.jcall',function(obj,returnSig='V',method,...) {
      args<-list(...)
      if(method%in%c('createStatement','executeQuery')){if(method=='executeQuery')lastSql<<-args[[1]];v<-new.env(parent=emptyenv());v$nextRow<-TRUE;return(v)}
      if(method=='next'){v<-obj$nextRow;obj$nextRow<-FALSE;return(v)}
      if(method=='getString')return(if(grepl('SELECT sha256::text FROM',lastSql,fixed=TRUE))descriptor$sha256 else if(grepl('promote_publication',lastSql,fixed=TRUE))'1' else '10000000-0000-4000-8000-000000000002')
      if(method=='rollback'){rollbacks<<-rollbacks+1L;if(mode=='rollback_fail')stop('PRIVATE_ROLLBACK_SQL');if(mode=='rollback_warn')warning('PRIVATE_ROLLBACK_WARNING')}
      if(method=='commit'){committed<<-TRUE;return(invisible(NULL))}
      if(method%in%c('setAutoCommit','setReadOnly','setTransactionIsolation','setQueryTimeout','setFetchSize','execute','close','rollback'))return(invisible(NULL))
      stop('PRIVATE_JDBC_PATH')
    },ns='rJava')
    assignInNamespace('.store_commit',function(jdbc){if(mode=='before_commit')stop('PRIVATE_COMMIT_SQL');prior$commit(jdbc);if(mode=='ack_lost')stop('PRIVATE_COMMIT_SQL');if(mode=='commit_sigint')signal()},ns='AchillesNext')
    publish<-publishResultRelease;scope<-new.env(parent=environment(publish));lastSql<-''
    scope$.store_validation_context<-function(...)list(context=list(state='validated',source_id='fixture:outcome',content_revision='1',profile_sha256=strrep('a',64)))
    admitted<-o(contract_version='2.0.0');raw<-f('.v2_bytes')(admitted)
    mockPointer<-NULL
    descriptor<-o(sha256=f('.v2_hash')(raw),bytes=as.character(length(raw)),kind='root',rows='0')
    scope$.store_build_pages<-function(tx,validated,publicationId,scopeId,approvalId,policy,directory,...) {
      buildCalls<<-buildCalls+1L
      writeBin(raw,file.path(directory,'objects',paste0(descriptor$sha256,'.json')))
      mockPointer<<-f('.v2_bytes')(o(contract_version='2.0.0',publication_id=publicationId,source_id='fixture:outcome',access_scope_id=scopeId,root=descriptor))
      writeBin(mockPointer,file.path(directory,'publication.json'));descriptor
    }
    scope$.v2_directory<-function(directory,visit=function(...)NULL,...) {visit(descriptor,raw);admitted}
    scope$.publication_pages<-function(directory,root,pointer,visit,check){check();visit(descriptor,raw)}
    environment(publish)<-scope
    foreignCreated<-FALSE
    moveAttempts<-c(object=0L,pointer=0L);moveSuccesses<-moveAttempts;moveFailures<-moveAttempts
    transactionCalls<-0L;buildCalls<-0L
    reserveForeign<-function() {
      stopifnot(base::dir.create(destination,mode='0711'),isTRUE(Sys.chmod(destination,'0711')))
      foreignCreated<<-TRUE
    }
    scope$dir.create<-function(path,...) {
      if(mode=='empty_destination_race'&&identical(path,destination)&&!foreignCreated)reserveForeign()
      made<-base::dir.create(path,...)
      if(made&&mode=='destination_sigint'&&identical(path,destination))signal()
      if(made&&((mode=='lock_sigint'&&startsWith(basename(path),'.achilles-export-lock-'))||
        (mode=='stage_sigint'&&startsWith(basename(path),'.achilles-export-')&&!startsWith(basename(path),'.achilles-export-lock-'))))signal()
      made
    }
    scope$file.rename<-function(from,to) {
      # Old code checked absence before entering this rename. Insert an EMPTY
      # foreign directory at that exact seam; POSIX rename would replace it.
      if(mode=='empty_destination_race'&&identical(to,destination)&&!foreignCreated)reserveForeign()
      objectMove<-identical(dirname(to),file.path(destination,'objects'))
      pointerMove<-identical(to,file.path(destination,'publication.json'))
      kind<-if(objectMove)'object' else if(pointerMove)'pointer' else NULL
      if(!is.null(kind))moveAttempts[[kind]]<<-moveAttempts[[kind]]+1L
      if(objectMove)stopifnot(!file.exists(file.path(destination,'publication.json')))
      if(pointerMove)stopifnot(file.exists(file.path(destination,'objects',paste0(descriptor$sha256,'.json'))),!file.exists(to))
      if((mode=='object_move_fail'&&objectMove)||(mode=='pointer_move_fail'&&pointerMove)) {
        moveFailures[[kind]]<<-moveFailures[[kind]]+1L
        return(FALSE)
      }
      moved<-base::file.rename(from,to)
      if(moved&&!is.null(kind))moveSuccesses[[kind]]<<-moveSuccesses[[kind]]+1L
      if(moved&&mode=='rename_sigint')signal();moved
    }
    scope$.store_transaction<-function(...) {transactionCalls<<-transactionCalls+1L;value<-f('.store_transaction')(...);if(mode=='return_sigint')signal();value}
    destination<-file.path(normalizePath(root,mustWork=TRUE),mode)
    error<-tryCatch({publish(details,'results',release,destination,'scope','approval',
      list(),function(...)!mode%in%c('precommit','rollback_fail','precommit_disconnect','rollback_warn'),'0')},error=identity,interrupt=identity)
    if(mode=='empty_destination_race') {
      stopifnot(foreignCreated)
      if(!inherits(error,'error')||committed||!dir.exists(destination)||length(list.files(destination,all.files=TRUE,no..=TRUE)))
        stop('Foreign empty destination was clobbered',call.=FALSE)
      stopifnot(foreignCreated,identical(as.character(file.info(destination)$mode),'711'),disconnects==1L,rollbacks==1L)
      unlink(destination,recursive=TRUE)
      stopifnot(!length(Sys.glob(file.path(root,'.achilles-export*'))))
      next
    }
    retained<-mode%in%c('ack_lost','before_commit','disconnect','disconnect_warn','commit_sigint','return_sigint','success')
    if(mode=='success')stopifnot(!inherits(error,'condition'),committed,dir.exists(destination)) else {
      stopifnot(inherits(error,'condition'),!grepl('PRIVATE_',conditionMessage(error),fixed=TRUE),is.null(error$call),is.null(error$parent))
      if(mode%in%c('ack_lost','before_commit','disconnect','commit_sigint','return_sigint','rollback_fail','rollback_warn','precommit_disconnect','disconnect_warn',
        'lock_sigint','stage_sigint','rename_sigint','connect_sigint','destination_sigint')) {
        stopifnot(inherits(error,'AchillesPublicationFailure'),
          error$outcome==if(mode%in%c('ack_lost','before_commit'))'unknown' else if(committed)'committed' else 'not_committed',
          error$reason_code==if(mode%in%c('ack_lost','before_commit'))'publication.commit_unknown' else
            if(mode%in%c('disconnect','rollback_fail','rollback_warn','precommit_disconnect','disconnect_warn'))'publication.cleanup_failed' else 'publication.cancelled')
        for(key in c('publication_id','release_id'))stopifnot(is.character(error[[key]]),length(error[[key]])==1L,!is.na(error[[key]]),
          grepl('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',error[[key]]))
        if(retained)stopifnot(is.character(error$root_sha256),length(error$root_sha256)==1L,!is.na(error$root_sha256),grepl('^[0-9a-f]{64}$',error$root_sha256),error$root_sha256==descriptor$sha256,is.null(error$export_dir))
        if(error$outcome=='unknown')stopifnot(is.null(error$publication_changed),is.null(error$current_changed)) else
          stopifnot(identical(error$publication_changed,committed),identical(error$current_changed,committed))
      }
    }
    stopifnot(identical(dir.exists(destination),retained),disconnects==if(mode%in%c('lock_sigint','stage_sigint'))0L else 1L)
    if(retained)stopifnot(identical(readBin(file.path(destination,'publication.json'),'raw',n=262144L),mockPointer))
    if(mode%in%c('object_move_fail','pointer_move_fail')) {
      stopifnot(transactionCalls==1L,buildCalls==1L,!committed,rollbacks==1L,
        identical(conditionMessage(error),'Result publication failed; prior current preserved'))
      if(mode=='object_move_fail')stopifnot(identical(moveAttempts,c(object=1L,pointer=0L)),
        identical(moveSuccesses,c(object=0L,pointer=0L)),identical(moveFailures,c(object=1L,pointer=0L))) else
        stopifnot(identical(moveAttempts,c(object=1L,pointer=1L)),
          identical(moveSuccesses,c(object=1L,pointer=0L)),identical(moveFailures,c(object=0L,pointer=1L)))
    }
    if(mode%in%c('rollback_fail','rollback_warn'))stopifnot(error$rollback_state=='unconfirmed')
    if(mode%in%c('precommit_disconnect','disconnect_warn'))stopifnot(error$disconnect_state=='unconfirmed')
    stopifnot(!length(Sys.glob(file.path(root,'.achilles-export*'))))

  }
  # Foreign paths never become this attempt's property, including a destination
  # created after the first check while our own lock is being acquired.
  connections<-0L
  assignInNamespace('connect',function(...){connections<<-connections+1L;stop('PRIVATE_FOREIGN_CONNECTION')},ns='DatabaseConnector')
  sentinel<-charToRaw('foreign-owned sentinel')
  for(seam in c('existing_lock','existing_destination','late_destination')) {
    destination<-file.path(normalizePath(root,mustWork=TRUE),paste0('foreign-',seam))
    lock<-file.path(dirname(destination),paste0('.achilles-export-lock-',f('.hash')(destination)))
    foreign<-if(seam=='existing_lock')lock else destination
    if(seam!='late_destination') {
      stopifnot(dir.create(foreign,mode='0700'));writeBin(sentinel,file.path(foreign,'sentinel.bin'))
    }
    public<-publishResultRelease
    if(seam=='late_destination') {
      scope<-new.env(parent=environment(public))
      scope$dir.create<-function(path,...) {
        made<-base::dir.create(path,...)
        if(made&&identical(path,lock)) {
          stopifnot(base::dir.create(destination,mode='0700'))
          writeBin(sentinel,file.path(destination,'sentinel.bin'))
        }
        made
      }
      environment(public)<-scope
    }
    failure<-tryCatch({public(details,'results',release,destination,'scope','approval',list(),function(...)TRUE,'0');NULL},error=identity)
    stopifnot(inherits(failure,'error'),connections==0L,dir.exists(foreign),
      identical(list.files(foreign,all.files=TRUE,no..=TRUE),'sentinel.bin'),
      identical(readBin(file.path(foreign,'sentinel.bin'),'raw',n=1024L),sentinel))
    if(seam=='existing_lock')stopifnot(!file.exists(destination)) else stopifnot(!file.exists(lock))
    unlink(foreign,recursive=TRUE)
    stopifnot(!length(Sys.glob(file.path(root,'.achilles-export*'))))
  }
  cat('PUBLICATION_FOREIGN_LOCK_DESTINATION_SENTINELS_ZERO_CONNECTIONS_OWN_LOCK_CLEANUP_OK\n')
  cat('PUBLICATION_PURE_UNIQUE_MODES ',length(modes),' FOREIGN_GUARDS 3\n',sep='')
  cat('PUBLICATION_REAL_TRANSACTION_CONTROL_ACK_DISCONNECT_PRECOMMIT_OUTCOMES_OK\n')
})
