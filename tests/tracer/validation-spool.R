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
