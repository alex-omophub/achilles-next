# Exact saved-ID lookup and honest name-search absence on approved v2 artifacts.
library(AchillesNext)
source('tests/tracer/saved-result-fixture.R')
local({
  f<-function(n)get(n,asNamespace('AchillesNext'));wire<-f('.v2_bytes')
  folder<-tempfile('saved-concepts-');dir.create(folder);on.exit(unlink(folder,recursive=TRUE))
  x<-makeSavedResultFixture(file.path(folder,'admitted'),extraConceptIds=c('-10','-9','2','10'))
  validateResultArtifact(x$directory)
  attempted<-0L;original<-DatabaseConnector::connect
  assignInNamespace('connect',function(...){attempted<<-attempted+1L;stop('Unexpected connection')},ns='DatabaseConnector')
  on.exit(assignInNamespace('connect',original,ns='DatabaseConnector'),add=TRUE)
  active<-TRUE
  p<-openArtifactResultProvider(x$directory,x$context,function(c)active&&identical(c,x$context));on.exit(p$close(),add=TRUE)
  errors<-0L
  fail<-function(work,code) {
    e<-tryCatch({work();NULL},error=identity)
    stopifnot(inherits(e,'achillesnext_read_error'),identical(e$code,code));errors<<-errors+1L
  }
  ids<-c('9007199254740993','10','2','-9','0','-10','123','999')
  expected<-c('-10','-9','0','2','10','123','999','9007199254740993')
  collect<-function(limit=25L,maxBytes=1048576L) {
    result<-list();cursor<-NULL;pages<-0L
    repeat {
      page<-p$lookupConcepts(ids,limit=limit,maxBytes=maxBytes,cursor=cursor)
      stopifnot(page$state=='available',!page$generation_requested,length(wire(page))<=maxBytes,
        page$terminology$state=='unavailable',page$terminology$matching=='unavailable',
        page$terminology$label_source$state=='unavailable',page$terminology$vocabulary_release$state=='unavailable')
      result<-c(result,page$concepts);pages<-pages+1L
      if(page$complete)break
      stopifnot(is.character(page$cursor),length(page$concepts)>0L);cursor<-page$cursor
    }
    stopifnot(identical(vapply(result,function(e)e$concept_tag$value,''),expected))
    list(entries=result,pages=pages)
  }
  all<-collect();rows<-collect(limit=2L);stopifnot(rows$pages==4L,identical(all$entries,rows$entries))
  stopifnot(all$entries[[7]]$state=='not_saved',all$entries[[7]]$reason_code=='concept.not_saved',
    all(vapply(all$entries[-7],function(e)e$state=='available'&&is.null(e$label)&&e$label_state=='unavailable',TRUE)))
  # Canonical set identity allows reordered requests; result order is signed ID order.
  first<-p$lookupConcepts(ids,limit=2L)
  nextPage<-p$lookupConcepts(rev(ids),limit=2L,cursor=first$cursor)
  stopifnot(identical(vapply(nextPage$concepts,function(e)e$concept_tag$value,''),c('0','2')))
  singleSizes<-integer();cursor<-NULL
  repeat {
    one<-p$lookupConcepts(ids,limit=1L,cursor=cursor);singleSizes<-c(singleSizes,length(wire(one)))
    if(one$complete)break
    cursor<-one$cursor
  }
  byteLimit<-max(singleSizes)+32L
  byBytes<-collect(maxBytes=byteLimit)
  stopifnot(byBytes$pages>1L,identical(all$entries,byBytes$entries))
  largest<-paste(rep('9',512L),collapse='')
  stopifnot(p$lookupConcepts(largest)$concepts[[1]]$state=='not_saved')
  # No unavailable search is reported as a completed empty match/known vocabulary.
  for(query in c('Diabetes','  Café  ','β blocker',"x%_'; SELECT * FROM person; --")) {
    page<-p$searchConcepts(query)
    stopifnot(page$state=='unavailable',page$reason_code=='terminology.name_index_not_saved',
      !page$searched,!length(page$concepts),is.null(page$cursor),page$complete,
      identical(page$query,query),!page$generation_requested,page$budget$objects==1L,
      page$context$source_id==x$context$source_id)
  }
  for(input in list(NULL,character(),1,NA_character_,c('1','1'),as.character(seq_len(101)),
      '', 'all','null','schema_absent','-0','01','+1',' 1','1\n',paste0(largest,'9'))) {
    fail(function()p$lookupConcepts(input),'invalid_request')
  }
  for(work in list(function()p$lookupConcepts('123',limit=0L),function()p$lookupConcepts('123',limit=101L),
      function()p$lookupConcepts('123',maxBytes=TRUE),function()p$lookupConcepts('123',maxBytes=8388609L),
      function()p$searchConcepts(''),function()p$searchConcepts('  '),function()p$searchConcepts('a\nb'),
      function()p$searchConcepts(1),function()p$searchConcepts(paste(rep('é',129L),collapse='')),
      function()p$searchConcepts('x',limit=101L))) fail(work,'invalid_request')
  invalidUtf8<-rawToChar(as.raw(c(0xc3,0x28)));Encoding(invalidUtf8)<-'UTF-8'
  fail(function()p$searchConcepts(invalidUtf8),'invalid_request')
  cursor<-p$lookupConcepts(ids,limit=2L)$cursor
  fail(function()p$lookupConcepts(ids,limit=2L,cursor=paste0(cursor,'x')),'invalid_cursor')
  cursor<-p$lookupConcepts(ids,limit=2L)$cursor
  fail(function()p$lookupConcepts(ids[-1],limit=2L,cursor=cursor),'invalid_cursor')
  cursor<-p$lookupConcepts(ids,limit=2L)$cursor
  fail(function()p$lookupConcepts(ids,limit=3L,cursor=cursor),'invalid_cursor')
  cursor<-p$lookupConcepts(ids,limit=2L)$cursor
  fail(function()p$searchConcepts('diabetes',cursor=cursor),'invalid_cursor')
  cursor<-p$listMetrics(limit=1L)$cursor
  fail(function()p$lookupConcepts(ids,cursor=cursor),'invalid_cursor')
  changed<-x$context;changed$authorization_epoch<-'2'
  q<-openArtifactResultProvider(x$directory,changed,function(c)TRUE);on.exit(q$close(),add=TRUE)
  cursor<-p$lookupConcepts(ids,limit=2L)$cursor
  fail(function()q$lookupConcepts(ids,limit=2L,cursor=cursor),'invalid_cursor')
  fail(function()p$lookupConcepts('123',maxBytes=10L),'resource_limit')
  fail(function()p$searchConcepts('diabetes',maxBytes=10L),'resource_limit')
  exact<-length(wire(p$lookupConcepts('123')))
  stopifnot(length(wire(p$lookupConcepts('123',maxBytes=exact)))==exact)
  fail(function()p$lookupConcepts('123',maxBytes=exact-1L),'resource_limit')
  exact<-length(wire(p$searchConcepts('diabetes')))
  stopifnot(length(wire(p$searchConcepts('diabetes',maxBytes=exact)))==exact)
  fail(function()p$searchConcepts('diabetes',maxBytes=exact-1L),'resource_limit')
  tiny<-openArtifactResultProvider(x$directory,x$context,function(c)TRUE,readBudget=list(maxObjects=1L));on.exit(tiny$close(),add=TRUE)
  fail(function()tiny$lookupConcepts('123'),'resource_limit')
  stopifnot(tiny$inspect()$cache_bytes==0L)
  # A large (multi-level) fixture proves a selective ID read, not a full scan.
  big<-makeSavedResultFixture(file.path(folder,'many'),pageRows=1L,extraConceptIds=as.character(seq.int(10000L,10300L)))
  validateResultArtifact(big$directory)
  t<-f('.saved_artifact_transport')(big$directory,big$context,function(c)TRUE);read<-t$read;kinds<-character()
  t$read<-function(d,cancel){kinds<<-c(kinds,d$kind);read(d,cancel)}
  selective<-f('.saved_provider')(t);on.exit(selective$close(),add=TRUE)
  page<-selective$lookupConcepts('10299')
  stopifnot(page$concepts[[1]]$state=='available',page$budget$objects<=5L,page$budget$rows==1L,
    !any(kinds%in%c('data','metric_catalogue','terminology')))
  before<-selective$inspect()$fetched_objects;selective$searchConcepts('x')
  stopifnot(selective$inspect()$fetched_objects==before) # root raw-cache, still live host checks
  # Many scattered IDs share one hard budget; exhaustion is never false absence.
  scattered<-as.character(seq.int(10000L,10099L))
  fail(function()selective$lookupConcepts(scattered,limit=100L),'resource_limit')
  stopifnot(selective$inspect()$cache_bytes==0L)
  larger<-openArtifactResultProvider(big$directory,big$context,function(c)TRUE,readBudget=list(maxObjects=128L))
  on.exit(larger$close(),add=TRUE)
  boundedSet<-larger$lookupConcepts(scattered,limit=100L)
  stopifnot(boundedSet$complete,length(boundedSet$concepts)==100L,boundedSet$budget$objects<=104L,
    all(vapply(boundedSet$concepts,function(e)e$state=='available',TRUE)))
  # Older valid exports can have empty concept trees. Absence stays distinct.
  old<-makeSavedResultFixture(file.path(folder,'old'),saveConcepts=FALSE);validateResultArtifact(old$directory)
  legacy<-openArtifactResultProvider(old$directory,old$context,function(c)TRUE);on.exit(legacy$close(),add=TRUE)
  stopifnot(legacy$lookupConcepts('123')$concepts[[1]]$state=='not_saved',legacy$searchConcepts('x')$state=='unavailable')
  # A rehashed label must not silently extend the closed original page format.
  bad<-makeSavedResultFixture(file.path(folder,'unversioned'),fault='unversioned_label')
  rejected<-tryCatch({validateResultArtifact(bad$directory);FALSE},error=function(e)TRUE);stopifnot(rejected)
  corrupt<-openArtifactResultProvider(bad$directory,bad$context,function(c)TRUE);on.exit(corrupt$close(),add=TRUE)
  fail(function()corrupt$lookupConcepts('0'),'integrity_failure')
  stopifnot(corrupt$inspect()$cache_bytes==0L)
  cancelled<-FALSE
  t<-f('.saved_artifact_transport')(x$directory,x$context,function(c)TRUE);rawRead<-t$read
  t$read<-function(d,cancel){b<-rawRead(d,cancel);if(d$kind=='concept_catalogue')cancelled<<-TRUE;b}
  late<-f('.saved_provider')(t);on.exit(late$close(),add=TRUE)
  fail(function()late$lookupConcepts('123',cancel=function()cancelled),'aborted')
  stopifnot(late$inspect()$cache_bytes==0L)
  t<-f('.saved_artifact_transport')(x$directory,x$context,function(c)TRUE);rawRead2<-t$read
  t$read<-function(d,cancel){b<-rawRead2(d,cancel);if(d$kind=='concept_catalogue')closing$close();b}
  closing<-f('.saved_provider')(t);on.exit(closing$close(),add=TRUE)
  fail(function()closing$lookupConcepts('123'),'closed')
  active<-FALSE;fail(function()p$lookupConcepts('123'),'inaccessible');fail(function()p$searchConcepts('x'),'inaccessible')
  active<-TRUE;fail(function()p$lookupConcepts('123',cancel=function()TRUE),'aborted')
  fail(function()p$searchConcepts('x',cancel=function()TRUE),'aborted')
  p$close();fail(function()p$lookupConcepts('123'),'closed');fail(function()p$searchConcepts('x'),'closed')
  stopifnot(attempted==0L)
  cat('SAVED_CONCEPT_LOOKUP_PAGINATION_EXACT_IDS_SELECTIVE_LEGACY_UNAVAILABLE_SEARCH_ZERO_SOURCE_OK errors=',errors,
    ' selective_objects=',page$budget$objects,' selective_bytes=',page$budget$bytes,' selective_rows=',page$budget$rows,'\n')
})
