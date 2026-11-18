# Exact disk lookup, growth/collisions, markers and cleanup without a row map.
library(AchillesNext)
local({
  path<-tempfile('validation-spool-test-');spool<-get('.v2_spool',asNamespace('AchillesNext'))(path)
  on.exit({spool$close();unlink(path,recursive=TRUE)})
  hash<-function(i)digest::digest(as.character(i),algo='sha256',serialize=FALSE)
  # More than half the initial slot count forces a rehash; include empty values.
  for(i in 1:1100)spool$put(hash(i),if(i==1L)raw() else charToRaw(paste0('value-',i)))
  for(i in c(1L,2L,511L,512L,1024L,1100L))stopifnot(identical(spool$get(hash(i)),if(i==1L)raw() else charToRaw(paste0('value-',i))))
  stopifnot(spool$inspect()$slots==4096,spool$inspect()$entries==1100,
    is.null(spool$get(hash('missing'))),!spool$has(hash('missing')))
  for(i in 1:24)spool$put(sprintf('%064x',i),charToRaw(as.character(i)))
  for(i in 1:24)stopifnot(rawToChar(spool$get(sprintf('%064x',i)))==as.character(i))
  stopifnot(spool$flags(hash(2),1L),!spool$flags(hash(2),1L),spool$flags(hash(2),2L),spool$flags(hash(2))==3L)
  seen<-0L;spool$walk(function(key,value){seen<<-seen+1L;stopifnot(identical(spool$get(key),value))})
  stopifnot(seen==1124L,length(list.files(path))==2L)
  fail<-function(work,message){e<-tryCatch({work();NULL},error=identity);stopifnot(inherits(e,'error'),identical(conditionMessage(e),message))}
  fail(function()spool$put(hash(2),raw()),'Duplicate validation key')
  fail(function()spool$get('not-a-hash'),'Invalid validation key')
  fail(function()spool$put(hash('large'),raw(131073L)),'Validation value byte limit')
  spool$close();spool$close();fail(function()spool$get(hash(1)),'Validation spool is closed')
  # Cancellation during rehash removes the replacement file and leaves the
  # original map readable, with no partly inserted value or marker loss.
  path2<-tempfile('validation-spool-cancel-');abort<-FALSE
  pending<-get('.v2_spool',asNamespace('AchillesNext'))(path2,function(){if(abort)stop('rehash cancelled',call.=FALSE)})
  on.exit({pending$close();unlink(path2,recursive=TRUE)},add=TRUE)
  for(i in 1:512)pending$put(hash(i),charToRaw(as.character(i)))
  pending$flags(hash(1),2L);abort<-TRUE
  fail(function()pending$put(hash(513),charToRaw('513')),'rehash cancelled')
  stopifnot(pending$inspect()$slots==1024,pending$inspect()$entries==512,
    !pending$has(hash(513)),pending$flags(hash(1))==2L,length(list.files(path2))==2L)
  abort<-FALSE;pending$put(hash(513),charToRaw('513'))
  stopifnot(rawToChar(pending$get(hash(513)))=='513',pending$flags(hash(1))==2L)
  cat('VALIDATION_DISK_SPOOL_COLLISIONS_REHASH_FLAGS_EMPTY_VALUES_WALK_BOUNDS_OK\n')
})

# Linear probes cross a replacement-page edge in both halves and wrap at the end.
local({
  path<-tempfile('validation-page-boundary-')
  spool<-get('.v2_spool',asNamespace('AchillesNext'))(path)
  on.exit({spool$close();unlink(path,recursive=TRUE)})
  keys<-vapply(seq_len(1025L),function(i)digest::digest(as.character(i),algo='sha256',serialize=FALSE),'')
  homes<-rep(c(1022L,2046L,3070L,4094L),each=8L)
  substr(keys[seq_along(homes)],1L,8L)<-sprintf('%08x',homes)
  for(i in seq_len(1024L))spool$put(keys[i],charToRaw(as.character(i)))
  for(i in seq_along(homes))stopifnot(spool$flags(keys[i],2L))
  stopifnot(spool$inspect()$slots==2048)
  spool$put(keys[1025L],charToRaw('1025'))
  stopifnot(spool$inspect()$slots==4096)
  for(i in seq_along(keys))stopifnot(identical(spool$get(keys[i]),charToRaw(as.character(i))))
  for(i in seq_along(homes))stopifnot(spool$flags(keys[i])==2L)
})

