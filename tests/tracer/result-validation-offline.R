# Focused regressions for publication review findings; no database or Node.
library(AchillesNext)
local({
 ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);o<-f('.object');a<-f('.v2_assets')()
 rejects<-function(work,pattern) {
   message<-tryCatch({work();'ACCEPTED'},error=conditionMessage)
   stopifnot(message!='ACCEPTED',grepl(pattern,message,fixed=TRUE))
 }
 # The profile must match the independent lock, not a hash recomputed from itself.
 root<-tempfile('profile-lock-');dir.create(root);on.exit(unlink(root,recursive=TRUE))
 profile<-file.path(root,'alpha-measurement-v1.json')
 file.copy(system.file('analysis/alpha-measurement-v1.json',package='AchillesNext'),profile)
 lock<-system.file('analysis/manifest-lock.json',package='AchillesNext')
 f('.nv_locked_profile')(profile,lock)
 cat('\n',file=profile,append=TRUE)
 rejects(function()f('.nv_locked_profile')(profile,lock),'Frozen profile integrity mismatch')
 # Only the optional CARE_SITE row may be unavailable, not the entire panel.
 mid<-'core.visit.care_setting_count';m<-a$metrics[[mid]]
 d<-o(metric_id=mid,version=m$version,population=m$population,grain=m$grain,row_schema_id=a$rows[[mid]]$row_schema_id,definition_sha256=f('.v2_hash')(f('.v2_bytes')(m)),state='unsupported',reason_code='fixture.absent',required=TRUE,conditional_support=o(state='schema_absent',reason_code='fixture.absent'),rows='0',completeness=o(scope_kind='schema_conditional',complete=TRUE,excluded_record_count=NULL,reason_code='fixture.absent'))
 rejects(function()f('.v2_dataset')(d),'Required base marginals cannot be unsupported')
 ds<-list('core.source.capabilities'=o(state='suppressed'))
 rejects(function()f('.v2_capability_check')(ds,list()),'Capability inventory is required')
 f('.v2_capability_check')(ds,list(),requireEvidence=FALSE)
 # A streamed denominator includes target dimensions. No tx$one round trip.
 row<-o(row_key='',dimensions=o(gender_concept_id='0'),row_kind='counts',state='computed',reason_code=NULL,values=o(person_count='1'),denominator_refs=list(o(measure='person_count',metric_id='core.person.count',row_key=strrep('a',64),field='person_count',value='10')))
 row$row_key<-f('.v2_row_identity')(a$rows[['core.person.gender_count']],row)
 numeric<-structure(rep(list(NULL),14),names=c('record_count','person_count','person_days','interval_count','n','sum','min','max','p10','p25','p50','p75','p90','unused'))
 numeric$person_count<-'1';numeric$unused<-NULL
 ref<-c(row$denominator_refs[[1]],o(target_dimensions=o()))
 stored<-o(row_key=row$row_key,dimensions=row$dimensions,state='computed',reason_code=NULL,payload_kind='counts',route_key='A',sort_key=f('.v2_sort')(a$rows[['core.person.gender_count']],row),metadata=NULL,numeric=numeric,denominator_refs=list(ref))
 calls<-0L;received<-FALSE
 tx<-list(schema='"fixture"',one=function(...)stop('N+1 query attempted'),stream=function(sql,visit){calls<<-calls+1L;stopifnot(grepl("'target_dimensions',t.dimensions",sql,fixed=TRUE));visit(f('.json')(stored))})
 f('.store_rows')(tx,'00000000-0000-4000-8000-000000000001','core.person.gender_count',function(r,key){received<<-TRUE;stopifnot(identical(f('.json')(r),f('.json')(row)))})
 stopifnot(calls==1L,received)
 policy<-o(id='fixture',revision='1',scope_kind='restricted',allow_metrics=list('core.person.count'))
 path<-file.path(root,'PRIVATE_PATH_SENTINEL','export')
 rejects(function()publishResultRelease(list(dbms='postgresql'),'fixture','00000000-0000-4000-8000-000000000001',path,'fixture','fixture',policy,function(c)TRUE),'Export parent directory is unavailable')
 cat('PR16_OFFLINE_LOCK_CAPABILITY_MARGINAL_STREAM_AND_DIAGNOSTIC_REGRESSIONS_OK\n')
})

