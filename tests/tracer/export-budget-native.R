# Real page production and public publication, with filesystem totals and exact
# database bytes. Repeated emitter calls prove cap invariance, not an independent
# numerical oracle; existing fixture/oracle tests retain that responsibility.
testExportBudgetIntegration <- function(details,schema,release,root,policy,q,savedTerminology=NULL,label='base') {
 ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);lit<-f('.store_literal')
 uuid<-f('.store_new_uuid');stamp<-f('.stamp');io<-f('.export_io');frozenTime<-stamp()
 on.exit({assignInNamespace('.store_new_uuid',uuid,ns='AchillesNext');assignInNamespace('.stamp',stamp,ns='AchillesNext');assignInNamespace('.export_io',io,ns='AchillesNext')})
 assignInNamespace('.stamp',function()frozenTime,ns='AchillesNext')
 ref<-file.path(root,paste0('export-budget-',label,'-reference'));stopifnot(dir.create(ref),dir.create(file.path(ref,'objects')))
 publication<-uuid();scope<-paste0('fixture-budget-',label);approval<-'synthetic-export-budget'
 descriptor<-f('.store_transaction')(details,schema,function(tx) {
  validated<-f('.store_validate')(tx,release)
  f('.store_build_pages')(tx,validated,publication,scope,approval,policy,ref,savedTerminology,maxExportBytes=2^53-1)
 },isolation=2L)
 validateResultArtifact(ref)
 paths<-sort(list.files(ref,recursive=TRUE));sizes<-file.info(file.path(ref,paths))$size;needed<-sum(sizes)
 pointerBytes<-file.info(file.path(ref,'publication.json'))$size
 kinds<-vapply(paths[startsWith(paths,'objects/')],function(path)f('.nv_json')(readBin(file.path(ref,path),'raw',n=file.info(file.path(ref,path))$size))$kind,'')
 stopifnot(setequal(unique(kinds),c('root','index','data','metric_catalogue','concept_catalogue','terminology')),needed>pointerBytes)
 approvals<-0L
 call<-function(destination,limit,id=uuid(),cancel=function()FALSE) {
  assignInNamespace('.store_new_uuid',function()id,ns='AchillesNext')
  on.exit(assignInNamespace('.store_new_uuid',uuid,ns='AchillesNext'))
  publishResultRelease(details,schema,release,destination,scope,approval,policy,function(candidate){approvals<<-approvals+1L;TRUE},
    savedTerminology=savedTerminology,cancel=cancel,maxExportBytes=limit)
 }
 exact<-call(file.path(root,paste0('export-budget-',label,'-exact')),needed,publication)
 stopifnot(approvals==1L,identical(descriptor,exact$root),identical(paths,sort(list.files(exact$export_dir,recursive=TRUE))))
 for(path in paths)stopifnot(identical(readBin(file.path(ref,path),'raw',n=file.info(file.path(ref,path))$size),
   readBin(file.path(exact$export_dir,path),'raw',n=file.info(file.path(exact$export_dir,path))$size)))
 plus<-call(file.path(root,paste0('export-budget-',label,'-plus-one')),needed+1)
 for(published in list(exact,plus)) {
  validateResultArtifact(published$export_dir)
  stopifnot(sum(file.info(list.files(published$export_dir,recursive=TRUE,full.names=TRUE))$size)==needed)
  f('.v2_directory')(published$export_dir,function(d,bytes) {
   stored<-q(paste0("SELECT encode(payload,'hex') AS value FROM ",schema,'.achillesnext_page_object WHERE publication_id=',lit(published$publication_id),' AND sha256=',lit(d$sha256)))$VALUE
   stopifnot(identical(stored,paste(sprintf('%02x',as.integer(bytes)),collapse='')))
  })
 }
 current<-function()q(paste0('SELECT source_id,profile_id,scope_id,publication_id::text,revision::text FROM ',schema,'.achillesnext_current_publication ORDER BY source_id,profile_id,scope_id'))
 counts<-function()c(q(paste0('SELECT count(*)::text AS n FROM ',schema,'.achillesnext_publication'))$N,
   q(paste0('SELECT count(*)::text AS n FROM ',schema,'.achillesnext_page_object'))$N)
 before<-current();beforeCounts<-counts();baseline<-nrow(showConnections());results<-list()
 modes<-c('zero','pointer_overflow','write_warning','predicate_cancel')
 if(.Platform$OS.type=='unix')modes<-c(modes,'open_sigint')
 for(mode in modes) {
  approvals<-0L;opened<-character();fired<-FALSE;cancelled<-FALSE
  assignInNamespace('.export_io',function(work) {
   symbols<-all.names(body(work))
   if('file'%in%symbols)opened<<-c(opened,basename(get('path',environment(work))))
   if(!fired&&mode=='write_warning'&&'writeBin'%in%symbols) {
    fired<<-TRUE;return(io(function(){work();warning('PRIVATE_EXPORT_WRITE_SENTINEL')}))
   }
   value<-io(work)
   if(!fired&&mode=='predicate_cancel'&&'writeBin'%in%symbols){fired<<-TRUE;cancelled<<-TRUE}
   if(!fired&&mode=='open_sigint'&&'file'%in%symbols){fired<<-TRUE;stopifnot(tools::pskill(Sys.getpid(),tools::SIGINT));Sys.sleep(0)}
   value
  },ns='AchillesNext')
  destination<-file.path(root,paste0('export-budget-',label,'-',mode));limit<-if(mode=='zero')0 else if(mode=='pointer_overflow')needed-1 else needed
  error<-tryCatch({call(destination,limit,cancel=function()cancelled);Sys.sleep(0);NULL},error=identity,interrupt=identity)
  assignInNamespace('.export_io',io,ns='AchillesNext')
  stopifnot(inherits(error,'error'),approvals==0L,!dir.exists(destination),identical(before,current()),identical(beforeCounts,counts()),
    !length(Sys.glob(file.path(root,'.achilles-export-*'))),nrow(showConnections())==baseline,
    !grepl('PRIVATE_EXPORT_',conditionMessage(error),fixed=TRUE),is.null(error$call),is.null(error$parent))
  if(mode%in%c('zero','pointer_overflow','write_warning'))stopifnot(inherits(error,'achillesnext_export_error'),error$code==if(mode=='write_warning')'io_failure' else 'byte_limit')
  if(mode=='zero')stopifnot(!length(opened))
  if(mode=='pointer_overflow')stopifnot(length(opened)==length(paths)-1L,!'publication.json'%in%opened)
  if(mode=='open_sigint')stopifnot(inherits(error,'AchillesPublicationFailure'),error$outcome=='not_committed',error$reason_code=='publication.cancelled')
  if(mode%in%c('write_warning','predicate_cancel','open_sigint'))stopifnot(fired)
  results[[mode]]<-if(inherits(error,'achillesnext_export_error'))error$code else if(inherits(error,'AchillesPublicationFailure'))error$reason_code else 'precommit_cancel'
 }
 cat('EXPORT_BUDGET_NATIVE',label,'bytes=',needed,'objects=',length(paths)-1L,'pointer=',pointerBytes,'EXACT_CAP_WIRE_INVARIANCE_DB_BYTES_PRECOMMIT_PRESERVATION_OK\n')
 invisible(list(bytes=needed,objects=length(paths)-1L,pointer_bytes=pointerBytes,kinds=sort(unique(kinds)),failures=results))
}