# Exact shared logical byte/file limits and old+replacement rehash peaks.
local({
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns)
  spool<-f('.v2_spool');budget<-f('.v2_scratch_budget');write<-f('.v2_scratch_file')
  root<-tempfile('scratch-budget-');dir.create(root);on.exit(unlink(root,recursive=TRUE))
  live<-list();on.exit(for(s in live)try(s$close(),silent=TRUE),add=TRUE,after=FALSE)
  make<-function(name,b,check=function()NULL){s<-spool(file.path(root,name),check,b);live[[length(live)+1L]]<<-s;s}
  hash<-function(i)digest::digest(as.character(i),algo='sha256',serialize=FALSE)
  fail<-function(work,code=NULL) {
    e<-tryCatch({work();NULL},error=identity);stopifnot(inherits(e,'error'))
    if(!is.null(code))stopifnot(inherits(e,'achillesnext_scratch_error'),identical(e$code,code))
    invisible(e)
  }
  initial<-1024*89
  for(v in list(-1,NA_real_,NaN,Inf,1.5,2^53,'1024',numeric()))fail(function()budget(v))
  b<-budget(initial-1);path<-file.path(root,'too-small')
  fail(function()spool(path,budget=b),'byte_limit')
  stopifnot(!dir.exists(path),b$inspect()$bytes==0,b$inspect()$files==0)
  b<-budget(initial+64);s<-make('exact-append',b);s$put(hash(1),raw())
  fail(function()s$put(hash(2),raw()),'byte_limit')
  stopifnot(s$has(hash(1)),!s$has(hash(2)),s$inspect()$entries==1,b$inspect()$bytes==initial+64)
  b<-budget(2*initial-1);s<-make('shared-first',b)
  fail(function()make('shared-second',b),'byte_limit')
  stopifnot(b$inspect()$bytes==initial,b$inspect()$files==2,!dir.exists(file.path(root,'shared-second')))
  b<-budget(2*initial+64);s<-make('shared-exact-first',b);t<-make('shared-exact-second',b)
  s$put(hash(1),raw());fail(function()t$put(hash(1),raw()),'byte_limit')
  stopifnot(s$has(hash(1)),!t$has(hash(1)),b$inspect()$bytes==2*initial+64)
  # Final retained bytes fit, but a replacement cannot displace the live index
  # until copying has completed; refuse before allocating either new value/file.
  retained<-2*initial+513*64;peak<-3*initial+512*64
  b<-budget(retained);s<-make('grow-refused',b)
  for(i in 1:512)s$put(hash(i),raw())
  s$flags(hash(1),2L);fail(function()s$put(hash(513),raw()),'byte_limit')
  stopifnot(s$inspect()$slots==1024,s$inspect()$entries==512,s$flags(hash(1))==2L,
    length(list.files(file.path(root,'grow-refused')))==2,!s$has(hash(513)),b$inspect()$peak_bytes==initial+512*64)
  b<-budget(peak);s<-make('grow-exact',b)
  for(i in 1:513)s$put(hash(i),raw())
  stopifnot(s$inspect()$slots==2048,b$inspect()$peak_bytes==peak,b$inspect()$bytes==retained)
  sizes<-sum(file.info(list.files(file.path(root,'grow-exact'),full.names=TRUE))$size)
  stopifnot(sizes==b$inspect()$bytes)
  # Zero-length marks consume a file slot. Group overwrites charge only growth.
  b<-budget(0,maxFiles=1);write(file.path(root,'mark-1'),raw(),b)
  fail(function()write(file.path(root,'mark-2'),raw(),b),'file_limit')
  stopifnot(b$inspect()$bytes==0,b$inspect()$files==1,!file.exists(file.path(root,'mark-2')))
  b<-budget(3,maxFiles=1);path<-file.path(root,'group');write(path,charToRaw('9\n'),b)
  write(path,charToRaw('10\n'),b);fail(function()write(path,charToRaw('100\n'),b),'byte_limit')
  stopifnot(readLines(path)=='10',b$inspect()$bytes==3,b$inspect()$files==1)
  armed<-FALSE;checks<-0L;b<-budget();s<-make('mid-copy-cancel',b,function(){
    if(armed){checks<<-checks+1L;if(checks==2L)stop('mid-copy cancellation')}
  })
  for(i in 1:1024)s$put(hash(i),raw())
  s$flags(hash(1),2L);prior<-b$inspect()$bytes;armed<-TRUE
  cancelled<-fail(function()s$put(hash(1025),raw()))
  stopifnot(conditionMessage(cancelled)=='mid-copy cancellation',checks==2L,
    s$inspect()$slots==2048,s$inspect()$entries==1024,!s$inspect()$poisoned,
    s$flags(hash(1))==2L,identical(s$get(hash(1)),raw()),!s$has(hash(1025)),
    length(list.files(file.path(root,'mid-copy-cancel')))==2,b$inspect()$bytes==prior)
  armed<-FALSE;s$put(hash(1025),raw());stopifnot(s$inspect()$slots==4096)
  cat('VALIDATION_SHARED_SCRATCH_EXACT_BYTES_FILES_REHASH_PEAK_OK\n')
})