# One export quota spans real canonical objects of every kind and the pointer.
source('tests/tracer/saved-result-fixture.R')
local({
 ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns)
 root<-tempfile('export-budget-');dir.create(root);on.exit(unlink(root,recursive=TRUE))
 fixture<-makeSavedResultFixture(file.path(root,'fixture'),pageRows=1L,extraConceptIds=as.character(20:25),savedLabels=list('123'='Approved name'))
 objects<-list.files(file.path(fixture$directory,'objects'),full.names=TRUE)
 paths<-c(objects,file.path(fixture$directory,'publication.json'));sizes<-file.info(paths)$size;total<-sum(sizes)
 kinds<-vapply(objects,function(path)f('.nv_json')(readBin(path,'raw',n=file.info(path)$size))$kind,'')
 stopifnot(setequal(unique(kinds),c('root','index','data','metric_catalogue','concept_catalogue','terminology')))
 fail<-function(work,code=NULL) {
  e<-tryCatch({work();NULL},error=identity);stopifnot(inherits(e,'error'))
  if(!is.null(code))stopifnot(inherits(e,'achillesnext_export_error'),e$code==code,is.null(e$call),is.null(e$parent),!grepl(root,conditionMessage(e),fixed=TRUE))
  invisible(e)
 }
 for(value in list(-1,NA_real_,NaN,Inf,1.5,1+0i,2^53,'100',numeric()))fail(function()f('.export_writer')(value))
 for(limit in c(total,total+1)) {
  directory<-file.path(root,paste0('accepted-',limit));dir.create(directory);dir.create(file.path(directory,'objects'))
  writer<-f('.export_writer')(limit)
  for(path in paths)writer$write(file.path(directory,if(basename(path)=='publication.json')'publication.json' else file.path('objects',basename(path))),readBin(path,'raw',n=file.info(path)$size))
  stopifnot(writer$inspect()$bytes==total,writer$inspect()$files==length(paths),sum(file.info(list.files(directory,recursive=TRUE,full.names=TRUE))$size)==total)
  for(path in paths) {
   copy<-file.path(directory,if(basename(path)=='publication.json')'publication.json' else file.path('objects',basename(path)))
   stopifnot(identical(readBin(path,'raw',n=file.info(path)$size),readBin(copy,'raw',n=file.info(copy)$size)))
  }
  validateResultArtifact(directory)
 }
 directory<-file.path(root,'pointer-one-over');dir.create(directory);dir.create(file.path(directory,'objects'));writer<-f('.export_writer')(total-1)
 for(path in objects)writer$write(file.path(directory,'objects',basename(path)),readBin(path,'raw',n=file.info(path)$size))
 fail(function()writer$write(file.path(directory,'publication.json'),readBin(tail(paths,1),'raw',n=tail(sizes,1))),'byte_limit')
 stopifnot(!file.exists(file.path(directory,'publication.json')),writer$inspect()$bytes==sum(head(sizes,-1)),writer$inspect()$files==length(objects))
 writer<-f('.export_writer')(0);path<-file.path(root,'zero');fail(function()writer$write(path,charToRaw('x')),'byte_limit')
 stopifnot(!file.exists(path),writer$inspect()$bytes==0,writer$inspect()$files==0)
 # Invalid public controls are rejected before opening a database connection.
 original<-get('connect',asNamespace('DatabaseConnector'));attempts<-0L
 assignInNamespace('connect',function(...){attempts<<-attempts+1L;stop('PRIVATE_CONNECTION')},ns='DatabaseConnector')
 on.exit(assignInNamespace('connect',original,ns='DatabaseConnector'),add=TRUE)
 fail(function()publishResultRelease(list(dbms='postgresql'),'results','00000000-0000-4000-8000-000000000001',file.path(root,'invalid'),
   'scope','approval',list(),function(...)TRUE,maxExportBytes=Inf))
 stopifnot(attempts==0L,!dir.exists(file.path(root,'invalid')))
 cat('EXPORT_BUDGET_ALL_CANONICAL_KINDS_EXACT_PLUS_ONE_POINTER_OVERFLOW_NO_SOURCE_OK\n')
})

