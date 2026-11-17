# Separate source/store credentials exercise the installed public bridge.
library(AchillesNext)
source('tools/benchmark/implementation_identity.R')
source('tests/tracer/characterization-execute-native.R')
source('tests/tracer/characterization-candidate-sql-failures.R')
source('tests/tracer/characterization-candidate-sql-publication.R')
source('tests/tracer/characterization-candidate-sql-clock.R')
main<-function() {
  args<-commandArgs(TRUE);stopifnot(length(args)==2L)
  implementation<-implementationIdentity(getwd())
  env<-new.env(parent=globalenv());sys.source(args[1],env);out<-normalizePath(args[2],mustWork=TRUE)
  input<-jsonlite::fromJSON(file.path(out,'input.json'),simplifyVector=FALSE)
  roles<-jsonlite::fromJSON(Sys.getenv('ACHILLES_NEXT_BRIDGE_FIXTURE'),simplifyVector=FALSE)
  stopifnot(setequal(names(roles),c('source','store','reader')),roles$source$user!=roles$store$user,
    all(vapply(roles[c('source','store')],function(x)grepl('^achilles_test_bridge_(source|store)_[0-9a-f]{12}$',x$user),TRUE)),
    grepl('^achilles_test_reader_[0-9a-f]{12}$',roles$reader$user))
  details<-function(kind)DatabaseConnector::createConnectionDetails(dbms='postgresql',server='127.0.0.1/achilles_next_fixtures',
    port=as.integer(roles[[kind]]$port),user=roles[[kind]]$user,password=roles[[kind]]$password)
  sourceDetails<-details('source');storeDetails<-details('store');readerDetails<-details('reader');legacyDetails<-env$fixtureConnection()
  owner<-DatabaseConnector::connect(env$fixtureConnection('owner'))
  on.exit(DatabaseConnector::disconnect(owner),add=TRUE)
  ex<-function(sql)DatabaseConnector::executeSql(owner,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,'error.txt'))
  q<-function(sql)DatabaseConnector::querySql(owner,sql,integer64AsNumeric=FALSE,errorReportFile=file.path(out,'query-error.txt'))
  f<-function(n)get(n,asNamespace('AchillesNext'));lit<-f('.store_literal');wire<-f('.json')
  guard<-q("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB=='achilles_next_fixtures',guard$MARKER=='AchillesNext synthetic fixture sandbox v1')
  results<-paste0('achillesnext_domain_',Sys.getpid());serving<-paste0('achillesnext_popserve_',Sys.getpid())
  sources<-character();installed<-FALSE
  legacyTemp<-q("SELECT has_database_privilege('achilles_next_runner',current_database(),'TEMPORARY')::text AS allowed")$ALLOWED=='true'
  on.exit({
    # A failed owner diagnostic may leave JDBC's transaction aborted. Release
    # that transaction before the attempt-owned schema cleanup.
    if(!rJava::.jcall(owner@jConnection,'Z','getAutoCommit'))rJava::.jcall(owner@jConnection,'V','rollback')
    for(s in sources)ex(paste0('DROP SCHEMA "',s,'" CASCADE'))
    if(installed)ex(paste0('DROP SCHEMA "',serving,'","',results,'" CASCADE'))
    if(!legacyTemp)ex('REVOKE TEMPORARY ON DATABASE achilles_next_fixtures FROM achilles_next_runner')
  },add=TRUE,after=FALSE)
  if(!legacyTemp)ex('GRANT TEMPORARY ON DATABASE achilles_next_fixtures TO achilles_next_runner')
  initializeResultStore(env$fixtureConnection('owner'),results,serving,'cdm_tiny_a_55');installed<-TRUE
  producer<-c('source_release','analysis_run','operation','result_release','dataset','aggregate_cell','denominator_edge')
  qualified<-function(names)paste0('"',results,'".achillesnext_',names)
  for(role in c(roles$store$user,'achilles_next_runner'))ex(paste0('GRANT USAGE ON SCHEMA "',results,'" TO ',role,
    '; GRANT SELECT ON ',paste(qualified(c('storage_version','profile_registry','validation_receipt',producer)),collapse=','),' TO ',role,
    '; GRANT INSERT ON ',paste(qualified(producer),collapse=','),' TO ',role,
    '; GRANT UPDATE ON ',paste(qualified(c('analysis_run','result_release')),collapse=','),' TO ',role))
  # Institutional operator rights are restricted to the result store. This
  # principal cannot read the CDM, even when sealing/validating/publishing.
  operatorTables<-c('validation_receipt','publication','page_object','audience_grant','current_publication')
  ex(paste0('GRANT SELECT,INSERT ON ',paste(qualified(operatorTables),collapse=','),' TO ',roles$store$user,
    '; GRANT UPDATE ON ',paste(qualified(c('publication','audience_grant','current_publication')),collapse=','),' TO ',roles$store$user,
    '; GRANT EXECUTE ON FUNCTION "',results,'".seal_release(uuid),"',results,'".promote_publication(uuid,bigint) TO ',roles$store$user))
  makeSource<-function(case,index) {
    schema<-paste0('cdm_tiny_domain_',Sys.getpid(),'_',index);sources<<-c(sources,schema)
    ex(paste0('CREATE SCHEMA "',schema,'"; COMMENT ON SCHEMA "',schema,'" IS \'AchillesNext synthetic fixture sandbox v1: bridge\''))
    for(n in names(case$columns)) {
      definitions<-paste(paste0('"',names(case$columns[[n]]),'" ',unlist(case$columns[[n]])),collapse=',')
      ex(paste0('CREATE TABLE "',schema,'"."',n,'" (',definitions,')'))
      if(length(case$tables[[n]]))ex(paste0('INSERT INTO "',schema,'"."',n,'" SELECT * FROM jsonb_to_recordset(',lit(wire(case$tables[[n]])),'::jsonb) x(',definitions,')'))
    }
    for(role in c(roles$source$user,'achilles_next_runner')) {
      ex(paste0('GRANT USAGE ON SCHEMA "',schema,'" TO ',role,'; GRANT SELECT ON ALL TABLES IN SCHEMA "',schema,'" TO ',role))
      for(table in unlist(case$denied_tables))ex(paste0('REVOKE SELECT ON "',schema,'"."',table,'" FROM ',role))
    }
    schema
  }
  snap<-function(candidate)f('.store_transaction')(storeDetails,results,function(tx) {
    datasets<-f('.store_datasets')(tx,candidate$release_id);rows<-list()
    for(mid in names(datasets)) {
      rows[[mid]]<-list();f('.store_rows')(tx,candidate$release_id,mid,function(row,key)rows[[mid]][[length(rows[[mid]])+1L]]<<-row)
    }
    context<-f('.store_context')(tx,candidate$release_id)
    list(datasets=datasets,rows=rows,schema_sha256=context$observed_schema_sha256,context=context)
  })
  canonical<-function(rows)sort(vapply(rows,wire,''),method='radix')
  patch<-function(name,replacement,work,namespace='AchillesNext') {
    original<-get(name,asNamespace(namespace));on.exit(assignInNamespace(name,original,ns=namespace),add=TRUE)
    assignInNamespace(name,replacement,ns=namespace);work()
  }
  tableCounts<-function()vapply(producer,function(table)q(paste0('SELECT count(*)::text AS n FROM ',qualified(table)))$N,'')
  oldPointer<-function()q(paste0('SELECT source_id,profile_id,scope_id,publication_id::text,revision::text FROM "',results,'".achillesnext_current_publication ORDER BY source_id,profile_id,scope_id'))
  oldPages<-function()q(paste0('SELECT publication_id::text,sha256,encode(payload,\'hex\') AS bytes FROM "',results,'".achillesnext_page_object ORDER BY publication_id,sha256'))
  baselineTemp<-q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N
  snapshots<-list();failures<-NULL;clockProof<-NULL;allBatches<-TRUE;readCategories<-list()
  for(index in seq_along(input)) {
    case<-input[[index]];schema<-makeSource(case,index);sourceId<-paste0('fixture:bridge:',case$case,':',case$version)
    stopifnot(q(paste0('SELECT has_schema_privilege(',lit(roles$source$user),',',lit(results),",'USAGE')::text AS allowed"))$ALLOWED=='false',
      q(paste0('SELECT has_schema_privilege(',lit(roles$store$user),',',lit(schema),",'USAGE')::text AS allowed"))$ALLOWED=='false',
      q(paste0('SELECT has_table_privilege(',lit(roles$source$user),',',lit(paste0('"',schema,'".person')),
        ",'INSERT,UPDATE,DELETE,TRUNCATE')::text AS allowed"))$ALLOWED=='false')
    legacy<-generateCharacterizationCandidate(legacyDetails,schema,sourceId,results,case$version)
    expected<-snap(legacy)
    if(index==1L) {
      sealResultRelease(env$fixtureConnection('owner'),results,legacy$release_id)
      validateResultRelease(env$fixtureConnection('owner'),results,legacy$release_id)
      policy<-list(id='fixture-bridge',revision='1',scope_kind='restricted',allow_metrics=list('core.person.count','core.person.gender_count'))
      published<-publishResultRelease(env$fixtureConnection('owner'),results,legacy$release_id,file.path(out,'prior-publication'),
        'fixture-bridge','fixture-bridge-approved',policy,function(candidate)TRUE,'0')
      validateResultArtifact(published$export_dir)
    }
    pointer<-oldPointer();pages<-oldPages()
    prior<-function()stopifnot(identical(pointer,oldPointer()),identical(pages,oldPages()))
    columns<-do.call(rbind,lapply(names(case$columns),function(table) {
      x<-case$columns[[table]]
      data.frame(table=table,column=names(x),type=vapply(x,function(t)switch(t,bigint='int8',integer='int4',t),''),
        readable=!table%in%unlist(case$denied_tables),stringsAsFactors=FALSE)
    }))
    for(strategy in c('weighted','reference')) {
      program<-renderCharacterizationSql(schema,sourceId,case$version,columns,numericStrategy=strategy)
      execute<-get('executeCharacterizationSql',asNamespace('AchillesNext'));observed<-NULL
      metadataIds<-f('.core_metadata_ids')();sourceMetadata<-stats::setNames(lapply(metadataIds,function(mid)list()),metadataIds)
      import<-f('.candidate_import');storeReads<-character()
      importProof<-function(...) {
        values<-list(...);tx<-values[[1]];one<-tx$one;stream<-tx$stream
        tx$one<-function(sql){storeReads<<-c(storeReads,sql);one(sql)}
        tx$stream<-function(sql,visit){storeReads<<-c(storeReads,sql);stream(sql,visit)}
        values[[1]]<-tx;do.call(import,values)
      }
      generate<-generateCharacterizationCandidateFromSql;scope<-new.env(parent=environment(generate))
      scope$.candidate_import<-importProof
      scope$executeCharacterizationSql<-function(connectionDetails,program,visit,...) {
        receipt<-execute(connectionDetails,program,function(mid,item) {
          visit(mid,item)
          if(mid%in%metadataIds)sourceMetadata[[mid]][[length(sourceMetadata[[mid]])+1L]]<<-item[c('row_kind','dimensions','values','state','reason_code')]
        },...)
        testCharacterizationExecuteAudit(receipt);observed<<-receipt
        # A successful return guarantees source rollback/disconnect. Remove even
        # source USAGE now; candidate replay must use captured aggregates only.
        ex(paste0('REVOKE USAGE ON SCHEMA "',schema,'" FROM ',roles$source$user));receipt
      }
      environment(generate)<-scope
      candidate<-generate(sourceDetails,program,storeDetails,results,scratchParent=out)
      stopifnot(!is.null(observed),identical(wire(candidate$source_receipt),wire(observed)),
        identical(candidate$source_store_separate,TRUE),candidate$publication_changed==FALSE,
        candidate$state=='building',candidate$profile_complete,!candidate$publishable)
      actual<-snap(candidate);runtime<-observed$runtime_facts
      for(mid in names(expected$datasets)) {
        referenceDataset<-expected$datasets[[mid]]
        # Compiled execution materializes its inventory as an additional stage.
        # Only timing cardinality follows its own actual stage inventory.
        if(mid=='core.execution.timing')referenceDataset$rows<-as.character(length(runtime$timings))
        if(!identical(wire(actual$datasets[[mid]]),wire(referenceDataset))) {
          writeLines(wire(list(metric_id=mid,actual=actual$datasets[[mid]],expected=referenceDataset)),
            file.path(out,'descriptor-mismatch.json'),useBytes=TRUE)
          stop(paste('Candidate dataset differs:',mid),call.=FALSE)
        }
        if(mid%in%metadataIds) {
          saved<-lapply(actual$rows[[mid]],function(row)row[c('row_kind','dimensions','values','state','reason_code')])
          stopifnot(identical(canonical(saved),canonical(sourceMetadata[[mid]])),
            actual$datasets[[mid]]$rows==observed$inventory[[mid]]$rows)
        }
        if(mid=='core.execution.timing')next
        reference<-expected$rows[[mid]]
        if(mid=='core.source.passport')reference[[1]]$values$generation<-list(started_at=runtime$started_at,ended_at=runtime$ended_at)
        stopifnot(identical(canonical(actual$rows[[mid]]),canonical(reference)))
      }
      timing<-actual$rows[['core.execution.timing']]
      stopifnot(length(timing)==length(runtime$timings))
      for(row in timing) {
        matches<-Filter(function(t)identical(t$operation_id,row$dimensions$operation_id)&&identical(t$phase,row$dimensions$phase),runtime$timings)
        stopifnot(length(matches)==1L,identical(row$values$duration_ms,matches[[1]]$duration_ms),all(vapply(row$values$telemetry,is.null,TRUE)))
      }
      rid<-lit(candidate$release_id)
      edges<-q(paste0('SELECT count(*)::text AS n FROM ',qualified('denominator_edge'),' WHERE release_id=',rid))$N
      missing<-q(paste0('SELECT count(*)::text AS n FROM ',qualified('denominator_edge'),' e LEFT JOIN ',qualified('aggregate_cell'),
        ' c ON (c.release_id,c.metric_id,c.row_key)=(e.release_id,e.target_metric_id,e.target_row_key) WHERE e.release_id=',rid,' AND c.row_key IS NULL'))$N
      stopifnot(missing=='0',actual$context$state=='building',actual$context$run_state=='succeeded',actual$context$consistency_basis=='single_repeatable_read')
      identity<-q(paste0('SELECT (reusable_input_identity IS NULL)::text AS unknown FROM ',qualified('analysis_run'),' WHERE run_id=',lit(candidate$run_id)))$UNKNOWN
      stopifnot(identity=='true')
      releaseIdentity<-q(paste0("SELECT data_release_identity->>'state' AS data_state,vocabulary_identity->>'state' AS vocabulary_state FROM ",
        qualified('source_release'),' WHERE source_release_id=',lit(candidate$source_release_id)))
      stopifnot(releaseIdentity$DATA_STATE=='unknown',releaseIdentity$VOCABULARY_STATE=='unknown')
      operations<-q(paste0('SELECT operation_id,dependency_ids::text AS dependencies,telemetry::text FROM ',qualified('operation'),
        ' WHERE run_id=',lit(candidate$run_id),' ORDER BY operation_id'))
      stopifnot(nrow(operations)==2L,setequal(operations$OPERATION_ID,c('compiled.source_capture','compiled.candidate_persistence')))
      sourceOperation<-jsonlite::fromJSON(operations$TELEMETRY[operations$OPERATION_ID=='compiled.source_capture'],simplifyVector=FALSE)
      persistenceOperation<-jsonlite::fromJSON(operations$TELEMETRY[operations$OPERATION_ID=='compiled.candidate_persistence'],simplifyVector=FALSE)
      dependencies<-jsonlite::fromJSON(operations$DEPENDENCIES[operations$OPERATION_ID=='compiled.candidate_persistence'],simplifyVector=FALSE)
      stopifnot(identical(dependencies,list('compiled.source_capture')),sourceOperation$program_sha256==program$program_sha256,
        identical(wire(sourceOperation$generation),wire(observed$generation)),
        identical(wire(sourceOperation$runtime_facts),wire(observed$runtime_facts)),
        identical(wire(sourceOperation$audit_totals),wire(observed$audit_totals)),
        identical(sourceOperation$reusable,FALSE),identical(persistenceOperation$reusable,FALSE),
        persistenceOperation$source_capture_transaction=='separate_completed_repeatable_read')
      stats<-candidate$persistence
      stopifnot(stats$peak_queued_rows<=stats$max_rows,stats$peak_queued_sql_bytes<=stats$max_sql_bytes,
        stats$max_rows<=1024L,stats$max_sql_bytes<=4*1024^2)
      # Queries may reconcile grouped whole metrics, never fetch a denominator
      # by a literal per-row identity. Count the actual SQL at the import seam.
      stopifnot(length(storeReads)>0L,length(storeReads)<512L,
        !any(grepl("row_key[[:space:]]*=[[:space:]]*'[0-9a-f]{64}'",storeReads)))
      readCategories[[paste(case$case,case$version,strategy,sep=':')]]<-length(storeReads)
      allBatches<-allBatches&&stats$rows>=stats$cell_statements
      sealResultRelease(storeDetails,results,candidate$release_id)
      validateResultRelease(storeDetails,results,candidate$release_id)
      stopifnot(q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{32}_'")$N==baselineTemp)
      prior()
      snapshots[[length(snapshots)+1L]]<-c(list(case=case$case,version=case$version,strategy=strategy,source_id=sourceId,
        candidate=candidate,source_receipt=observed,source_audit=observed$audit_totals,missing_denominator_targets=missing,
        denominator_edges=edges,exact_legacy_rows=TRUE,exact_legacy_datasets=TRUE,validated_with_source_denied=TRUE,
        validated=TRUE,generated_metric_count=candidate$generated_metric_count),actual)
      ex(paste0('GRANT USAGE ON SCHEMA "',schema,'" TO ',roles$source$user))
      cat('CANDIDATE_SQL_142_CANONICAL_PARITY_AND_SOURCE_DENIED_REPLAY ',case$case,' ',case$version,' ',strategy,'\n',sep='')
    }
    if(index==1L)clockProof<-testCharacterizationCandidateSqlClock(sourceDetails,storeDetails,results,schema,sourceId,case$version,columns,out,q,f,qualified)
    if(index==1L)failures<-testCharacterizationCandidateSqlFailures(sourceDetails,program,storeDetails,results,out,
      f,patch,ex,q,qualified,tableCounts,prior,roles$source$user,schema)
  }
  first<-snapshots[[1L]]
  compiledPublication<-testCharacterizationCandidateSqlPublication(env,owner,results,serving,
    first$source_receipt$source$cdm_schema,first$source_id,first$candidate,first,out,
    sourceDetails,storeDetails,readerDetails,roles, input[[1L]])
  stopifnot(identical(implementation,implementationIdentity(getwd())),allBatches)
  report<-list(snapshots=snapshots,failures=failures,client_clock=clockProof,compiled_publication=compiledPublication,implementation=implementation,
    isolation=list(different_principals=TRUE,source_store_access=FALSE,store_source_access=FALSE,source_write_access=FALSE,
      replay_source_access_revoked=TRUE,bounded_writer_batches=allBatches,import_read_queries=readCategories))
  writeLines(wire(report),file.path(out,'report.json'),useBytes=TRUE)
}
main()
