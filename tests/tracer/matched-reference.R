# Opt-in small-fixture paired execution. No large tiers or installed code changes.
library(AchillesNext)
source('tools/benchmark/implementation_identity.R')
source('tools/benchmark/matched_reference.R')
local({
  args<-commandArgs(TRUE);stopifnot(length(args)==2L)
  env<-new.env();sys.source(args[1],env);out<-normalizePath(args[2],mustWork=TRUE)
  input<-jsonlite::fromJSON(file.path(out,'input.json'),simplifyVector=FALSE)
  f<-function(n)get(n,asNamespace('AchillesNext'));lit<-f('.store_literal');wire<-f('.v2_bytes')
  implementation<-implementationIdentity('.')
  owner<-DatabaseConnector::connect(env$fixtureConnection('owner'));on.exit(DatabaseConnector::disconnect(owner),add=TRUE)
  ex<-function(sql)DatabaseConnector::executeSql(owner,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,'sql-error.txt'))
  q<-function(sql)DatabaseConnector::querySql(owner,sql,integer64AsNumeric=FALSE)
  guard<-q("SELECT current_database() AS db,current_user AS usr,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB=='achilles_next_fixtures',guard$USR=='achilles_next_fixture_owner',guard$MARKER=='AchillesNext synthetic fixture sandbox v1')
  reader<-jsonlite::fromJSON(Sys.getenv('ACHILLES_NEXT_SERVING_FIXTURE'),simplifyVector=FALSE)
  stopifnot(grepl('^achilles_test_reader_[0-9a-f]{12}$',reader$user))
  readDetails<-DatabaseConnector::createConnectionDetails(dbms='postgresql',server='127.0.0.1/achilles_next_fixtures',port=as.integer(reader$port),user=reader$user,password=reader$password)
  schemas<-vapply(input,function(x)x$schema,'');stopifnot(all(grepl('^cdm_synthetic_[0-9a-f]{12}$',schemas)),!anyDuplicated(schemas))
  results<-paste0('achillesnext_matched_',Sys.getpid());serving<-paste0('achillesnext_matched_serve_',Sys.getpid());installed<-FALSE;exporter<-NULL
  hadTemp<-q("SELECT has_database_privilege('achilles_next_runner',current_database(),'TEMPORARY')::text AS ok")$OK=='true'
  writeBin(wire(list(results_schema=results,serving_schema=serving,runner_had_temp=hadTemp)),file.path(out,'fixture-state.json'))
  on.exit({
    failures<-character()
    clean<-function(work)tryCatch(work(),error=function(e){failures<<-c(failures,conditionMessage(e))})
    if(!is.null(exporter)) {
      clean(function()rJava::.jcall(exporter@jConnection,'V','rollback'))
      clean(function()DatabaseConnector::disconnect(exporter))
    }
    if(installed)clean(function()ex(paste0('DROP SCHEMA "',serving,'","',results,'" CASCADE')))
    if(!hadTemp)clean(function()ex('REVOKE TEMPORARY ON DATABASE achilles_next_fixtures FROM achilles_next_runner'))
    if(length(failures))stop('Matched fixture cleanup failed: ',paste(failures,collapse='; '))
  },add=TRUE,after=FALSE)
  if(!hadTemp)ex('GRANT TEMPORARY ON DATABASE achilles_next_fixtures TO achilles_next_runner')
  initializeResultStore(env$fixtureConnection('owner'),results,serving,schemas);installed<-TRUE
  tables<-function(ids)paste(paste0('"',results,'".achillesnext_',ids),collapse=',')
  producer<-c('source_release','analysis_run','operation','result_release','dataset','aggregate_cell','denominator_edge')
  ex(paste0('GRANT USAGE ON SCHEMA "',results,'" TO achilles_next_runner; GRANT SELECT ON ',tables(c('storage_version','profile_registry','validation_receipt',producer)),
    ' TO achilles_next_runner; GRANT INSERT ON ',tables(producer),' TO achilles_next_runner; GRANT UPDATE ON ',tables(c('analysis_run','result_release')),' TO achilles_next_runner'))
  ex(paste0('GRANT USAGE ON SCHEMA "',serving,'" TO ',reader$user,'; GRANT SELECT ON "',serving,'".achillesnext_approved_pages,"',serving,'".achillesnext_approved_current TO ',reader$user))
  capture<-function(candidate)f('.store_transaction')(env$fixtureConnection(),results,function(tx) {
    datasets<-f('.store_datasets')(tx,candidate$release_id);rows<-list()
    for(mid in names(datasets)) {
      rows[[mid]]<-list()
      f('.store_rows')(tx,candidate$release_id,mid,function(row,key){rows[[mid]][[length(rows[[mid]])+1L]]<<-row})
    }
    list(datasets=datasets,rows=rows,schema_sha256=f('.store_context')(tx,candidate$release_id)$observed_schema_sha256)
  })
  pairs<-list()
  for(index in seq_along(input)) {
    one<-input[[index]];sourceId<-paste0('fixture:matched:',one$manifest_sha256)
    stopifnot(identical(q(paste0("SELECT obj_description(oid,'pg_namespace') AS marker FROM pg_namespace WHERE nspname=",lit(one$schema)))$MARKER,one$marker))
    compiled<-jsonlite::fromJSON(file.path(out,one$compiled),simplifyVector=FALSE)
    exporter<-DatabaseConnector::connect(env$fixtureConnection('owner'))
    rJava::.jcall(exporter@jConnection,'V','setAutoCommit',FALSE);rJava::.jcall(exporter@jConnection,'V','setTransactionIsolation',4L)
    snapshot<-list(ID=referenceOne(exporter,'SELECT pg_export_snapshot()'),WITNESS=referenceOne(exporter,'SELECT pg_current_snapshot()::text'))
    before<-referenceOne(exporter,paste0('SELECT count(*)::text FROM "',one$schema,'".person'))
    # A committed write after export proves both importers see the captured input,
    # rather than merely obtaining two coincidentally equal current snapshots.
    stopifnot(q(paste0('SELECT count(*)::text AS n FROM "',one$schema,'".person WHERE person_id=2000000000'))$N=='0')
    ex(paste0('INSERT INTO "',one$schema,'".person(person_id,year_of_birth,gender_concept_id,race_concept_id,ethnicity_concept_id) VALUES (2000000000,2000,0,0,0)'))
    latest<-q(paste0('SELECT count(*)::text AS n FROM "',one$schema,'".person'))$N
    stopifnot(as.numeric(latest)==as.numeric(before)+1L)
    witnesses<-new.env();witnesses$values<-character();paths<-list();candidates<-list()
    for(path in c('optimized','reference')) {
      cat('MATCHED_GENERATE ',one$case_id,' ',path,'\n',sep='')
      begin<-proc.time()[['elapsed']]
      candidate<-if(path=='optimized')referenceOptimized(env$fixtureConnection(),one$schema,sourceId,results,one$version,snapshot$ID,witnesses) else
        referenceGenerate(env$fixtureConnection(),one$schema,sourceId,results,one$version,compiled,snapshot$ID,witnesses)
      generationMs<-f('.run_ms')(begin)
      stopifnot(identical(candidate$generated_metric_count,'142'),isTRUE(candidate$profile_complete),identical(candidate$publishable,FALSE))
      snap<-capture(candidate);snap$source_id<-sourceId;snap$version<-one$version;snap$generated_metric_count<-candidate$generated_metric_count
      stopifnot(snap$rows[['core.person.count']][[1]]$values$person_count==before)
      paths[[path]]<-list(snapshot=snap,generation_ms=generationMs);candidates[[path]]<-candidate
    }
    checkpoint<-file.path(out,paste0('candidates-',index,'.json'))
    writeBin(wire(list(paths=paths,model=one$model,expectations=one$expectations)),checkpoint)
    status<-system2(Sys.getenv('ACHILLES_NEXT_REFERENCE_PYTHON',unset='python3'),c('tools/matched_reference_compare.py',shQuote(checkpoint)))
    stopifnot(status==0L,length(witnesses$values)==2L,all(witnesses$values==snapshot$WITNESS))
    rJava::.jcall(exporter@jConnection,'V','rollback');DatabaseConnector::disconnect(exporter);exporter<-NULL
    ex(paste0('DELETE FROM "',one$schema,'".person WHERE person_id=2000000000; REVOKE ALL ON SCHEMA "',one$schema,'" FROM achilles_next_runner'))
    denied<-tryCatch({f('.store_transaction')(env$fixtureConnection(),results,function(tx)tx$one(paste0('SELECT count(*)::text FROM "',one$schema,'".person')),readOnly=TRUE);FALSE},error=function(e)grepl('permission denied',conditionMessage(e),fixed=TRUE))
    stopifnot(denied,q(paste0('SELECT has_schema_privilege(',lit(reader$user),',',lit(one$schema),",'USAGE')::text AS ok"))$OK=='false',
      q(paste0('SELECT has_schema_privilege(',lit(reader$user),',',lit(results),",'USAGE')::text AS ok"))$OK=='false')
    scopes<-paste0('fixture-matched-',index,'-',c('full','projected'))
    for(scope in scopes)ex(paste0('INSERT INTO "',results,'".achillesnext_audience_grant VALUES (',lit(scope),',',lit(reader$user),',true)'))
    for(path in names(paths)) {
      candidate<-candidates[[path]];begin<-proc.time()[['elapsed']]
      sealResultRelease(env$fixtureConnection('owner'),results,candidate$release_id)
      validateResultRelease(env$fixtureConnection('owner'),results,candidate$release_id)
      paths[[path]]$snapshot$validated<-TRUE
      pubs<-list()
      for(kind in c('full','projected')) {
        scope<-scopes[if(kind=='full')1L else 2L]
        policy<-list(id=scope,revision='1',scope_kind=if(kind=='full')'restricted' else 'distributable',
          allow_metrics=if(kind=='full')as.list(names(paths[[path]]$snapshot$datasets)) else list('core.person.count','core.person.gender_count'))
        directory<-paste0('export-',index,'-',path,'-',kind)
        cat('MATCHED_PUBLISH ',one$case_id,' ',path,' ',kind,'\n',sep='')
        published<-publishResultRelease(env$fixtureConnection('owner'),results,candidate$release_id,file.path(out,directory),scope,'synthetic-matched-review',policy,function(proposal) {
          stopifnot(proposal$source_id==sourceId,proposal$release_id==candidate$release_id);TRUE
        },if(path=='optimized')'0' else '1')
        # Publication already performs complete native artifact admission. Avoid
        # re-admitting the same export merely to locate two serving samples.
        rawObject<-function(d)readBin(file.path(published$export_dir,'objects',paste0(d$sha256,'.json')),'raw',n=as.numeric(d$bytes))
        rootBytes<-rawObject(published$root);rootDoc<-f('.nv_json')(rootBytes)
        firstData<-function(d) {
          if(d$kind=='data')return(d)
          stopifnot(d$kind=='index')
          doc<-f('.nv_json')(rawObject(d));stopifnot(length(doc$children)>0L)
          firstData(doc$children[[1L]]$object)
        }
        dataDescriptor<-firstData(rootDoc$data)
        rootRead<-readResultObject(readDetails,serving,sourceId,published$publication_id,scope,published$root$sha256)
        dataRead<-readResultObject(readDetails,serving,sourceId,published$publication_id,scope,published$root$sha256,dataDescriptor)
        stopifnot(identical(rootRead,rootBytes),identical(dataRead,rawObject(dataDescriptor)))
        served<-2L
        cat('MATCHED_EXPORT_VERIFIED ',one$case_id,' ',path,' ',kind,'\n',sep='')
        pubs[[kind]]<-list(directory=directory,publication_id=published$publication_id,release_id=candidate$release_id,access_scope_id=scope,
          root=published$root,policy=policy,served_objects=served)
      }
      paths[[path]]$post_generation_ms<-f('.run_ms')(begin);paths[[path]]$publications<-pubs
    }
    pairs[[length(pairs)+1L]]<-list(case_id=one$case_id,source_id=sourceId,version=one$version,paths=paths,
      captured_snapshot=snapshot$ID,snapshot_witness=snapshot$WITNESS,imported_witnesses=as.list(witnesses$values),captured_people=before,
      latest_people_after_capture=latest,producer_denied=denied,serving_source_and_aggregate_denied=TRUE)
    cat('MATCHED_REFERENCE_142_FULL_AND_PROJECTED_EXPORTS ',one$case_id,'\n',sep='')
  }
  stopifnot(identical(implementation,implementationIdentity('.')))
  writeBin(wire(list(pairs=pairs,implementation=implementation)),file.path(out,'results.json'))
})
