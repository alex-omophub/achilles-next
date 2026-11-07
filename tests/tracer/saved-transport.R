# Internal page traversal: routing-only fixtures do not assert full admission.
library(AchillesNext)
local({
  f <- function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');wire<-f('.v2_bytes');hash<-f('.v2_hash');a<-f('.v2_assets')()
  folder<-tempfile('saved-transport-test-');stopifnot(dir.create(folder));on.exit(unlink(folder,recursive=TRUE))
  failures<-0L
  fail<-function(work,code=NULL) {
    e<-tryCatch({work();NULL},error=identity)
    stopifnot(inherits(e,'error'))
    if(!is.null(code))stopifnot(inherits(e,'achillesnext_read_error'),identical(e$code,code))
    failures<<-failures+1L;invisible(e)
  }
  make<-function(bad=NULL,n=130L,retained=TRUE,catalogueState='computed',catalogueRows='1') {
    directory<-tempfile('fixture-',folder);dir.create(directory);dir.create(file.path(directory,'objects'))
    common<-o(contract_version='2.0.0',publication_id='00000000-0000-4000-8000-000000000001',release_id='00000000-0000-4000-8000-000000000002',source_id='fixture:transport',profile_id='core-characterization-v2',profile_revision='2.0.0',profile_sha256=a$hash,access_scope_id='fixture-scope')
    emit<-function(doc,kind,rows) {
      bytes<-wire(doc);d<-f('.v2_descriptor')(bytes,kind,rows)
      writeBin(bytes,file.path(directory,'objects',paste0(d$sha256,'.json')));d
    }
    concepts<-f('.v2_tree')('concept_catalogue',common,function(doc,kind,rows)emit(doc,kind,rows))
    for(i in seq_len(n)) {
      tag<-o(kind='id',value=as.character(i));key<-f('.v2_component')(tag,'concept_tag')
      doc<-c(common,o(kind='concept_catalogue',entries=list(o(concept_tag=tag,label=NULL,label_state='unavailable'))))
      if(i==1L && identical(bad,'row'))doc$entries[[1]]$label<-'unapproved'
      if(i==1L && identical(bad,'label_state_type'))doc$entries[[1]]$label_state<-list('unavailable')
      if(i==1L && identical(bad,'context'))doc$source_id<-'fixture:foreign'
      if(i==1L && identical(bad,'range'))doc$entries[[1]]$concept_tag$value<-'0'
      d<-emit(doc,'concept_catalogue','1');concepts$add(d,key,key)
    }
    conceptRoot<-concepts$finish()
    if(!is.null(bad) && bad%in%c('overlap','rows','unknown_field','fanout')) {
      doc<-f('.nv_json')(readBin(file.path(directory,'objects',paste0(conceptRoot$sha256,'.json')),'raw',n=262145L))
      if(bad=='overlap')doc$children[[2]]$lower_key<-doc$children[[1]]$upper_key
      if(bad=='unknown_field')doc$foreign<-'unknown'
      if(bad=='fanout')doc$children<-rep(doc$children[1],129L)
      conceptRoot<-emit(doc,'index',if(bad=='rows')'999' else conceptRoot$rows)
    }
    if(identical(bad,'depth'))for(i in 1:9) {
      child<-o(lower_key=f('.v2_component')(o(kind='id',value='1'),'concept_tag'),upper_key=f('.v2_component')(o(kind='id',value=as.character(n)),'concept_tag'),object=conceptRoot)
      conceptRoot<-emit(c(common,o(kind='index',index_kind='concept_catalogue',children=list(child))),'index',as.character(n))
    }
    mid<-'core.person.count';m<-a$metrics[[mid]]
    row<-o(row_key='',dimensions=o(),row_kind='counts',state='computed',reason_code=NULL,values=o(person_count='9007199254740993'),denominator_refs=list())
    row$row_key<-f('.v2_row_identity')(a$rows[[mid]],row)
    if(identical(bad,'row_state_type'))row$state<-list('computed')
    if(identical(bad,'ref_type'))row$denominator_refs<-list(o(measure=list('person_count'),metric_id=mid,row_key=row$row_key,field='person_count',value='9007199254740993'))
    data<-emit(c(common,o(kind='data',metric_id=mid,metric_version=if(identical(bad,'version_type'))list(m$version) else m$version,rows=list(row))),'data','1')
    entry<-o(metric_id=mid,version=m$version,population=m$population,grain=m$grain,row_schema_id=a$rows[[mid]]$row_schema_id,definition_sha256=hash(wire(m)),state=catalogueState,reason_code=if(catalogueState=='computed')NULL else 'fixture.policy_suppressed',required=TRUE,conditional_support=o(state='supported',reason_code=NULL),rows=catalogueRows,completeness=o(scope_kind='standard_full',complete=TRUE,excluded_record_count='0',reason_code=NULL))
    if(identical(bad,'catalogue_state_type'))entry$state<-list('computed')
    catalogue<-emit(c(common,o(kind='metric_catalogue',entries=list(entry))),'metric_catalogue','1')
    terminology<-emit(c(common,o(kind='index',index_kind='terminology',children=list())),'index','0')
    policy<-o(id='fixture',revision='1',scope_kind='restricted',allow_metrics=if(!retained || identical(bad,'policy'))list() else as.list(names(a$metrics)))
    root<-c(common,o(kind='root',scope_kind='restricted',publication_state='ready',eligible_for_current_pointer=TRUE,expected_metric_count='142',generated_at='2026-01-01T00:00:00.000Z',source_schema=o(sha256=strrep('a',64),declared_cdm_version='5.5'),source_consistency=o(within_run='unknown',reusable=FALSE,reason_code='fixture.unknown'),disclosure=o(approval_id='fixture',policy=policy,policy_sha256=hash(wire(policy))),catalogue=catalogue,concepts=conceptRoot,data=data,terminology=terminology))
    if(identical(bad,'root_count_type'))root$expected_metric_count<-142L
    if(identical(bad,'root_scope_type'))root$scope_kind<-list('restricted')
    desc<-emit(root,'root','0')
    context<-c(common,o(root=desc,authorization_epoch='1',instance_id='fixture-instance'))
    list(directory=normalizePath(directory),context=context,root=root)
  }
  x<-make();approved<-TRUE;checks<-0L
  # Root policy constrains catalogue metadata as well as data pages.
  for(values in list(c('computed','1'),c('computed','0'),c('suppressed','1'))) {
    z<-make(n=1L,retained=FALSE,catalogueState=values[[1]],catalogueRows=values[[2]])
    r<-f('.saved_reader')(f('.saved_artifact_transport')(z$directory,z$context,function(c)TRUE))
    fail(function()r$scan('metric_catalogue'),'integrity_failure')
    stopifnot(r$inspect()$cache_bytes==0L);r$close()
  }
  for(retained in c(TRUE,FALSE)) {
    z<-make(n=1L,retained=retained,catalogueState=if(retained)'computed' else 'suppressed',catalogueRows=if(retained)'1' else '0')
    r<-f('.saved_reader')(f('.saved_artifact_transport')(z$directory,z$context,function(c)TRUE))
    entry<-r$scan('metric_catalogue')$pages[[1]]$document$entries[[1]]
    stopifnot(entry$state==if(retained)'computed' else 'suppressed',entry$rows==if(retained)'1' else '0');r$close()
  }
  # A host callback may close the reader after the first lifecycle check.
  checkCallbackClose<-function(stage) {
    r<-NULL;fetched<-0L
    authority<-function(c){if(stage=='authority')r$close();TRUE}
    cancelled<-function(){if(stage=='cancel')r$close();FALSE}
    t<-f('.saved_transport')(x$context,authority,function(d){fetched<<-fetched+1L;stop('Unexpected fetch')})
    r<-f('.saved_reader')(t);on.exit(r$close())
    fail(function()r$root(cancel=cancelled),'closed')
    stopifnot(r$inspect()$closed,r$inspect()$cache_bytes==0L,fetched==0L)
  }
  for(stage in c('authority','cancel'))checkCallbackClose(stage)
  # Fixture approval is a test host decision, not inferred by the reader.
  authorize<-function(context){checks<<-checks+1L;approved}
  transport<-f('.saved_artifact_transport')(x$directory,x$context,authorize)
  reader<-f('.saved_reader')(transport,cacheBytes=12000L);on.exit(reader$close(),add=TRUE)
  first<-reader$scan('concept_catalogue',limit=3L)
  stopifnot(length(first$pages)==3L,!first$complete,!is.null(first$cursor),first$budget$objects<12L,first$budget$bytes<262144L)
  ids<-unlist(lapply(first$pages,function(p)p$document$entries[[1]]$concept_tag$value));cursor<-first$cursor
  repeat {
    result<-reader$scan('concept_catalogue',limit=16L,cursor=cursor)
    ids<-c(ids,unlist(lapply(result$pages,function(p)p$document$entries[[1]]$concept_tag$value)))
    stopifnot(result$budget$objects<=64L,result$budget$rows<=8192L,reader$inspect()$cache_bytes<=12000L,reader$inspect()$cache_objects<=64L)
    if(result$complete)break
    cursor<-result$cursor
  }
  stopifnot(identical(ids,as.character(1:130)),reader$inspect()$cache_hits>0L,checks>10L)
  # Semantic selection belongs to a later layer; these return complete partitions.
  result<-reader$scan('data');stopifnot(result$pages[[1]]$document$rows[[1]]$values$person_count=='9007199254740993')
  stopifnot(reader$scan('terminology')$complete,length(reader$scan('terminology')$pages)==0L)
  key<-f('.v2_component')(o(kind='id',value='77'),'concept_tag')
  exact<-reader$scan('concept_catalogue',lower=key,upper=key)
  stopifnot(length(exact$pages)==1L,exact$pages[[1]]$document$entries[[1]]$concept_tag$value=='77',exact$budget$objects<8L)
  cursor<-reader$scan('concept_catalogue')$cursor
  fail(function()reader$scan('terminology',cursor=cursor),'invalid_cursor')
  for(change in c('instance_id','authorization_epoch','access_scope_id','source_id','publication_id','release_id')) {
    ctx<-x$context;ctx[[change]]<-if(grepl('_id$',change)&&change%in%c('publication_id','release_id'))'00000000-0000-4000-8000-000000000099' else 'changed'
    r<-f('.saved_reader')(f('.saved_artifact_transport')(x$directory,ctx,function(c)TRUE));on.exit(r$close(),add=TRUE)
    fail(function()r$scan('concept_catalogue',cursor=cursor),'invalid_cursor')
    if(change%in%c('access_scope_id','source_id','publication_id','release_id'))fail(function()r$root(),'integrity_failure')
  }
  for(token in c(paste0(cursor,'x'),'invalid',strrep('a',8193)))fail(function()reader$scan('concept_catalogue',cursor=token),'invalid_cursor')
  for(args in list(list(branch='unknown'),list(branch='data',limit=0L),list(branch='data',limit=17L),list(branch='data',lower='z',upper='a'),list(branch='data',lower=strrep('x',2049L))))fail(function()do.call(reader$scan,args),'invalid_request')
  fail(function()reader$root(cancel=function()NA),'invalid_request')
  # Empty and singleton catalogue roots, plus a one-child second index level.
  for(n in c(1L,129L)) {
    z<-make(n=n);r<-f('.saved_reader')(f('.saved_artifact_transport')(z$directory,z$context,function(c)TRUE));on.exit(r$close(),add=TRUE)
    k<-f('.v2_component')(o(kind='id',value=as.character(n)),'concept_tag')
    page<-r$scan('concept_catalogue',lower=k,upper=k)
    stopifnot(length(page$pages)==1L,page$complete,page$pages[[1]]$document$entries[[1]]$concept_tag$value==as.character(n))
  }
  reader$root();approved<-FALSE
  fail(function()reader$root(),'inaccessible');stopifnot(reader$inspect()$cache_bytes==0L)
  approved<-TRUE;reader$root()
  fail(function()reader$root(cancel=function()TRUE),'aborted');stopifnot(reader$inspect()$cache_bytes==0L)
  reader$close();reader$close();fail(function()reader$root(),'closed')
  # Late cancellation/context invalidation discards bytes, including cache hits.
  cancelled<-FALSE;reads<-0L
  late<-f('.saved_transport')(x$context,function(c)TRUE,function(d){reads<<-reads+1L;cancelled<<-TRUE;f('.v2_safe_file')(x$directory,paste0('objects/',d$sha256,'.json'),4194304L)})
  r<-f('.saved_reader')(late);on.exit(r$close(),add=TRUE)
  fail(function()r$root(cancel=function()cancelled),'aborted');stopifnot(reads==1L,r$inspect()$cache_bytes==0L)
  closing<-NULL
  t<-f('.saved_transport')(x$context,function(c)TRUE,function(d){closing$close();f('.v2_safe_file')(x$directory,paste0('objects/',d$sha256,'.json'),4194304L)})
  closing<-f('.saved_reader')(t);fail(function()closing$root(),'closed');stopifnot(closing$inspect()$cache_bytes==0L)
  for(options in list(list(maxObjects=1L),list(maxBytes=32L),list(maxRows=1L))) {
    r<-do.call(f('.saved_reader'),c(list(transport=transport),options));on.exit(r$close(),add=TRUE)
    fail(function()r$scan('concept_catalogue',limit=2L),'resource_limit');stopifnot(r$inspect()$cache_bytes==0L)
  }
  # Rehashed structural/row/context faults still fail behind apparently valid pins.
  for(bad in c('row','context','range','overlap','rows','unknown_field','fanout','depth','policy')) {
    z<-make(bad);r<-f('.saved_reader')(f('.saved_artifact_transport')(z$directory,z$context,function(c)TRUE));on.exit(r$close(),add=TRUE)
    fail(function()r$scan(if(bad=='policy')'data' else 'concept_catalogue'),'integrity_failure')
  }
  for(bad in c('label_state_type','row_state_type','ref_type','version_type','catalogue_state_type','root_count_type','root_scope_type')) {
    z<-make(bad,n=1L);r<-f('.saved_reader')(f('.saved_artifact_transport')(z$directory,z$context,function(c)TRUE));on.exit(r$close(),add=TRUE)
    branch<-if(bad%in%c('row_state_type','ref_type','version_type'))'data' else if(bad=='catalogue_state_type')'metric_catalogue' else 'concept_catalogue'
    fail(function()r$scan(branch),'integrity_failure')
  }
  for(bad in list(o(sha256='../escape',bytes='2',kind='root',rows='0'),o(sha256=strrep('a',64),bytes=strrep('9',513),kind='root',rows='0'))) {
    ctx<-x$context;ctx$root<-bad;fail(function()f('.saved_artifact_transport')(x$directory,ctx,function(c)TRUE))
  }
  fail(function()f('.saved_artifact_transport')(x$directory,x$context,NULL))
  # Remote/host exception bodies must not escape in classified errors.
  for(stage in c('authority','fetch')) {
    t<-f('.saved_transport')(x$context,if(stage=='authority')function(c)stop('SECRET-fixture-credential') else function(c)TRUE,
      function(d)stop('SECRET-fixture-query'))
    r<-f('.saved_reader')(t);on.exit(r$close(),add=TRUE)
    e<-fail(function()r$root(),if(stage=='authority')'inaccessible' else 'unavailable')
    stopifnot(!grepl('SECRET',conditionMessage(e)),is.null(e$call),setequal(names(e),c('message','call','code')))
  }
  for(n in c('profile_id','profile_revision','profile_sha256')) {
    ctx<-x$context;ctx[[n]]<-'wrong';fail(function()f('.saved_artifact_transport')(x$directory,ctx,function(c)TRUE))
  }
  z<-make(n=1L);rootFile<-file.path(z$directory,'objects',paste0(z$context$root$sha256,'.json'))
  original<-readBin(rootFile,'raw',n=262145L)
  r<-f('.saved_reader')(f('.saved_artifact_transport')(z$directory,z$context,function(c)TRUE),cacheBytes=0L);on.exit(r$close(),add=TRUE)
  writeBin(c(original,as.raw(32)),rootFile);fail(function()r$root(),'integrity_failure')
  unlink(rootFile);other<-tempfile('outside-',folder);writeBin(original,other);stopifnot(file.symlink(other,rootFile))
  fail(function()r$root(),'unavailable')
  unlink(rootFile);writeBin(as.raw(rep(32L,262145L)),rootFile);fail(function()r$root(),'unavailable')
  # An empty branch's bytes must be checked, not trusted from rows="0" alone.
  emptyPath<-file.path(z$directory,'objects',paste0(z$root$terminology$sha256,'.json'));writeBin(charToRaw('bad'),emptyPath)
  writeBin(original,rootFile);fail(function()r$scan('terminology'),'integrity_failure')
  cat('SAVED_TRANSPORT_PAGINATION_CONTEXT_CURSOR_CACHE_BUDGETS_ABORT_CORRUPTION_OK failures=',failures,'\n')
})