# Inject failures at the filesystem boundary, including warning-only writes.
local({
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);original<-f('.v2_scratch_io')
  root<-tempfile('scratch-io-');dir.create(root);on.exit(unlink(root,recursive=TRUE))
  on.exit(assignInNamespace('.v2_scratch_io',original,ns='AchillesNext'),add=TRUE)
  fail<-function(work) {
    e<-tryCatch({work();NULL},error=identity)
    stopifnot(inherits(e,'achillesnext_scratch_error'),e$code=='io_failure',
      conditionMessage(e)=='Validation scratch I/O failed')
  }
  inject<-function(predicate,after=FALSE) {
    fired<-FALSE
    assignInNamespace('.v2_scratch_io',function(work) {
      if(!fired&&predicate(all.names(body(work)))) {
        fired<<-TRUE;return(original(function(){if(after)work();warning('PRIVATE_DISK_PATH_SENTINEL');if(!after)work()}))
      }
      original(work)
    },ns='AchillesNext')
    function()fired
  }
  connections<-nrow(showConnections())
  for(operation in c('file','seek','writeBin','flush')) {
    b<-f('.v2_scratch_budget')();path<-file.path(root,paste0('constructor-',operation))
    fired<-inject(function(names)operation%in%names)
    fail(function()f('.v2_spool')(path,budget=b));stopifnot(fired(),!dir.exists(path),b$inspect()$bytes==0,b$inspect()$files==0)
    assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
  }
  for(operation in c('seek','writeBin','flush')) {
    s<-f('.v2_spool')(file.path(root,paste0('append-',operation)))
    fired<-inject(function(names)operation%in%names&&'data'%in%names)
    fail(function()s$put(strrep('a',64),raw()));stopifnot(fired(),s$inspect()$poisoned)
    fail(function()s$get(strrep('a',64)));s$close()
    assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
  }
  # Replacement allocation, final handoff close and old-index unlink failures
  # all retain no orphan replacement and never expose a partly usable map.
  for(operation in c('file','close','unlink')) {
    path<-file.path(root,paste0('grow-',operation));s<-f('.v2_spool')(path)
    for(i in 1:512)s$put(digest::digest(as.character(i),algo='sha256',serialize=FALSE),raw())
    fired<-inject(function(names)operation%in%names)
    fail(function()s$put(strrep('a',64),raw()));stopifnot(fired(),s$inspect()$poisoned,
      !file.exists(file.path(path,'index-2048')))
    fail(function()s$get(strrep('a',64)));s$close()
    assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
  }
  s<-f('.v2_spool')(file.path(root,'partial-append'))
  fired<-inject(function(names)all(c('writeBin','data')%in%names),after=TRUE)
  fail(function()s$put(strrep('b',64),charToRaw('written-before-warning')))
  stopifnot(fired(),s$inspect()$poisoned,s$inspect()$entries==0)
  fail(function()s$get(strrep('b',64)));s$close()
  assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
  stopifnot(nrow(showConnections())==connections)
  cat('VALIDATION_SCRATCH_IO_FAULTS_SAFE_ERRORS_POISON_CLEANUP_OK\n')
})