# Grow a real saved aggregate release, not a copied artifact inventory. Additional
# zero-valued gender strata preserve the independent fixture's exact PERSON sum.
testExportBudgetGrowing <- function(details,schema,release,root,policy,q,extra=2300L) {
 ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);o<-f('.object');lit<-f('.store_literal')
 run<-f('.store_new_uuid')();target<-f('.store_new_uuid')()
 f('.store_transaction')(details,schema,function(tx) {
  oldRun<-tx$one(paste0('SELECT run_id::text FROM ',tx$schema,'.achillesnext_result_release WHERE release_id=',lit(release)))
  tx$execute(paste0('INSERT INTO ',tx$schema,'.achillesnext_analysis_run SELECT (jsonb_populate_record(NULL::',tx$schema,'.achillesnext_analysis_run,to_jsonb(a)||jsonb_build_object(\'run_id\',',lit(run),'))).* FROM ',tx$schema,'.achillesnext_analysis_run a WHERE run_id=',lit(oldRun)))
  tx$execute(paste0('INSERT INTO ',tx$schema,'.achillesnext_result_release VALUES (',lit(target),',',lit(run),",'building',142,0,NULL)"))
  for(table in c('dataset','aggregate_cell','denominator_edge'))tx$execute(paste0('INSERT INTO ',tx$schema,'.achillesnext_',table,
    ' SELECT (jsonb_populate_record(NULL::',tx$schema,'.achillesnext_',table,',to_jsonb(a)||jsonb_build_object(\'release_id\',',lit(target),'))).* FROM ',tx$schema,'.achillesnext_',table,' a WHERE release_id=',lit(release)))
  person<-NULL;f('.store_rows')(tx,release,'core.person.count',function(row,key)person<<-row)
  stopifnot(!is.null(person));assets<-f('.v2_assets')();mid<-'core.person.gender_count';writer<-f('.store_writer')(tx,target,assets)
  for(i in seq_len(extra)) {
   row<-o(row_key='',dimensions=o(gender_concept_id=as.character(1000000L+i)),row_kind='counts',state='computed',reason_code=NULL,
     values=o(person_count='0'),denominator_refs=list(o(measure='person_count',metric_id='core.person.count',row_key=person$row_key,field='person_count',value=person$values$person_count)))
   row$row_key<-f('.v2_row_identity')(assets$rows[[mid]],row);writer$add(mid,row)
  }
  writer$finish();tx$execute(paste0('UPDATE ',tx$schema,'.achillesnext_dataset SET row_count=row_count+',extra,' WHERE release_id=',lit(target),' AND metric_id=',lit(mid)))
 })
 sealResultRelease(details,schema,target);validateResultRelease(details,schema,target)
 count<-q(paste0('SELECT count(*)::text AS n,sum(person_count)::text AS total FROM ',schema,'.achillesnext_aggregate_cell WHERE release_id=',lit(target)," AND metric_id='core.person.gender_count'"))
 stopifnot(count$N==as.character(extra+1L),count$TOTAL==q(paste0('SELECT sum(person_count)::text AS total FROM ',schema,'.achillesnext_aggregate_cell WHERE release_id=',lit(release)," AND metric_id='core.person.gender_count'"))$TOTAL)
 proof<-testExportBudgetIntegration(details,schema,target,root,policy,q,label=paste0('growing-',extra))
 stopifnot(proof$objects>10L)
 cat('EXPORT_BUDGET_GROWING_REAL_AGGREGATE_PUBLICATION_ROWS=',extra+1L,'TOTAL_BYTE_PATH_OK\n')
 invisible(proof)
}
