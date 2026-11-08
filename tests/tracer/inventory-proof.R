# Reused by the opt-in million-entry run and the small compatibility smoke test.
proveSavedInventory <- function(directory,context,count,constructor=NULL,transportFactory=NULL,database=FALSE) {
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);wire<-f('.v2_bytes')
  providers<-list();cases<-character();failures<-list()
  keep<-function(p){providers[[length(providers)+1L]]<<-p;p}
  on.exit(for(p in providers)p$close())
  if(is.null(constructor))constructor<-function(ctx,authority,budget)openArtifactResultProvider(directory,ctx,authority,budget)
  if(is.null(transportFactory))transportFactory<-function(ctx,authority)f('.saved_artifact_transport')(directory,ctx,authority)
  open<-function(ctx=context,authority=function(ctx)TRUE,budget=list())keep(constructor(ctx,authority,budget))
  fail<-function(name,work,code,p) {
    elapsed<-system.time(e<-tryCatch({work();NULL},error=identity),gcFirst=FALSE)
    stopifnot(inherits(e,'achillesnext_read_error'),identical(e$code,code),p$inspect()$cache_bytes==0L)
    cases<<-c(cases,name)
    failures[[length(failures)+1L]]<<-list(case=name,code=code,elapsed_seconds=unname(elapsed['elapsed']))
  }
  p<-open()
  independentContext<-context;independentContext$instance_id<-'independent-reader'
  independent<-open(independentContext)
  independentCursor<-if(count>1L)independent$searchConcepts('Synthetic',limit=1L)$cursor else NULL
  missing<-p$lookupConcepts(as.character(count+1))
  stopifnot(missing$concepts[[1]]$state=='not_saved',is.null(missing$concepts[[1]]$label))
  empty<-p$searchConcepts('Not a synthetic name');stopifnot(empty$searched,empty$complete,!length(empty$concepts))
  cases<-c(cases,'exact-missing-is-not-zero','empty-prefix-result')
  if(count>3L) {
    first<-p$searchConcepts('Synthetic concept ',limit=1L)
    cursor<-first$cursor;ids<-first$concepts[[1]]$concept_tag$value
    for(i in 2:3) {
      page<-p$searchConcepts('Synthetic concept ',limit=1L,cursor=cursor)
      ids<-c(ids,page$concepts[[1]]$concept_tag$value);cursor<-page$cursor
    }
    stopifnot(identical(ids,c('1','2','3')))
    maxBytes<-length(wire(first))+64L
    bytePage<-p$searchConcepts('Synthetic concept ',limit=25L,maxBytes=maxBytes)
    stopifnot(length(wire(bytePage))<=maxBytes,length(bytePage$concepts)>=1L,!bytePage$complete,
      length(bytePage$concepts)<min(25L,count))
    cases<-c(cases,'within-leaf-count-cursors','complete-response-byte-boundary')
    for(field in c('instance_id','authorization_epoch')) {
      changed<-context;changed[[field]]<-paste0(changed[[field]],'-new');other<-open(changed)
      fail(paste0('cursor-',field),function()other$searchConcepts('Synthetic concept ',limit=1L,cursor=cursor),'invalid_cursor',other)
    }
    fail('cursor-selection',function()p$searchConcepts('Other',limit=1L,cursor=cursor),'invalid_cursor',p)
  }
  for(field in c('contract_version','source_id','access_scope_id','publication_id','release_id')) {
    changed<-context;changed[[field]]<-if(field=='contract_version')'2.0.0' else if(field%in%c('publication_id','release_id'))'00000000-0000-4000-8000-000000000099' else 'other'
    other<-open(changed)
    fail(paste0('wire-context-',field),function()other$lookupConcepts('1'),if(database&&field%in%c('source_id','access_scope_id','publication_id'))'unavailable' else 'integrity_failure',other)
  }
  for(field in c('profile_id','profile_revision','profile_sha256')) {
    changed<-context;changed[[field]]<-if(field=='profile_sha256')strrep('f',64) else 'unregistered-inventory'
    e<-tryCatch({open(changed);NULL},error=identity)
    stopifnot(inherits(e,'error'),identical(conditionMessage(e),if(field=='profile_id')'Unregistered runtime profile' else 'Unregistered runtime profile revision or hash'))
    cases<-c(cases,paste0('constructor-context-',field))
  }
  # Warming a cache cannot authorize access after the host revokes the instance.
  active<-TRUE;revoked<-open(authority=function(ctx)active);revoked$lookupConcepts('1');active<-FALSE
  fail('warm-cache-revocation',function()revoked$lookupConcepts('1'),'inaccessible',revoked)
  tiny<-open(budget=list(maxObjects=1L))
  fail('resource-limit-is-not-missing',function()tiny$lookupConcepts('1'),'resource_limit',tiny)
  if(count>=16384L) {
    ids<-as.character(1L+(0:99)*floor(count/100))
    fail('scattered-id-set-fails-without-partial-success',function()p$lookupConcepts(ids,limit=100L),'resource_limit',p)
    cursor<-NULL;returned<-character()
    for(i in 1:3) {
      page<-p$lookupConcepts(ids,limit=4L,cursor=cursor)
      stopifnot(page$budget$objects<=64L,page$budget$bytes<=8388608L,page$budget$rows<=8192L,!page$complete)
      returned<-c(returned,vapply(page$concepts,function(entry)entry$concept_tag$value,''));cursor<-page$cursor
    }
    stopifnot(identical(returned,ids[1:12]))
    cases<-c(cases,'scattered-id-set-bounded-cursor-pages')
  }
  fail('pre-cancel',function()p$searchConcepts('Synthetic',cancel=function()TRUE),'aborted',p)
  # Return late, otherwise valid bytes after cancellation. Zero cache suppresses
  # caching as a confounder; this exercises the actual post-fetch checkpoint.
  cancelled<-FALSE;armed<-FALSE;fetches<-0L
  transport<-transportFactory(context,function(ctx)TRUE);read<-transport$read
  transport$read<-function(d,cancel) {
    value<-read(d,cancel);fetches<<-fetches+1L
    if(armed&&d$kind=='concept_catalogue')cancelled<<-TRUE
    value
  }
  late<-keep(f('.saved_provider')(transport,list(cacheBytes=0L)))
  oldCursor<-if(count>1L)late$searchConcepts('Synthetic',limit=1L)$cursor else NULL
  armed<-TRUE
  fail('late-fetch-cancel',function()late$lookupConcepts('1',cancel=function()cancelled),'aborted',late)
  armed<-FALSE;cancelled<-FALSE
  if(!is.null(oldCursor))fail('cancel-invalidates-cursor',function()late$searchConcepts('Synthetic',limit=1L,cursor=oldCursor),'invalid_cursor',late)
  # Abort within a real 512-entry witness page, before the remaining candidates.
  if(count>=3L) {
    candidate<-open();component<-f('.v2_component');scanned<-0L;abort<-FALSE
    observed<-function(x,name) {
      if(identical(substitute(x),quote(candidate$concept_tag))){scanned<<-scanned+1L;if(scanned==2L)abort<<-TRUE}
      component(x,name)
    }
    assignInNamespace('.v2_component',observed,ns='AchillesNext')
    tryCatch(fail('candidate-loop-cancel',function()candidate$searchConcepts('Synthetic',cancel=function()abort),'aborted',candidate),
      finally=assignInNamespace('.v2_component',component,ns='AchillesNext'))
    stopifnot(scanned==2L)
  }
  # Closing/replacing authority while a fetch is outstanding discards late data.
  closed<-NULL;transport<-transportFactory(context,function(ctx)TRUE);readClose<-transport$read
  transport$read<-function(d,cancel){value<-readClose(d,cancel);closed$close();value}
  closed<-keep(f('.saved_provider')(transport))
  fail('close-during-fetch',function()closed$lookupConcepts('1'),'closed',closed)
  stopifnot(closed$inspect()$closed)
  current<-context;transport<-transportFactory(context,function(ctx)identical(ctx,current));readEpoch<-transport$read
  transport$read<-function(d,cancel){value<-readEpoch(d,cancel);current$authorization_epoch<<-'replacement';value}
  old<-keep(f('.saved_provider')(transport))
  fail('epoch-change-during-fetch',function()old$lookupConcepts('1'),'inaccessible',old)
  corrupt<-transportFactory(context,function(ctx)TRUE);readCorrupt<-corrupt$read
  corrupt$read<-function(d,cancel){bytes<-readCorrupt(d,cancel);bytes[[1]]<-as.raw(32L);bytes}
  broken<-keep(f('.saved_provider')(corrupt))
  fail('late-byte-corruption',function()broken$lookupConcepts('1'),'integrity_failure',broken)
  # A mutable pointer cannot switch a pinned reader mid-interaction.
  if(!database) {
    pointer<-file.path(directory,'publication.json');saved<-readBin(pointer,'raw',n=file.info(pointer)$size)
    tryCatch({
      writeBin(charToRaw('{}\n'),pointer)
      fresh<-open();stopifnot(fresh$lookupConcepts('1')$concepts[[1]]$label==sprintf('Synthetic concept %07d',1L))
    },finally=writeBin(saved,pointer))
    cases<-c(cases,'pinned-root-ignores-current-file')
  }
  stopifnot(independent$lookupConcepts('1')$concepts[[1]]$state=='available')
  if(!is.null(independentCursor))stopifnot(independent$searchConcepts('Synthetic',limit=1L,cursor=independentCursor)$concepts[[1]]$concept_tag$value=='2')
  cases<-c(cases,'cancel-close-errors-do-not-invalidate-other-instance')
  list(cases=as.list(cases),count=length(cases),candidate_checks_before_abort=if(count>=3L)scanned else NULL,
    late_fetches=fetches,all_errors_clear_cache=TRUE,failures=failures)
}