# Public admission controls preserve exact bytes, full semantic checks and
# source isolation for both legacy-ID and approved-label artifacts.
source('tests/tracer/saved-result-fixture.R')
local({
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns)
  root<-tempfile('scratch-artifact-');dir.create(root);on.exit(unlink(root,recursive=TRUE))
  old<-makeSavedResultFixture(file.path(root,'old'))
  labels<-makeSavedResultFixture(file.path(root,'labels'),extraConceptIds=as.character(20:45),savedLabels=list('123'='Approved label'))
  original<-DatabaseConnector::connect;attempted<-0L
  assignInNamespace('connect',function(...){attempted<<-attempted+1L;stop('Unexpected source connection')},ns='DatabaseConnector')
  on.exit(assignInNamespace('connect',original,ns='DatabaseConnector'),add=TRUE)
  scratches<-function()sort(Sys.glob(file.path(tempdir(),'achilles-validate-*')))
  before<-scratches()
  fail<-function(work,code=NULL) {
    e<-tryCatch({work();NULL},error=identity);stopifnot(inherits(e,'error'))
    if(!is.null(code))stopifnot(inherits(e,'achillesnext_scratch_error'),identical(e$code,code))
    stopifnot(identical(before,scratches()));invisible(e)
  }
  hashes<-function(directory) {
    paths<-list.files(directory,recursive=TRUE,full.names=TRUE)
    vapply(paths,function(path)digest::digest(file=path,algo='sha256'),'')
  }
  peak<-0;originalBudget<-f('.v2_scratch_budget')
  assignInNamespace('.v2_scratch_budget',function(maxBytes=1024^3,maxFiles=1000000L) {
    b<-originalBudget(maxBytes,maxFiles);acquire<-b$acquire
    b$acquire<-function(n,f=0){acquire(n,f);peak<<-max(peak,b$inspect()$peak_bytes)};b
  },ns='AchillesNext')
  on.exit(assignInNamespace('.v2_scratch_budget',originalBudget,ns='AchillesNext'),add=TRUE)
  for(x in list(old,labels)) {
    pinned<-hashes(x$directory);peak<-0;validateResultArtifact(x$directory)
    needed<-peak;stopifnot(needed>2*1024*89,needed<1024^3)
    cat("ARTIFACT_SCRATCH_PEAK",x$context$contract_version,needed,"bytes\n")
    validateResultArtifact(x$directory,maxScratchBytes=needed)
    fail(function()validateResultArtifact(x$directory,maxScratchBytes=needed-1),'byte_limit')
    stopifnot(identical(pinned,hashes(x$directory)),identical(before,scratches()))
  }
  assignInNamespace('.v2_scratch_budget',function(maxBytes=1024^3,maxFiles=1000000L)originalBudget(maxBytes,4),ns='AchillesNext')
  fail(function()validateResultArtifact(labels$directory),'file_limit')
  assignInNamespace('.v2_scratch_budget',originalBudget,ns='AchillesNext')
  for(fault in c('wrong_reference','missing_concept','wrong_name_label','extra_concept')) {
    bad<-makeSavedResultFixture(file.path(root,fault),fault=fault,savedLabels=list('123'='Approved label'))
    fail(function()validateResultArtifact(bad$directory,maxScratchBytes=1024^3))
  }
  fail(function()validateResultArtifact(labels$directory,maxScratchBytes=0),'byte_limit')
  cancelled<-fail(function()validateResultArtifact(labels$directory,cancel=function()TRUE))
  stopifnot(inherits(cancelled,'achillesnext_read_error'),cancelled$code=='aborted')
  calls<-0L
  cancelled<-fail(function()validateResultArtifact(labels$directory,cancel=function(){calls<<-calls+1L;calls>30L}))
  stopifnot(inherits(cancelled,'achillesnext_read_error'),cancelled$code=='aborted',calls==31L,attempted==0L)
  cat('VALIDATION_ARTIFACT_EXACT_BUDGET_BYTES_LABELS_SEMANTICS_CANCEL_ZERO_SOURCE_OK\n')
})

