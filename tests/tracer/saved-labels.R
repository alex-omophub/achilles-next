# Independent opt-in format/name-index proof; no source connections after admission.
library(AchillesNext)
source('tests/tracer/saved-result-fixture.R')
local({
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');wire<-f('.v2_bytes')
  folder<-tempfile('saved-labels-');dir.create(folder);on.exit(unlink(folder,recursive=TRUE))
  labels<-list('0'='  Diabetes  ','123'='diabetes','456'='DIABETES mellitus','1'='β blocker','9007199254740993'='Café','-10'='Cafe\u0301','2'='Éclair')
  for(id in as.character(20:35))labels[[id]]<-paste0('Large label ',id,' ',paste(rep('x',200L),collapse=''))
  x<-makeSavedResultFixture(file.path(folder,'labels'),pageRows=1L,extraConceptIds=c('-10','2',as.character(20:35)),savedLabels=labels)
  validateResultArtifact(x$directory)
  old<-makeSavedResultFixture(file.path(folder,'old'));validateResultArtifact(old$directory)
  original<-DatabaseConnector::connect;attempted<-0L
  assignInNamespace('connect',function(...){attempted<<-attempted+1L;stop('Unexpected source connection')},ns='DatabaseConnector')
  on.exit(assignInNamespace('connect',original,ns='DatabaseConnector'),add=TRUE)
  active<-TRUE;p<-openArtifactResultProvider(x$directory,x$context,function(c)active);on.exit(p$close(),add=TRUE)
  errors<-0L
  fail<-function(work,code=NULL){e<-tryCatch({work();NULL},error=identity);stopifnot(inherits(e,'error'));if(!is.null(code))stopifnot(inherits(e,'achillesnext_read_error'),e$code==code);errors<<-errors+1L}
  lookup<-p$lookupConcepts(c('123','777','999'))
  stopifnot(lookup$terminology$state=='available',lookup$terminology$vocabulary_release$state=='unknown',
    lookup$concepts[[1]]$label=='diabetes',lookup$concepts[[2]]$label_reason_code=='terminology.id_not_in_snapshot',lookup$concepts[[3]]$state=='not_saved')
  collect<-function(query=' DIAB ',limit=25L,maxBytes=1048576L) {
    cursor<-NULL;entries<-list();pages<-0L
    repeat {
      page<-p$searchConcepts(query,limit=limit,maxBytes=maxBytes,cursor=cursor)
      stopifnot(page$state=='available',page$searched,page$terminology$matching=='ascii-fold-prefix-v1',
        length(wire(page))<=maxBytes,identical(page$query,query),!page$generation_requested)
      entries<-c(entries,page$concepts);pages<-pages+1L
      if(page$complete)break
      stopifnot(length(page$concepts)>0L);cursor<-page$cursor
    }
    list(entries=entries,pages=pages)
  }
  whole<-collect();paged<-collect(limit=1L)
  stopifnot(length(whole$entries)==3L,identical(whole$entries,paged$entries),paged$pages==3L,
    identical(vapply(whole$entries,function(e)e$concept_tag$value,''),c('0','123','456')),
    whole$entries[[1]]$label=='  Diabetes  ')
  one<-p$searchConcepts('Large',limit=1L)
  byteLimit<-length(wire(one))+64L;byBytes<-collect(query='Large',maxBytes=byteLimit)
  stopifnot(byBytes$pages>1L,identical(byBytes$entries,collect(query='Large')$entries))
  stopifnot(length(p$searchConcepts('β b')$concepts)==1L,length(p$searchConcepts('Café')$concepts)==1L,
    length(p$searchConcepts('Cafe\u0301')$concepts)==1L,!length(p$searchConcepts('CAFÉ')$concepts),
    !length(p$searchConcepts('éclair')$concepts),length(p$searchConcepts('Écl')$concepts)==1L,
    !length(p$searchConcepts('mellitus')$concepts),!length(p$searchConcepts('diab%')$concepts),!length(p$searchConcepts('123')$concepts))
  empty<-p$searchConcepts('not present');stopifnot(empty$searched,empty$state=='available',empty$complete,is.null(empty$cursor))
  # Case/ASCII-space equivalent queries share a normalized continuation identity.
  first<-p$searchConcepts('DIAB',limit=1L);nextPage<-p$searchConcepts(' diab ',limit=1L,cursor=first$cursor)
  stopifnot(nextPage$concepts[[1]]$concept_tag$value=='123')
  fail(function()p$searchConcepts('other',limit=1L,cursor=first$cursor),'invalid_cursor')
  cursor<-p$searchConcepts('diab',limit=1L)$cursor
  fail(function()p$searchConcepts('diab',limit=2L,cursor=cursor),'invalid_cursor')
  cursor<-p$lookupConcepts(c('0','123'),limit=1L)$cursor
  fail(function()p$searchConcepts('diab',limit=1L,cursor=cursor),'invalid_cursor')
  fail(function()p$searchConcepts('diab',maxBytes=10L),'resource_limit')
  tiny<-openArtifactResultProvider(x$directory,x$context,function(c)TRUE,readBudget=list(maxObjects=2L));on.exit(tiny$close(),add=TRUE)
  fail(function()tiny$searchConcepts('diab'),'resource_limit');stopifnot(tiny$inspect()$cache_bytes==0L)
  for(fault in c('extra_concept','missing_concept','missing_name_index','wrong_name_label','mixed_version')) {
    bad<-makeSavedResultFixture(file.path(folder,fault),pageRows=1L,savedLabels=labels,fault=fault)
    fail(function()validateResultArtifact(bad$directory))
    if(fault=='wrong_name_label') {
      q<-openArtifactResultProvider(bad$directory,bad$context,function(c)TRUE)
      fail(function()q$searchConcepts('Wrong'),'integrity_failure');q$close()
    }
  }
  unknown<-o(state='unknown',value=NULL,basis=NULL,assertion_id=NULL,reason_code='fixture.unknown')
  known<-function(value)o(state='known',value=value,basis='fixture',assertion_id='fixture-review',reason_code=NULL)
  fail(function()f('.term_identity')(c(known('v1'),o(value='v2'))))
  f('.term_vocab_match')(o(vocabulary_release=known('v1')),o(vocabulary_release=unknown))
  fail(function()f('.term_vocab_match')(o(vocabulary_release=known('v1')),o(vocabulary_release=known('v2'))))
  # Snapshot parser proves bytes/identity/order/line bounds without a DB.
  path<-file.path(folder,'snapshot.jsonl')
  header<-o(contract_version='1.0.0',kind='concept_snapshot',source_id=x$context$source_id,release_id=x$context$release_id,
    label_source=unknown,vocabulary_release=unknown,capture=o(captured_at='2026-01-01T00:00:00.000Z',within_capture='single_repeatable_read',with_aggregate_release='not_asserted'))
  oversized<-header;control<-paste(rep('\001',256L),collapse='')
  oversized$label_source<-oversized$vocabulary_release<-o(state='known',value=control,basis=control,assertion_id=control,reason_code=NULL)
  fail(function()f('.term_header')(oversized))
  entry<-whole$entries[[1]];writeBin(c(wire(header),wire(entry)),path)
  snapshot<-list(path=path,sha256=digest::digest(file=path,algo='sha256'),rows='1');seen<-0L
  fail(function()f('.term_snapshot')(c(snapshot,list(path='ignored')),function(...)NULL))
  f('.term_snapshot')(snapshot,function(e,key,h){seen<<-seen+1L;stopifnot(identical(e,entry))});stopifnot(seen==1L)
  fail(function()f('.term_snapshot')(list(path=path,sha256=strrep('0',64)),function(...)NULL))
  for(payload in list(c(wire(header),wire(entry),wire(entry)),c(wire(header),charToRaw(paste(rep('x',8193L),collapse=''))),head(c(wire(header),wire(entry)),-1L))) {
    writeBin(payload,path);s<-list(path=path,sha256=digest::digest(file=path,algo='sha256'))
    fail(function()f('.term_snapshot')(s,function(...)NULL))
  }
  cancelled<-FALSE;t<-f('.saved_artifact_transport')(x$directory,x$context,function(c)TRUE);read<-t$read
  t$read<-function(d,cancel){bytes<-read(d,cancel);if(d$kind=='terminology')cancelled<<-TRUE;bytes}
  late<-f('.saved_provider')(t);on.exit(late$close(),add=TRUE)
  fail(function()late$searchConcepts('diab',cancel=function()cancelled),'aborted')
  active<-FALSE;fail(function()p$searchConcepts('diab'),'inaccessible')
  p$close();fail(function()p$searchConcepts('diab'),'closed')
  legacy<-openArtifactResultProvider(old$directory,old$context,function(c)TRUE);on.exit(legacy$close(),add=TRUE)
  stopifnot(legacy$searchConcepts('diab')$state=='unavailable',legacy$lookupConcepts('123')$concepts[[1]]$label_state=='unavailable',attempted==0L)
  # Full-length multilingual labels and large IDs exceed old key lengths.
  bigId<-paste(rep('9',512L),collapse='');longIds<-c(as.character(40:79),bigId);longLabels<-list()
  for(i in seq_along(longIds))longLabels[[longIds[[i]]]]<-paste0(paste(rep('💡',255L),collapse=''),sprintf('%04d',i))
  long<-makeSavedResultFixture(file.path(folder,'long-labels'),pageRows=1L,extraConceptIds=longIds,savedLabels=longLabels)
  validateResultArtifact(long$directory)
  longProvider<-openArtifactResultProvider(long$directory,long$context,function(c)TRUE);on.exit(longProvider$close(),add=TRUE)
  cursor<-NULL;longCount<-0L
  repeat {
    page<-longProvider$searchConcepts('💡',limit=1L,cursor=cursor);longCount<-longCount+length(page$concepts)
    if(page$complete)break
    cursor<-page$cursor
  }
  stopifnot(longCount==length(longIds),nchar(f('.term_name_key')(longProvider$lookupConcepts(bigId)$concepts[[1]][c('concept_tag','label')]),type='bytes')>2048L)
  # Producer insert bounds include SQL escaping, prefix and separators.
  statements<-0L
  writer<-f('.term_temp_writer')(list(execute=function(sql){stopifnot(nchar(sql,type='bytes')<=262144L);statements<<-statements+1L}),'achillesnext_term_input')
  quoted<-o(concept_tag=o(kind='id',value='0'),label=paste(rep("'",1024L),collapse=''),label_state='available',label_reason_code=NULL,
    domain_id=paste(rep("'",128L),collapse=''),vocabulary_id=paste(rep("'",128L),collapse=''))
  for(i in seq_len(1000L)){quoted$concept_tag$value<-as.character(i);key<-f('.term_entry')(quoted,'concept_catalogue','2.1.0');writer$add(key,quoted,f('.term_name_key')(quoted))}
  writer$finish();stopifnot(statements>8L)
  # Shared structural vectors are checked independently with Ajv in CI.
  rootDoc<-f('.nv_json')(readBin(file.path(x$directory,'objects',paste0(x$context$root$sha256,'.json')),'raw',n=262145L))
  cases<-list()
  add<-function(kind,value,valid) {
    native<-tryCatch({switch(kind,concept_entry=f('.term_entry')(value,'concept_catalogue','2.1.0'),
      name_entry=f('.term_entry')(value,'terminology','2.1.0'),metadata=f('.term_metadata')(value),snapshot_header=f('.term_header')(value));TRUE},error=function(e)FALSE)
    stopifnot(identical(native,valid));cases[[length(cases)+1L]]<<-o(kind=kind,value=value,valid=valid)
  }
  entry<-whole$entries[[1]];missing<-lookup$concepts[[2]][c('concept_tag','label','label_state','label_reason_code','domain_id','vocabulary_id')]
  add('concept_entry',entry,TRUE);add('name_entry',entry,TRUE);add('concept_entry',missing,TRUE);add('name_entry',missing,FALSE)
  bad<-entry;bad$vocabulary_id<-NULL;add('concept_entry',bad,FALSE)
  bad<-entry;bad$concept_tag$value<-123;add('concept_entry',bad,FALSE)
  bad<-entry;bad$label_state<-'unavailable';add('concept_entry',bad,FALSE)
  bad<-missing;bad['label_reason_code']<-list(NULL);add('concept_entry',bad,FALSE)
  bad<-entry;bad$extra<-'forbidden';add('concept_entry',bad,FALSE)
  add('metadata',rootDoc$saved_terminology,TRUE)
  bad<-rootDoc$saved_terminology;bad$matching<-'other';add('metadata',bad,FALSE)
  bad<-rootDoc$saved_terminology;bad$extension_version<-'1.1.0';add('metadata',bad,FALSE)
  bad<-rootDoc$saved_terminology;bad$label_source<-known('fixture-vocab');add('metadata',bad,TRUE)
  bad$label_source['value']<-list(NULL);add('metadata',bad,FALSE)
  add('snapshot_header',header,TRUE)
  bad<-header;bad$release_id<-'not-a-uuid';add('snapshot_header',bad,FALSE)
  arguments<-commandArgs(TRUE);if(length(arguments))writeBin(wire(cases),arguments[[1]])
  cat('SAVED_LABELS_VERSION_COMPATIBILITY_NAME_PREFIX_PAGINATION_PROVENANCE_SNAPSHOT_BOUNDS_ZERO_SOURCE_OK errors=',errors,'\n')
})
