# Compose real refresh output with approval, projection, export and pinned reads.
# Called inside the marked-fixture core matrix, reusing its first candidate.
testCorePublication<-function(env,owner,results,serving,sourceSchema,sourceId,candidate,snapshot,out) {
  f<-function(n)get(n,asNamespace('AchillesNext'));lit<-f('.store_literal')
  ex<-function(sql)DatabaseConnector::executeSql(owner,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,'publication-error.txt'))
  q<-function(sql)DatabaseConnector::querySql(owner,sql,integer64AsNumeric=FALSE,errorReportFile=file.path(out,'publication-query-error.txt'))
  reader<-jsonlite::fromJSON(Sys.getenv('ACHILLES_NEXT_SERVING_FIXTURE'),simplifyVector=FALSE)
  role<-reader$user;stopifnot(grepl('^achilles_test_reader_[0-9a-f]+$',role))
  readDetails<-DatabaseConnector::createConnectionDetails(dbms='postgresql',server='127.0.0.1/achilles_next_fixtures',
    port=as.integer(reader$port),user=role,password=reader$password)
  # Neither the generation role after snapshot capture nor the dedicated reader
  # has source schema access. The reader also lacks aggregate-store schema access.
  for(principal in c(role,'achilles_next_runner'))stopifnot(q(paste0('SELECT has_schema_privilege(',lit(principal),',',lit(sourceSchema),",'USAGE')::text AS allowed"))$ALLOWED=='false')
  stopifnot(q(paste0('SELECT has_schema_privilege(',lit(role),',',lit(results),",'USAGE')::text AS allowed"))$ALLOWED=='false')
  ex(paste0('GRANT USAGE ON SCHEMA "',serving,'" TO ',role,'; GRANT SELECT ON "',serving,'".achillesnext_approved_pages,"',serving,'".achillesnext_approved_current TO ',role))
  readConnection<-DatabaseConnector::connect(readDetails)
  on.exit(DatabaseConnector::disconnect(readConnection),add=TRUE)
  metrics<-names(snapshot$datasets)
  selections<-list(full=as.list(metrics),projected=list('core.person.count','core.person.gender_count',
    'core.condition.observation_qualification_count','core.execution.output_status'))
  publications<-list();objects<-0L
  for(kind in names(selections)) {
    scope<-paste0('fixture-core-',kind)
    policy<-list(id=scope,revision='1',scope_kind=if(kind=='full')'restricted' else 'distributable',allow_metrics=selections[[kind]])
    approved<-FALSE
    published<-publishResultRelease(env$fixtureConnection('owner'),results,candidate$release_id,file.path(out,paste0('publication-',kind)),
      scope,paste0('review-',kind),policy,function(proposal) {
        stopifnot(proposal$release_id==candidate$release_id,proposal$source_id==sourceId)
        approved<<-TRUE;TRUE
      },'0')
    stopifnot(approved,published$revision=='1')
    ex(paste0('INSERT INTO "',results,'".achillesnext_audience_grant VALUES (',lit(scope),',',lit(role),',true)'))
    if(kind=='full') {
      source('tests/tracer/artifact-partition-regression.R',local=TRUE)
      testArtifactPartition(published$export_dir,out)
    } else validateResultArtifact(published$export_dir)
    f('.v2_directory')(published$export_dir,function(d,bytes) {
      returned<-readResultObject(readDetails,serving,sourceId,published$publication_id,scope,published$root$sha256,
        if(d$kind=='root')NULL else d)
      stopifnot(identical(returned,bytes));objects<<-objects+1L
    })
    current<-DatabaseConnector::querySql(readConnection,paste0('SELECT publication_id::text AS id,revision::text AS revision FROM "',serving,
      '".achillesnext_approved_current WHERE source_id=',lit(sourceId),' AND scope_id=',lit(scope)),
      errorReportFile=file.path(out,'reader-current-error.txt'))
    stopifnot(nrow(current)==1L,current$ID==published$publication_id,current$REVISION=='1')
    publications[[kind]]<-list(directory=basename(published$export_dir),publication_id=published$publication_id,
      access_scope_id=scope,root=published$root,scope_kind=policy$scope_kind)
  }
  full<-publications$full;projected<-publications$projected
  denied<-function(work) {
    error<-tryCatch({work();NULL},error=identity)
    stopifnot(inherits(error,'error'),conditionMessage(error)=='Approved result page unavailable or invalid')
  }
  denied(function()readResultObject(readDetails,serving,sourceId,full$publication_id,projected$access_scope_id,full$root$sha256))
  denied(function()readResultObject(readDetails,serving,paste0(sourceId,':wrong'),full$publication_id,full$access_scope_id,full$root$sha256))
  # Disable only the full audience. Its offline copy remains valid, while the
  # other approved scope stays independently readable.
  ex(paste0('UPDATE "',results,'".achillesnext_audience_grant SET enabled=false WHERE scope_id=',lit(full$access_scope_id),' AND database_role=',lit(role)))
  denied(function()readResultObject(readDetails,serving,sourceId,full$publication_id,full$access_scope_id,full$root$sha256))
  stopifnot(length(readResultObject(readDetails,serving,sourceId,projected$publication_id,projected$access_scope_id,projected$root$sha256))>0L)
  validateResultArtifact(file.path(out,full$directory))
  cat('GENERATED_CORE_FULL_PROJECTED_EXPORT_EXACT_SERVING_BYTES_CONTEXT_AND_REVOCATION_OK\n')
  list(snapshot_source_id=sourceId,release_id=candidate$release_id,publications=publications,
    approved_objects_read=as.character(objects),source_and_aggregate_denied=TRUE,exact_serving_bytes=TRUE,
    context_mismatch_rejected=TRUE,scope_revocation_isolated=TRUE,offline_copy_retained=TRUE)
}
