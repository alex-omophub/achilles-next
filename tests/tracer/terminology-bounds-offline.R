# Exact terminology copy/capture byte limits, ownership and integrity without SQL.
library(AchillesNext)
local({
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');wire<-f('.v2_bytes')
  root<-tempfile('term-bounds-');stopifnot(dir.create(root,mode='0700'));on.exit(unlink(root,recursive=TRUE),add=TRUE)
  unknown<-o(state='unknown',value=NULL,basis=NULL,assertion_id=NULL,reason_code='fixture.unknown')
  stamp<-'2026-01-01T00:00:00.000Z';release<-'10000000-0000-4000-8000-000000000001'
  header<-o(contract_version='1.0.0',kind='concept_snapshot',source_id='fixture:terms',release_id=release,
    label_source=unknown,vocabulary_release=unknown,capture=o(captured_at=stamp,within_capture='single_repeatable_read',with_aggregate_release='not_asserted'))
  rows<-lapply(seq_len(220L),function(i)o(concept_tag=o(kind='id',value=as.character(i)),label=paste0('Café β ',paste(rep('x',400L),collapse='')),
    domain_id='Fixture',vocabulary_id='Synthetic',label_state='available',label_reason_code=NULL))
  payload<-c(wire(header),do.call(c,lapply(rows,wire)));path<-file.path(root,'input.jsonl');writeBin(payload,path)
  snapshot<-list(path=path,sha256=digest::digest(payload,algo='sha256',serialize=FALSE),rows=as.character(length(rows)))
  needed<-length(payload);stopifnot(needed>65536L,nchar(rows[[1]]$label,type='bytes')>nchar(rows[[1]]$label))
  baseline<-nrow(showConnections(all=TRUE));visits<-0L
  expect<-function(work,code=NULL) {
    error<-tryCatch({work();NULL},error=identity,interrupt=identity)
    stopifnot(inherits(error,'condition'),is.null(error$call),is.null(error$parent),!grepl('PRIVATE_',conditionMessage(error),fixed=TRUE))
    if(!is.null(code))stopifnot(inherits(error,'achillesnext_terminology_error'),error$code==code)
    error
  }
  # Keep private-copy directories in this attempt's test root for exact cleanup checks.
  copy<-f('.term_private_copy');scope<-new.env(parent=environment(copy));requests<-integer()
  scope$tempfile<-function(pattern,...)base::tempfile(pattern,tmpdir=root)
  scope$readBin<-function(con,what,n,...) {requests<<-c(requests,n);base::readBin(con,what,n,...)}
  environment(copy)<-scope
  parse<-f('.term_snapshot');parserScope<-new.env(parent=environment(parse));parserScope$.term_private_copy<-copy;environment(parse)<-parserScope
  visit<-function(...)visits<<-visits+1L
  for(cap in c(needed,needed+1)) {
    visits<-0L;result<-parse(snapshot,visit,maxSnapshotBytes=cap)
    stopifnot(identical(wire(result),wire(header)),visits==length(rows),all(requests<=65536L))
  }
  for(cap in c(0,needed-1)) {visits<-0L;expect(function()parse(snapshot,visit,maxSnapshotBytes=cap),'input_byte_limit');stopifnot(visits==0L)}
  bad<-snapshot;bad$sha256<-strrep('0',64);visits<-0L
  expect(function()parse(bad,visit,maxSnapshotBytes=needed),'hash_mismatch');stopifnot(visits==0L)
  # Replacement after open cannot change the already opened source descriptor.
  changed<-FALSE;old<-file.path(root,'opened-original.jsonl')
  scope$readBin<-function(con,what,n,...) {
    raw<-base::readBin(con,what,n,...)
    if(!changed){changed<<-TRUE;stopifnot(file.rename(path,old));writeBin(charToRaw('PRIVATE_REPLACEMENT'),path)}
    raw
  }
  visits<-0L;parse(snapshot,visit,maxSnapshotBytes=needed);stopifnot(changed,visits==length(rows))
  unlink(path);stopifnot(file.rename(old,path))
  # A growing source is bounded by bytes actually read, not a pre-copy stat/hash.
  changed<-FALSE
  scope$readBin<-function(con,what,n,...) {
    raw<-base::readBin(con,what,n,...)
    if(!changed){changed<<-TRUE;c<-file(path,'ab');writeBin(as.raw(rep(1L,65536L)),c);close(c)}
    raw
  }
  visits<-0L;expect(function()parse(snapshot,visit,maxSnapshotBytes=needed),'input_byte_limit');stopifnot(changed,visits==0L)
  writeBin(payload,path);scope$readBin<-base::readBin
  # Real partial writes, close warnings and hash I/O faults never reach a visitor.
  io<-f('.term_bound_io');on.exit(assignInNamespace('.term_bound_io',io,ns='AchillesNext'),add=TRUE)
  for(mode in c('partial_warning','close_warning','hash_warning','cancel')) {
    fired<-FALSE;cancelled<-FALSE;visits<-0L
    assignInNamespace('.term_bound_io',function(work) {
      symbols<-all.names(body(work))
      if(!fired&&mode=='partial_warning'&&'writeBin'%in%symbols) {
        fired<<-TRUE;return(io(function(){writeBin(head(get('raw',environment(work)),1L),get('connection',environment(work)));warning('PRIVATE_PARTIAL_WRITE')}))
      }
      value<-io(work)
      if(!fired&&((mode=='close_warning'&&'close'%in%symbols)||(mode=='hash_warning'&&'digest'%in%symbols))) {
        fired<<-TRUE;return(io(function()warning('PRIVATE_IO_WARNING')))
      }
      if(!fired&&mode=='cancel'&&'writeBin'%in%symbols){fired<<-TRUE;cancelled<<-TRUE}
      value
    },ns='AchillesNext')
    error<-expect(function()parse(snapshot,visit,cancel=function()cancelled,maxSnapshotBytes=needed),if(mode=='cancel')NULL else 'io_failure')
    assignInNamespace('.term_bound_io',io,ns='AchillesNext')
    stopifnot(fired,visits==0L,nrow(showConnections(all=TRUE))==baseline,!length(list.dirs(root,recursive=FALSE)))
    if(mode=='cancel')stopifnot(inherits(error,'achillesnext_read_error'),error$code=='aborted')
  }
  # Actual self-SIGINT after private-copy return tests the parent ownership seam.
  if(.Platform$OS.type=='unix') {
    parseSignal<-parse;signalScope<-new.env(parent=environment(parseSignal))
    signalScope$.term_private_copy<-function(...) {value<-copy(...);stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0);value}
    environment(parseSignal)<-signalScope;visits<-0L
    error<-expect(function()parseSignal(snapshot,visit,maxSnapshotBytes=needed));stopifnot(inherits(error,'interrupt'),visits==0L)
  }
  # Real SIGINT after each opened copy FD must close it and remove private state.
  if(.Platform$OS.type=='unix')for(openMode in c('rb','wb')) {
    fired<-FALSE
    scope$file<-function(description,open='',...) {
      con<-base::file(description,open,...)
      if(!fired&&identical(open,openMode)){fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)}
      con
    }
    visits<-0L;error<-expect(function()parse(snapshot,visit,maxSnapshotBytes=needed))
    stopifnot(fired,inherits(error,'interrupt'),visits==0L,nrow(showConnections(all=TRUE))==baseline,!length(list.dirs(root,recursive=FALSE)))
  }
  scope$file<-base::file
  # Actual signals in the copy loop and after closed-copy hash are delivered at
  # owned-resource checkpoints, before any parsing/visitor can begin.
  if(.Platform$OS.type=='unix')for(seam in c('chunk','hash')) {
    fired<-FALSE;readCount<-0L
    scope$readBin<-function(con,what,n,...) {
      value<-base::readBin(con,what,n,...);readCount<<-readCount+1L
      if(!fired&&seam=='chunk'){fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)}
      value
    }
    assignInNamespace('.term_bound_io',function(work) {
      value<-io(work)
      if(!fired&&seam=='hash'&&'digest'%in%all.names(body(work))){fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)}
      value
    },ns='AchillesNext')
    visits<-0L;error<-expect(function()parse(snapshot,visit,maxSnapshotBytes=needed))
    assignInNamespace('.term_bound_io',io,ns='AchillesNext')
    stopifnot(fired,inherits(error,'interrupt'),visits==0L,nrow(showConnections(all=TRUE))==baseline,!length(list.dirs(root,recursive=FALSE)))
    if(seam=='chunk')stopifnot(readCount==1L)
  }
  scope$readBin<-base::readBin
  # Capture uses the same LF-inclusive accounting and never changes descriptors.
  texts<-vapply(rows[1:3],function(row)f('.json')(row[c('concept_tag','label','domain_id','vocabulary_id')]),'')
  expected<-c(wire(header),do.call(c,lapply(rows[1:3],wire)));outputNeeded<-length(expected)
  sourceCalls<-0L;lastSql<-NULL
  capture<-captureConceptSnapshot;captureScope<-new.env(parent=environment(capture));captureScope$.stamp<-function()stamp
  captureScope$.store_transaction<-function(details,schema,work,...) {
    sourceCalls<<-sourceCalls+1L
    work(list(schema='"vocab"',stream=function(sql,visit){lastSql<<-sql;for(text in texts)visit(text)}))
  }
  environment(capture)<-captureScope
  call<-function(destination,cap=outputNeeded,...)capture(NULL,'vocab',destination,'fixture:terms',release,unknown,unknown,maxOutputBytes=cap,...)
  for(cap in c(outputNeeded,outputNeeded+1)) {
    destination<-file.path(root,paste0('capture-',cap,'.jsonl'));result<-call(destination,cap)
    stopifnot(identical(names(result),c('path','sha256','rows')),result$rows=='3',
      identical(readBin(destination,'raw',n=outputNeeded+1L),expected),result$sha256==digest::digest(expected,algo='sha256',serialize=FALSE))
    unlink(destination)
  }
  stopifnot(grepl("octet_length(convert_to(doc,'UTF8'))<=8192",lastSql,fixed=TRUE),grepl('THEN doc ELSE NULL',lastSql,fixed=TRUE))
  for(cap in c(0,length(wire(header))-1,outputNeeded-1)) {
    destination<-file.path(root,paste0('capture-fail-',cap));before<-sourceCalls
    expect(function()call(destination,cap),'output_byte_limit');stopifnot(!file.exists(destination))
    if(cap<length(wire(header)))stopifnot(sourceCalls==before)
  }
  for(value in list(NULL,NA_real_,Inf,-1,0.5,'1',c(1,2),TRUE)) {
    before<-sourceCalls;expect(function()call(file.path(root,'invalid'),value),'invalid_limit')
    expect(function()parse(snapshot,visit,maxSnapshotBytes=value),'invalid_limit');stopifnot(sourceCalls==before)
    expect(function()publishResultRelease(NULL,'results',release,file.path(root,'invalid-pub'),'scope','review',list(),function(...)TRUE,maxSnapshotBytes=value),'invalid_limit')
  }
  # The engine-side sentinel is rejected without allocating a label payload.
  oldTexts<-texts;texts<-list(NULL);expect(function()call(file.path(root,'row-overflow'),outputNeeded),'row_limit');texts<-oldTexts
  sentinel<-charToRaw('PRIVATE_FOREIGN_SENTINEL')
  destination<-file.path(root,'foreign.jsonl');writeBin(sentinel,destination);before<-sourceCalls
  expect(function()call(destination));stopifnot(sourceCalls==before,identical(readBin(destination,'raw',n=100L),sentinel));unlink(destination)
  captureScope$file.link<-function(from,to){writeBin(sentinel,to);suppressWarnings(base::file.link(from,to))}
  expect(function()call(destination),'io_failure');stopifnot(identical(readBin(destination,'raw',n=100L),sentinel));unlink(destination)
  captureScope$file.link<-base::file.link
  if(.Platform$OS.type=='unix') {
    target<-file.path(root,'absent');stopifnot(file.symlink(target,destination))
    expect(function()call(destination),'io_failure');stopifnot(identical(Sys.readlink(destination),target),!file.exists(target));unlink(destination)
    captureScope$file.link<-function(from,to) {value<-base::file.link(from,to);stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0);value}
    error<-expect(function()call(destination));stopifnot(inherits(error,'interrupt'),!file.exists(destination))
    captureScope$file.link<-base::file.link
  }
  # A foreign lock and its contents are never treated as this call's ownership.
  lock<-file.path(root,paste0('.achilles-terms-lock-',f('.hash')(file.path(normalizePath(root),basename(destination)))))
  stopifnot(dir.create(lock));writeBin(sentinel,file.path(lock,'foreign'));before<-sourceCalls
  expect(function()call(destination),'io_failure')
  stopifnot(sourceCalls==before,identical(readBin(file.path(lock,'foreign'),'raw',n=100L),sentinel));unlink(lock,recursive=TRUE)
  if(.Platform$OS.type=='unix')for(seam in c('lock','stage','open')) {
    fired<-FALSE
    captureScope$dir.create<-function(path,...) {
      value<-base::dir.create(path,...)
      wanted<-if(seam=='lock')grepl('.achilles-terms-lock-',basename(path),fixed=TRUE) else seam=='stage'&&!grepl('.achilles-terms-lock-',basename(path),fixed=TRUE)
      if(!fired&&isTRUE(value)&&wanted){fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)}
      value
    }
    captureScope$file<-function(description,open='',...) {
      con<-base::file(description,open,...)
      if(!fired&&seam=='open'&&open=='wb'){fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)}
      con
    }
    error<-expect(function()call(destination));stopifnot(fired,inherits(error,'interrupt'),!file.exists(destination),nrow(showConnections(all=TRUE))==baseline)
  }
  captureScope$dir.create<-base::dir.create;captureScope$file<-base::file
  if(.Platform$OS.type=='unix') {
    fired<-FALSE;captureScope$.store_decode<-function(text) {
      row<-f('.store_decode')(text);fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0);row
    }
    error<-expect(function()call(destination));stopifnot(fired,inherits(error,'interrupt'),!file.exists(destination),nrow(showConnections(all=TRUE))==baseline)
    rm('.store_decode',envir=captureScope)
  }
  # Descriptor construction still belongs to work: error/actual SIGINT there
  # must remove the installed owned file before successful return ownership.
  for(mode in c('error',if(.Platform$OS.type=='unix')'interrupt')) {
    fired<-FALSE
    descriptorScope<-new.env(parent=captureScope)
    descriptorScope$list<-function(...) {
      value<-base::list(...)
      if(identical(names(value),c('path','sha256','rows'))) {
        fired<<-TRUE
        if(mode=='error')stop('PRIVATE_DESCRIPTOR_FAILURE')
        stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)
      }
      value
    }
    descriptorCapture<-captureConceptSnapshot;environment(descriptorCapture)<-descriptorScope
    error<-expect(function()descriptorCapture(NULL,'vocab',destination,'fixture:terms',release,unknown,unknown,maxOutputBytes=outputNeeded),if(mode=='error')'capture_failed' else NULL)
    stopifnot(fired,!file.exists(destination),nrow(showConnections(all=TRUE))==baseline)
    if(mode=='interrupt')stopifnot(inherits(error,'interrupt'))
  }
  stopifnot(nrow(showConnections(all=TRUE))==baseline,!length(list.dirs(root,recursive=FALSE)),
    !length(Sys.glob(file.path(root,'.achilles-terms-*'))))
  cat('TERMINOLOGY_COPY_CAPTURE_EXACT_CAP_UTF8_GROWTH_REPLACEMENT_HASH_GATE_IO_CANCEL_SIGINT_FOREIGN_PATHS_OK\n')
})