# Real R interrupt conditions keep their identity; cleanup continues and an
# uncertain write cannot expose a supposedly reusable spool after cancellation.
local({
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);original<-f('.v2_scratch_io')
  root<-tempfile('scratch-interrupt-');dir.create(root);on.exit(unlink(root,recursive=TRUE))
  on.exit(assignInNamespace('.v2_scratch_io',original,ns='AchillesNext'),add=TRUE)
  interrupted<-structure(list(message='synthetic scratch interrupt',call=NULL),class=c('interrupt','condition'))
  caught<-function(work) {
    out<-tryCatch(list(ok=TRUE,value=work()),interrupt=function(e)list(ok=FALSE,failure=e),error=function(e)list(ok=FALSE,failure=e))
    stopifnot(!out$ok,inherits(out$failure,'interrupt'),identical(out$failure,interrupted))
  }
  stopifnot(identical(original(function()interrupted),interrupted))
  caught(function()original(function()stop(interrupted)))
  done<-character()
  caught(function()f('.v2_scratch_cleanup')(list(function(){done<<-c(done,'first');stop(interrupted)},
    function(){done<<-c(done,'second');stop('later failure')},function(){done<<-c(done,'third')})))
  stopifnot(identical(done,c('first','second','third')))
  f('.v2_scratch_cleanup')(list(function()interrupted,function(){done<<-c(done,'returned-value')}))
  stopifnot(tail(done,1)=='returned-value')
  connections<-nrow(showConnections())
  # Interrupt after an index was extended: constructor releases both files and
  # handles even though no spool object can be returned to the caller.
  fired<-FALSE;b<-f('.v2_scratch_budget')();path<-file.path(root,'constructor')
  assignInNamespace('.v2_scratch_io',function(work) {
    result<-original(work)
    if(!fired&&'seek'%in%all.names(body(work))){fired<<-TRUE;stop(interrupted)}
    result
  },ns='AchillesNext')
  caught(function()f('.v2_spool')(path,budget=b))
  stopifnot(fired,!dir.exists(path),b$inspect()$bytes==0,b$inspect()$files==0)
  assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
  s<-f('.v2_spool')(file.path(root,'append'));fired<-FALSE
  assignInNamespace('.v2_scratch_io',function(work) {
    result<-original(work)
    if(!fired&&all(c('writeBin','data')%in%all.names(body(work)))){fired<<-TRUE;stop(interrupted)}
    result
  },ns='AchillesNext')
  caught(function()s$put(strrep('a',64),charToRaw('before interrupt')))
  stopifnot(fired,s$inspect()$poisoned,s$inspect()$entries==0)
  e<-tryCatch(s$get(strrep('a',64)),error=identity)
  stopifnot(inherits(e,'achillesnext_scratch_error'),e$code=='io_failure');s$close()
  assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
  s<-f('.v2_spool')(file.path(root,'close'));fired<-FALSE
  assignInNamespace('.v2_scratch_io',function(work) {
    if(!fired&&'close'%in%all.names(body(work))){fired<<-TRUE;stop(interrupted)}
    original(work)
  },ns='AchillesNext')
  caught(function()s$close());stopifnot(fired,s$inspect()$closed)
  assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
  # A check()-only interruption while copying is safe to retry. Neither old
  # values nor flags are mutated, so this cancellation must not poison them.
  armed<-FALSE;s<-f('.v2_spool')(file.path(root,'rehash-check'),function(){if(armed)stop(interrupted)})
  hash<-function(i)digest::digest(as.character(i),algo='sha256',serialize=FALSE)
  for(i in 1:512)s$put(hash(i),raw())
  s$flags(hash(1),2L);armed<-TRUE;caught(function()s$put(hash(513),raw()))
  stopifnot(!s$inspect()$poisoned,s$inspect()$entries==512,s$flags(hash(1))==2L,
    identical(s$get(hash(1)),raw()),!s$has(hash(513)),length(list.files(file.path(root,'rehash-check')))==2)
  armed<-FALSE;s$put(hash(513),raw());s$close()
  stopifnot(nrow(showConnections())==connections)
  cat('VALIDATION_SCRATCH_INTERRUPTS_TAGGED_VALUES_POISON_ALL_CLEANUPS_REHASH_RETRY_OK\n')
})