# Exercise the actual page producer over a checked synthetic aggregate fixture;
# the SQL seam supplies saved rows, not a prebuilt page inventory.
local({
 ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);o<-f('.object')
 root<-tempfile('export-producer-');dir.create(root);on.exit(unlink(root,recursive=TRUE))
 input<-makeSavedResultFixture(file.path(root,'input'));assets<-f('.v2_assets')();datasets<-list();rows<-list();concepts<-list()
 sourceRoot<-f('.v2_directory')(input$directory,function(d,raw) {
  doc<-f('.nv_json')(raw)
  if(d$kind=='metric_catalogue')for(entry in doc$entries)datasets[[entry$metric_id]]<<-entry
  if(d$kind=='data')rows[[doc$metric_id]]<<-c(rows[[doc$metric_id]],doc$rows)
  if(d$kind=='concept_catalogue')concepts<<-c(concepts,doc$entries)
 })
 context<-c(sourceRoot[f('.saved_common')()],o(observed_schema_sha256=sourceRoot$source_schema$sha256,
   declared_cdm_version=sourceRoot$source_schema$declared_cdm_version,consistency_basis=sourceRoot$source_consistency$within_run))
 tx<-list(stream=function(sql,visit)for(entry in concepts)visit(f('.json')(o(tag=entry$concept_tag,key=f('.v2_component')(entry$concept_tag,'concept_tag')))))
 build<-f('.store_build_pages');scope<-new.env(parent=environment(build));stamp<-f('.stamp')()
 scope$.stamp<-function()stamp
 # The fixture supplies projected rows without a backing SQL store. Exercise
 # the real traversal, including omitted metrics and the default asset registry.
 scans<-character()
 scope$.store_scan_release<-f('.store_scan_release')
 environment(scope$.store_scan_release)<-scope
 scope$.store_rows<-function(tx,releaseId,mid,visit,assets,includeFrame=FALSE) {
  scans<<-c(scans,mid)
  for(row in rows[[mid]]) {
   checked<-f('.v2_row')(mid,row,assets,includeFrame=includeFrame)
   if(includeFrame)visit(row,checked$key,checked$bytes) else visit(row,checked)
  }
 }
 scope$.v2_capability_check<-function(datasets,capabilities)f('.v2_capability_check')(datasets,capabilities,requireEvidence=FALSE)
 scope$.store_summary_checks<-scope$.store_domain_reconcile<-scope$.store_reconcile<-function(...)NULL
 environment(build)<-scope
 run<-function(name,limit) {
  directory<-file.path(root,name);dir.create(directory);dir.create(file.path(directory,'objects'))
  scans<<-character()
  build(tx,list(context=context,datasets=datasets),sourceRoot$publication_id,sourceRoot$access_scope_id,'fixture-budget',
    sourceRoot$disclosure$policy,directory,maxExportBytes=limit)
  stopifnot(identical(scans,sort(names(datasets),method="radix")))
  directory
 }
 generous<-run('generous',1024^3);validateResultArtifact(generous)
 files<-sort(list.files(generous,recursive=TRUE));total<-sum(file.info(file.path(generous,files))$size)
 exact<-run('exact',total);validateResultArtifact(exact)
 stopifnot(identical(files,sort(list.files(exact,recursive=TRUE))))
 for(path in files)stopifnot(identical(readBin(file.path(generous,path),'raw',n=file.info(file.path(generous,path))$size),readBin(file.path(exact,path),'raw',n=file.info(file.path(exact,path))$size)))
 e<-tryCatch(run('pointer-overflow',total-1),error=identity)
 stopifnot(inherits(e,'achillesnext_export_error'),e$code=='byte_limit',!file.exists(file.path(root,'pointer-overflow','publication.json')),
   sum(file.info(list.files(file.path(root,'pointer-overflow','objects'),full.names=TRUE))$size)==total-file.info(file.path(generous,'publication.json'))$size)
 cat('EXPORT_BUDGET_ACTUAL_PAGE_PRODUCER_EXACT_BYTE_INVARIANCE_POINTER_LAST_OK\n')
})

