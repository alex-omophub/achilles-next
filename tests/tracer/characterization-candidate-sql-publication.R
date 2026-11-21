# Join one already generated compiled candidate to the existing publication and
# saved-provider APIs. No additional successful characterization is generated.
testCharacterizationCandidateSqlPublication<-function(env,owner,results,serving,sourceSchema,sourceId,candidate,snapshot,out,
  sourceDetails,storeDetails,readerDetails,roles,input) {
  began<-proc.time()[['elapsed']]
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');wire<-f('.json');lit<-f('.store_literal')
  ex<-function(sql)DatabaseConnector::executeSql(owner,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,'compiled-publication-error.txt'))
  q<-function(sql)DatabaseConnector::querySql(owner,sql,integer64AsNumeric=FALSE,errorReportFile=file.path(out,'compiled-publication-query-error.txt'))
  source('tests/tracer/core-publication.R',local=TRUE)
  ex(paste0('REVOKE USAGE ON SCHEMA "',sourceSchema,'" FROM ',roles$source$user,',achilles_next_runner'))
  for(role in c(roles$source$user,roles$store$user,roles$reader$user,'achilles_next_runner'))
    stopifnot(q(paste0('SELECT has_schema_privilege(',lit(role),',',lit(sourceSchema),",'USAGE')::text AS allowed"))$ALLOWED=='false')
  stopifnot(q(paste0('SELECT has_schema_privilege(',lit(roles$reader$user),',',lit(results),",'USAGE')::text AS allowed"))$ALLOWED=='false')
  # The generic publication helper uses an institution operator. Give it the
  # source-denied store principal, never the source-owning fixture installer.
  operatorEnv<-new.env(parent=env)
  operatorEnv$fixtureConnection<-function(role='owner'){stopifnot(role=='owner');storeDetails}
  proof<-testCorePublication(operatorEnv,owner,results,serving,sourceSchema,sourceId,candidate,snapshot,out)
  full<-proof$publications$full;projected<-proof$publications$projected
  ex(paste0('UPDATE "',results,'".achillesnext_audience_grant SET enabled=true WHERE scope_id=',lit(full$access_scope_id),
    ' AND database_role=',lit(roles$reader$user)))
  pointer<-function()q(paste0('SELECT source_id,profile_id,scope_id,publication_id::text,revision::text FROM "',results,
    '".achillesnext_current_publication ORDER BY source_id,profile_id,scope_id'))
  pages<-function()q(paste0('SELECT publication_id::text,sha256,encode(payload,\'hex\') AS bytes FROM "',results,
    '".achillesnext_page_object ORDER BY publication_id,sha256'))
  beforePointer<-pointer();beforePages<-pages()
  beforeFiles<-sort(list.files(out,all.files=TRUE,no..=TRUE))
  counts<-function()q(paste0('SELECT jsonb_build_object(',paste(vapply(c('source_release','analysis_run','operation','result_release',
    'dataset','aggregate_cell','denominator_edge'),function(table)paste0(lit(table),',',
      '(SELECT count(*)::text FROM "',results,'".achillesnext_',table,')'),''),collapse=','),')::text AS counts'))$COUNTS
  beforeCounts<-counts()
  # A failed newer attempt must leave this compiled publication current and its
  # already pinned objects readable. Cancel after real source callbacks begin.
  columns<-do.call(rbind,lapply(names(input$columns),function(table) {
    x<-input$columns[[table]]
    data.frame(table=table,column=names(x),type=vapply(x,function(t)switch(t,bigint='int8',integer='int4',t),''),
      readable=!table%in%unlist(input$denied_tables),stringsAsFactors=FALSE)
  }))
  ex(paste0('GRANT USAGE ON SCHEMA "',sourceSchema,'" TO ',roles$source$user))
  on.exit(ex(paste0('REVOKE USAGE ON SCHEMA "',sourceSchema,'" FROM ',roles$source$user)),add=TRUE)
  program<-renderCharacterizationSql(sourceSchema,sourceId,input$version,columns)
  generate<-generateCharacterizationCandidateFromSql;scope<-new.env(parent=environment(generate));execute<-executeCharacterizationSql
  cancelled<-FALSE;captured<-0L;sourceCalls<-0L
  scope$executeCharacterizationSql<-function(connectionDetails,program,visit,...) {
    sourceCalls<<-sourceCalls+1L
    execute(connectionDetails,program,function(mid,row) {
      visit(mid,row);captured<<-captured+1L;if(captured==3L)cancelled<<-TRUE
    },...)
  }
  environment(generate)<-scope
  error<-tryCatch({generate(sourceDetails,program,storeDetails,results,scratchParent=out,check=function()!cancelled);NULL},error=identity)
  ex(paste0('REVOKE USAGE ON SCHEMA "',sourceSchema,'" FROM ',roles$source$user))
  stopifnot(inherits(error,'AchillesCandidateFailure'),error$reason_code=='candidate.cancelled',error$outcome=='not_committed',
    error$publication_changed==FALSE,captured==3L,sourceCalls==1L,identical(beforeCounts,counts()),
    identical(beforePointer,pointer()),identical(beforePages,pages()),identical(beforeFiles,sort(list.files(out,all.files=TRUE,no..=TRUE))))
  # All compiled execution is finished before observing saved-reader SQL: the
  # compiler's exact namespace identity remains enforced for every real run.
  ns<-asNamespace('AchillesNext');original<-f('.store_transaction');statements<-character()
  observe<-function(details,schema,work,...)original(details,schema,function(tx) {
    one<-tx$one;tx$one<-function(sql){statements<<-c(statements,sql);one(sql)};work(tx)
  },...)
  assignInNamespace('.store_transaction',observe,ns='AchillesNext')
  on.exit(assignInNamespace('.store_transaction',original,ns='AchillesNext'),add=TRUE)
  providers<-list()
  on.exit(for(pair in providers){pair$file$close();pair$database$close()},add=TRUE,after=FALSE)
  same<-function(a,b) {a$cursor<-b$cursor<-NULL;a$budget<-b$budget<-NULL;stopifnot(identical(wire(a),wire(b)))}
  canonical<-function(rows)sort(vapply(rows,wire,''),method='radix')
  semanticRequests<-0L;discovered<-list()
  for(kind in names(proof$publications)) {
    publication<-proof$publications[[kind]];directory<-file.path(out,publication$directory)
    root<-f('.nv_json')(readBin(file.path(directory,'objects',paste0(publication$root$sha256,'.json')),'raw',n=262145L))
    context<-c(root[f('.saved_common')()],o(root=publication$root,authorization_epoch='1',instance_id=paste0('compiled-',kind)))
    authorized<-local({expected<-context;function(value)identical(value,expected)})
    file<-openArtifactResultProvider(directory,context,authorized)
    database<-openDatabaseResultProvider(readerDetails,serving,context,authorized)
    providers[[kind]]<-list(file=file,database=database,context=context)
    left<-right<-NULL;ids<-character()
    repeat {
      a<-file$listMetrics(limit=17L,cursor=left);b<-database$listMetrics(limit=17L,cursor=right);same(a,b)
      ids<-c(ids,vapply(a$metrics,function(metric)metric$metric_id,''));semanticRequests<-semanticRequests+1L
      if(a$complete)break
      left<-a$cursor;right<-b$cursor
    }
    stopifnot(length(ids)==142L,!anyDuplicated(ids));discovered[[kind]]<-ids
    a<-file$selectSavedRows('core.person.count');b<-database$selectSavedRows('core.person.count');same(a,b)
    stopifnot(identical(canonical(a$rows),canonical(snapshot$rows[['core.person.count']])),!a$generation_requested)
    left<-right<-NULL;gender<-list()
    repeat {
      a<-file$selectSavedRows('core.person.gender_count',maxRows=1L,cursor=left)
      b<-database$selectSavedRows('core.person.gender_count',maxRows=1L,cursor=right);same(a,b)
      stopifnot(!a$generation_requested,length(a$dependencies)==1L,
        a$dependencies[[1L]]$metric_id=='core.person.count',
        identical(wire(a$dependencies[[1L]]$row),wire(snapshot$rows[['core.person.count']][[1L]])))
      gender<-c(gender,a$rows);semanticRequests<-semanticRequests+1L
      if(a$complete)break
      left<-a$cursor;right<-b$cursor
    }
    stopifnot(identical(canonical(gender),canonical(snapshot$rows[['core.person.gender_count']])))
    if(kind=='full') {
      a<-file$selectSavedRows('core.measurement.numeric_summary',rowKind='summary',maxRows=1L)
      b<-database$selectSavedRows('core.measurement.numeric_summary',rowKind='summary',maxRows=1L);same(a,b)
      expected<-Filter(function(row)row$row_kind=='summary',snapshot$rows[['core.measurement.numeric_summary']])
      stopifnot(length(a$rows)==1L,wire(a$rows[[1L]])%in%vapply(expected,wire,''),!a$generation_requested)
    } else {
      a<-file$selectSavedRows('core.drug.capture_count');b<-database$selectSavedRows('core.drug.capture_count');same(a,b)
      stopifnot(a$state=='suppressed',length(a$rows)==0L,!a$generation_requested)
    }
    a<-file$selectSavedRows('core.person.gender_count',list(gender_concept_id='999999999'))
    b<-database$selectSavedRows('core.person.gender_count',list(gender_concept_id='999999999'));same(a,b)
    stopifnot(a$state=='not_saved',!a$generation_requested)
  }
  # Pinned cursors and authorization stay scoped to their approved publication.
  cursor<-providers$full$database$selectSavedRows('core.person.gender_count',maxRows=1L)$cursor
  error<-tryCatch({providers$projected$database$selectSavedRows('core.person.gender_count',maxRows=1L,cursor=cursor);NULL},error=identity)
  stopifnot(inherits(error,'achillesnext_read_error'),error$code=='invalid_cursor')
  ex(paste0('UPDATE "',results,'".achillesnext_audience_grant SET enabled=false WHERE scope_id=',lit(full$access_scope_id),
    ' AND database_role=',lit(roles$reader$user)))
  error<-tryCatch({providers$full$database$selectSavedRows('core.person.count');NULL},error=identity)
  stopifnot(inherits(error,'achillesnext_read_error'),error$code=='unavailable',providers$full$database$inspect()$cache_bytes==0L,
    providers$full$file$selectSavedRows('core.person.count')$state=='available',
    providers$projected$database$selectSavedRows('core.person.count')$state=='available')
  ex(paste0('UPDATE "',results,'".achillesnext_audience_grant SET enabled=true WHERE scope_id=',lit(full$access_scope_id),
    ' AND database_role=',lit(roles$reader$user)))
  same(providers$full$file$selectSavedRows('core.person.count'),providers$full$database$selectSavedRows('core.person.count'))
  stopifnot(identical(beforePointer,pointer()),identical(beforePages,pages()),length(statements)>0L,
    all(startsWith(statements,"SELECT encode(payload,'base64') FROM ")),
    all(grepl(paste0(' FROM "',serving,'".achillesnext_approved_pages WHERE '),statements,fixed=TRUE)),
    !any(grepl('achillesnext_approved_current|achillesnext_aggregate_cell|cdm_',statements)))
  proof$program_sha256<-candidate$source_receipt$program_sha256
  proof$source_denied_operator<-TRUE;proof$serving_only_reader<-TRUE;proof$semantic_file_database_parity<-TRUE
  proof$only_approved_view_queries<-TRUE;proof$cancelled_newer_attempt_preserved<-TRUE;proof$pinned_providers_preserved<-TRUE
  proof$cancelled_capture_rows<-captured;proof$semantic_requests<-semanticRequests;proof$approved_view_queries<-length(statements)
  proof$duration_ms<-f('.sql_execution_ms')(proc.time()[['elapsed']]-began)
  cat('COMPILED_CANDIDATE_APPROVED_FULL_PROJECTED_PROVIDERS_CANCELLED_NEWER_ATTEMPT_PINNED_BYTES_OK\n')
  proof
}