# Deliver a real asynchronous interrupt in the former old-index deletion/swap
# window. Delivery must leave the replacement installed; if R delivers the
# pending interrupt in a subsequent append, that uncertain I/O must be poisoned.
if(.Platform$OS.type=='unix')local({
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);original<-f('.v2_scratch_io')
  path<-tempfile('scratch-atomic-handoff-');b<-f('.v2_scratch_budget')();s<-f('.v2_spool')(path,budget=b)
  on.exit({assignInNamespace('.v2_scratch_io',original,ns='AchillesNext');s$close();unlink(path,recursive=TRUE)})
  hash<-function(i)digest::digest(as.character(i),algo='sha256',serialize=FALSE)
  for(i in 1:512)s$put(hash(i),raw())
  s$flags(hash(1),2L);fired<-FALSE
  assignInNamespace('.v2_scratch_io',function(work) {
    result<-original(work)
    if(!fired&&'unlink'%in%all.names(body(work))) {
      fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT))
    }
    result
  },ns='AchillesNext')
  out<-tryCatch({s$put(hash(513),raw());Sys.sleep(0);list(ok=TRUE)},interrupt=function(e)list(ok=FALSE,failure=e),error=function(e)list(ok=FALSE,failure=e))
  assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
  stopifnot(fired,!out$ok,inherits(out$failure,'interrupt'),
    s$inspect()$slots==2048,s$inspect()$entries%in%c(512,513),
    !file.exists(file.path(path,'index-1024')),file.exists(file.path(path,'index-2048')),
    length(list.files(path))==2,file.info(file.path(path,'index-2048'))$size==2048*89,
    identical(readBin(file.path(path,'values'),'raw',n=512*64),charToRaw(paste(vapply(1:512,hash,''),collapse=''))))
  if(s$inspect()$poisoned) {
    e<-tryCatch(s$get(hash(1)),error=identity)
    stopifnot(inherits(e,'achillesnext_scratch_error'),e$code=='io_failure')
  } else {
    stopifnot(s$flags(hash(1))==2L,identical(s$get(hash(1)),raw()))
    if(s$inspect()$entries==512){stopifnot(!s$has(hash(513)));s$put(hash(513),raw())}
    stopifnot(s$inspect()$entries==513,s$has(hash(513)))
  }
  cat('VALIDATION_SCRATCH_ASYNC_SIGINT_AT_OLD_UNLINK_ATOMIC_HANDOFF_SAFE_STATE_OK\n')
})

# Actual pending SIGINT at allocation-return boundaries must not strand a
# connection between the allocator's cleanup and the receiving owner's cleanup.
if(.Platform$OS.type=='unix')local({
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);original<-f('.v2_scratch_io')
  root<-tempfile('scratch-allocation-handoff-');dir.create(root)
  baseline<-nrow(showConnections());captured<-NULL;s<-NULL
  on.exit({
    assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
    if(!is.null(s))try(s$close(),silent=TRUE)
    if(!is.null(captured)&&tryCatch(isOpen(captured),error=function(e)FALSE))close(captured)
    unlink(root,recursive=TRUE)
  })
  caught<-function(work) {
    out<-tryCatch({work();Sys.sleep(0);list(ok=TRUE)},interrupt=function(e)list(ok=FALSE,failure=e),error=function(e)list(ok=FALSE,failure=e))
    stopifnot(!out$ok,inherits(out$failure,'interrupt'))
  }
  # The file is really open, but the assignment to fresh's connection variable
  # has not happened yet. Delivery must wait until that owner can clean up.
  fired<-FALSE;b<-f('.v2_scratch_budget')();path<-file.path(root,'constructor')
  assignInNamespace('.v2_scratch_io',function(work) {
    result<-original(work)
    if(!fired&&'file'%in%all.names(body(work))) {
      captured<<-result;fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)
    }
    result
  },ns='AchillesNext')
  caught(function()f('.v2_spool')(path,budget=b))
  assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
  stopifnot(fired,!dir.exists(path),b$inspect()$bytes==0,b$inspect()$files==0,
    nrow(showConnections())==baseline)
  captured<-NULL
  b<-f('.v2_scratch_budget')();path<-file.path(root,'rehash')
  s<-f('.v2_spool')(path,budget=b)
  hash<-function(i)digest::digest(as.character(i),algo='sha256',serialize=FALSE)
  for(i in 1:512)s$put(hash(i),raw())
  s$flags(hash(1),2L);prior<-b$inspect();before<-nrow(showConnections())
  owner<-environment(s$put);fresh<-owner$fresh;fired<-FALSE
  owner$fresh<-function(...) {
    result<-fresh(...)
    captured<<-result;fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)
    result
  }
  caught(function()s$put(hash(513),raw()))
  owner$fresh<-fresh
  stopifnot(fired,s$inspect()$slots==1024,s$inspect()$entries==512,
    !file.exists(file.path(path,'index-2048')),length(list.files(path))==2,
    b$inspect()$bytes==prior$bytes,b$inspect()$files==prior$files,
    nrow(showConnections())==before)
  if(s$inspect()$poisoned) {
    e<-tryCatch(s$get(hash(1)),error=identity)
    stopifnot(inherits(e,'achillesnext_scratch_error'),e$code=='io_failure')
  } else {
    stopifnot(identical(s$get(hash(1)),raw()),s$flags(hash(1))==2L,!s$has(hash(513)))
    s$put(hash(513),raw());stopifnot(s$inspect()$entries==513)
  }
  s$close();s<-NULL;stopifnot(nrow(showConnections())==baseline)
  cat('VALIDATION_SCRATCH_ASYNC_SIGINT_ALLOCATION_OWNERSHIP_TRANSFER_CLEANUP_OK\n')
})