# Real file writes: warning/short-write/close failures are safe and every opened
# handle closes, including a pending actual SIGINT before open returns to owner.
local({
 ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);original<-f('.export_io')
 root<-tempfile('export-io-');dir.create(root);on.exit(unlink(root,recursive=TRUE))
 on.exit(assignInNamespace('.export_io',original,ns='AchillesNext'),add=TRUE)
 baseline<-nrow(showConnections())
 fail<-function(work) {
  e<-tryCatch({work();NULL},error=identity)
  stopifnot(inherits(e,'achillesnext_export_error'),e$code=='io_failure',conditionMessage(e)=='Result export I/O failed',is.null(e$call),is.null(e$parent))
 }
 for(operation in c('file','writeBin','flush','close')) {
  fired<-FALSE;writer<-f('.export_writer')(100)
  assignInNamespace('.export_io',function(work) {
   symbols<-all.names(body(work))
   if(!fired&&(operation%in%symbols||(operation=='close'&&'.v2_scratch_close'%in%symbols))) {
    fired<<-TRUE;return(original(function(){if(operation!='file')work();warning('PRIVATE_EXPORT_PATH');if(operation=='file')work()}))
   }
   original(work)
  },ns='AchillesNext')
  fail(function()writer$write(file.path(root,operation),charToRaw('content')))
  assignInNamespace('.export_io',original,ns='AchillesNext')
  stopifnot(fired,nrow(showConnections())==baseline,writer$inspect()$failed)
 }
 constructor<-f('.export_writer');scope<-new.env(parent=environment(constructor))
 scope$writeBin<-function(object,con,...)base::writeBin(head(object,-1L),con,...)
 environment(constructor)<-scope;writer<-constructor(100)
 fail(function()writer$write(file.path(root,'short-write'),charToRaw('content')))
 stopifnot(writer$inspect()$failed,nrow(showConnections())==baseline)
 if(.Platform$OS.type=='unix') {
  fired<-FALSE;captured<-NULL;writer<-f('.export_writer')(100)
  assignInNamespace('.export_io',function(work) {
   value<-original(work)
   if(!fired&&'file'%in%all.names(body(work))) {
    captured<<-value;fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)
   }
   value
  },ns='AchillesNext')
  out<-tryCatch({writer$write(file.path(root,'interrupted-open'),charToRaw('content'));Sys.sleep(0);list(ok=TRUE)},
   interrupt=function(e)list(ok=FALSE,failure=e),error=function(e)list(ok=FALSE,failure=e))
  assignInNamespace('.export_io',original,ns='AchillesNext')
  stopifnot(fired,!out$ok,inherits(out$failure,'interrupt'),nrow(showConnections())==baseline,
    !tryCatch(isOpen(captured),error=function(e)FALSE))
 }
 # Actual interrupt arriving before close must defer until the owned handle is
 # released, then propagate and poison the failed writer.
 if(.Platform$OS.type=='unix') {
  constructor<-f('.export_writer');scope<-new.env(parent=environment(constructor));closed<-FALSE
  scope$.v2_scratch_close<-function(connection) {
   stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)
   f('.v2_scratch_close')(connection);closed<<-TRUE
  }
  environment(constructor)<-scope;writer<-constructor(100)
  out<-tryCatch({writer$write(file.path(root,'interrupted-close'),charToRaw('content'));Sys.sleep(0);list(ok=TRUE)},
   interrupt=function(e)list(ok=FALSE,failure=e),error=function(e)list(ok=FALSE,failure=e))
  stopifnot(!out$ok,inherits(out$failure,'interrupt'),closed,writer$inspect()$failed,nrow(showConnections())==baseline)
 }
 cancelled<-FALSE;writer<-f('.export_writer')(100,function()f('.term_check')(function()cancelled))
 writer$write(file.path(root,'first'),charToRaw('one'));cancelled<-TRUE
 e<-tryCatch(writer$write(file.path(root,'cancelled'),charToRaw('two')),error=identity)
 stopifnot(inherits(e,'achillesnext_read_error'),e$code=='aborted',!file.exists(file.path(root,'cancelled')),writer$inspect()$bytes==3)
 condition<-simpleError('returned value');stopifnot(identical(original(function()condition),condition))
 cat('EXPORT_BUDGET_IO_SHORT_WRITE_WARN_CLOSE_SIGINT_AND_CANCEL_OWNERSHIP_OK\n')
})

# Row-stream fingerprints are independent of caller chunking and bind both
# metric membership and every byte across complete and partial hash blocks.
local({
 stream<-get('.publication_row_stream',asNamespace('AchillesNext'))
 raw<-c(as.raw(rep(0:255,768L)),as.raw(17L));pieces<-function(data,size) {
  starts<-seq.int(1L,length(data),by=size)
  lapply(starts,function(i)data[seq.int(i,min(length(data),i+size-1L))])
 }
 signature<-function(chunks,mid='a') {
  s<-stream();for(chunk in chunks)s$add(mid,chunk);s$finish()
 }
 want<-signature(list(raw))
 for(size in c(257L,65535L,65536L,65537L))stopifnot(identical(want,signature(pieces(raw,size))))
 for(i in c(65536L,length(raw))) {
  changed<-raw;changed[i]<-as.raw(0L)
  stopifnot(!identical(want,signature(list(changed))))
 }
 stopifnot(!identical(want,signature(list(raw),'b')),
   !identical(want,signature(list(raw[-length(raw)]))))
 s<-stream();s$add('b',raw[1]);error<-tryCatch(s$add('a',raw[1]),error=identity)
 stopifnot(inherits(error,'error'),identical(conditionMessage(error),'Unordered projection metric'))
})