# Admission owns the returned spools before deferred constructor interrupts can
# escape; removing a scratch directory alone must not leave its handles open.
if(.Platform$OS.type=='unix')local({
  ns<-asNamespace('AchillesNext');original<-get('.v2_spool',ns)
  root<-tempfile('scratch-admission-handoff-');dir.create(root)
  captured<-NULL;fired<-FALSE
  on.exit({
    assignInNamespace('.v2_spool',original,ns='AchillesNext')
    if(!is.null(captured))try(captured$close(),silent=TRUE)
    unlink(root,recursive=TRUE)
  })
  artifact<-makeSavedResultFixture(file.path(root,'artifact'))
  before<-nrow(showConnections());scratches<-sort(Sys.glob(file.path(tempdir(),'achilles-validate-*')))
  assignInNamespace('.v2_spool',function(...) {
    result<-original(...)
    if(!fired) {
      captured<<-result;fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)
    }
    result
  },ns='AchillesNext')
  out<-tryCatch({validateResultArtifact(artifact$directory);Sys.sleep(0);list(ok=TRUE)},
    interrupt=function(e)list(ok=FALSE,failure=e),error=function(e)list(ok=FALSE,failure=e))
  assignInNamespace('.v2_spool',original,ns='AchillesNext')
  stopifnot(fired,!out$ok,inherits(out$failure,'interrupt'),captured$inspect()$closed,
    nrow(showConnections())==before,identical(scratches,sort(Sys.glob(file.path(tempdir(),'achilles-validate-*')))))
  cat('VALIDATION_ARTIFACT_ASYNC_SIGINT_SPOOL_RETURN_OWNERSHIP_CLEANUP_OK\n')
})

# Group/mark writes have the same file-open ownership boundary. The helper
# closes its handle while enclosing admission retains responsibility for files.
if(.Platform$OS.type=='unix')local({
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);original<-f('.v2_scratch_io')
  path<-tempfile('scratch-group-open-');captured<-NULL;fired<-FALSE
  b<-f('.v2_scratch_budget')();before<-nrow(showConnections())
  on.exit({
    assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
    if(!is.null(captured)&&tryCatch(isOpen(captured),error=function(e)FALSE))close(captured)
    unlink(path)
  })
  assignInNamespace('.v2_scratch_io',function(work) {
    result<-original(work)
    if(!fired&&'file'%in%all.names(body(work))) {
      captured<<-result;fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)
    }
    result
  },ns='AchillesNext')
  out<-tryCatch({f('.v2_scratch_file')(path,charToRaw('12\n'),b);Sys.sleep(0);list(ok=TRUE)},
    interrupt=function(e)list(ok=FALSE,failure=e),error=function(e)list(ok=FALSE,failure=e))
  assignInNamespace('.v2_scratch_io',original,ns='AchillesNext')
  stopifnot(fired,!out$ok,inherits(out$failure,'interrupt'),nrow(showConnections())==before,
    file.exists(path),b$inspect()$bytes==3,b$inspect()$files==1)
  # An interrupted write remains fully reserved until its admission removes it.
  unlink(path);b$release(3,1)
  stopifnot(!file.exists(path),b$inspect()$bytes==0,b$inspect()$files==0)
  cat('VALIDATION_SCRATCH_GROUP_ASYNC_SIGINT_OPEN_OWNERSHIP_CLEANUP_OK\n')
})

# Directory creation is itself an ownership boundary, before any spool handle
# exists. Real pending SIGINT must wait until cleanup owns a successful mkdir.
if(.Platform$OS.type=='unix')local({
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns)
  originalIO<-f('.v2_scratch_io');originalBudget<-f('.v2_scratch_budget')
  root<-tempfile('scratch-directory-ownership-');dir.create(root)
  created<-NULL;b<-NULL
  on.exit({
    assignInNamespace('.v2_scratch_io',originalIO,ns='AchillesNext')
    assignInNamespace('.v2_scratch_budget',originalBudget,ns='AchillesNext')
    if(!is.null(created))unlink(created,recursive=TRUE)
    unlink(root,recursive=TRUE)
  })
  artifact<-makeSavedResultFixture(file.path(root,'artifact'))
  connections<-nrow(showConnections());clean<-logical()
  for(kind in c('artifact','spool')) {
    created<-NULL;fired<-FALSE;b<-NULL
    assignInNamespace('.v2_scratch_budget',function(maxBytes=1024^3,maxFiles=1000000L) {
      b<<-originalBudget(maxBytes,maxFiles);b
    },ns='AchillesNext')
    assignInNamespace('.v2_scratch_io',function(work) {
      result<-originalIO(work);symbols<-all.names(body(work))
      if(!fired&&'dir.create'%in%symbols) {
        created<<-get(if(kind=='artifact')'scratch' else 'directory',environment(work))
        stopifnot(dir.exists(created));fired<<-TRUE
        stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)
      }
      result
    },ns='AchillesNext')
    if(kind=='spool')b<-originalBudget()
    out<-tryCatch({
      if(kind=='artifact')validateResultArtifact(artifact$directory) else f('.v2_spool')(file.path(root,'new-spool'),budget=b)
      Sys.sleep(0);list(ok=TRUE)
    },interrupt=function(e)list(ok=FALSE,failure=e),error=function(e)list(ok=FALSE,failure=e))
    assignInNamespace('.v2_scratch_io',originalIO,ns='AchillesNext')
    assignInNamespace('.v2_scratch_budget',originalBudget,ns='AchillesNext')
    stopifnot(fired,!out$ok,inherits(out$failure,'interrupt'),nrow(showConnections())==connections,
      !is.null(b),b$inspect()$bytes==0,b$inspect()$files==0)
    clean[[kind]]<-!dir.exists(created)
    cat('DIRECTORY_CREATION_SIGINT_CLEANUP',kind,clean[[kind]],'\n')
    # Keep a RED run from leaving the very orphan it is detecting.
    unlink(created,recursive=TRUE);created<-NULL
  }
  # Refusal of an existing path confers no ownership. Its sentinel and directory
  # must survive both the private constructor and the public scratch collision.
  existing<-file.path(root,'existing');dir.create(existing)
  sentinel<-charToRaw('unowned directory sentinel');writeBin(sentinel,file.path(existing,'keep'))
  b<-originalBudget()
  e<-tryCatch(f('.v2_spool')(existing,budget=b),error=identity)
  stopifnot(inherits(e,'achillesnext_scratch_error'),e$code=='io_failure',dir.exists(existing),
    identical(readBin(file.path(existing,'keep'),'raw',n=1024),sentinel),
    b$inspect()$bytes==0,b$inspect()$files==0,nrow(showConnections())==connections)
  created<-NULL;fired<-FALSE
  assignInNamespace('.v2_scratch_io',function(work) {
    symbols<-all.names(body(work))
    if(!fired&&'dir.create'%in%symbols&&'scratch'%in%symbols) {
      created<<-get('scratch',environment(work));dir.create(created)
      writeBin(sentinel,file.path(created,'keep'));fired<<-TRUE
    }
    originalIO(work)
  },ns='AchillesNext')
  e<-tryCatch(validateResultArtifact(artifact$directory),error=identity)
  assignInNamespace('.v2_scratch_io',originalIO,ns='AchillesNext')
  stopifnot(fired,inherits(e,'achillesnext_scratch_error'),e$code=='io_failure',dir.exists(created),
    identical(readBin(file.path(created,'keep'),'raw',n=1024),sentinel),nrow(showConnections())==connections)
  stopifnot(all(clean))
  cat('VALIDATION_ARTIFACT_AND_SPOOL_ASYNC_SIGINT_DIRECTORY_OWNERSHIP_UNOWNED_PRESERVATION_OK\n')
})
