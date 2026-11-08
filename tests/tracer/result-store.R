# Installed-package integration test against the marked synthetic database only.
local({
  stopifnot(length(commandArgs(trailingOnly=TRUE))==1L)
  library(AchillesNext)
  configEnv <- new.env();sys.source(commandArgs(trailingOnly=TRUE)[[1]],envir=configEnv)
  details <- configEnv$fixtureConnection('owner')
  c <- DatabaseConnector::connect(details)
  on.exit(DatabaseConnector::disconnect(c),add=TRUE)
  q <- function(sql) DatabaseConnector::querySql(c,sql)
  marker <- q("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(identical(marker$DB,'achilles_next_fixtures'),identical(marker$MARKER,'AchillesNext synthetic fixture sandbox v1'))
  a <- paste0('result_store_test_',Sys.getpid());b <- paste0('result_serve_test_',Sys.getpid())
  stopifnot(is.na(q(paste0("SELECT to_regnamespace('",a,"')::text AS name"))$NAME))
  stopifnot(is.na(q(paste0("SELECT to_regnamespace('",b,"')::text AS name"))$NAME))
  execute <- function(sql) DatabaseConnector::executeSql(c,sql,progressBar=FALSE,reportOverallTime=FALSE)
  on.exit(execute(paste0('DROP SCHEMA IF EXISTS "',b,'" CASCADE; DROP SCHEMA IF EXISTS "',a,'" CASCADE;')),add=TRUE,after=FALSE)
  result <- initializeResultStore(details,a,b,'cdm_tiny_a_55')
  stopifnot(identical(result$storage_version,'2.0.0'))
  relations <- q(paste0("SELECT c.relname AS name FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('",a,"','",b,"') AND c.relkind IN ('r','p','v','m')"))$NAME
  stopifnot(length(relations)==24L,all(startsWith(relations,'achillesnext_')),
    all(c('achillesnext_aggregate_cell','achillesnext_aggregate_cell_0','achillesnext_approved_pages','achillesnext_approved_current')%in%relations))
  expectError <- function(work) { failed <- FALSE;tryCatch(work(),error=function(e) failed<<-TRUE);stopifnot(failed) }
  expectError(function() initializeResultStore(details,a,a,'cdm_tiny_a_55'))
  expectError(function() initializeResultStore(details,'cdm_tiny_a_55',b,'cdm_tiny_a_55'))
  stopifnot(identical(q(paste0('SELECT version FROM ',a,'.achillesnext_storage_version'))$VERSION,'2.0.0'))
  definition <- jsonlite::toJSON(list(profile_id='test',revision='0',metrics=list(list(id='test.count',version='1',population='person',grain='source',availability='required_when_table_readable'))),auto_unbox=TRUE)
  profileHash <- digest::digest(charToRaw(definition),algo='sha256',serialize=FALSE)
  hex <- paste(sprintf('%02x',as.integer(charToRaw(definition))),collapse='')
  execute(paste0("INSERT INTO ",a,".achillesnext_profile_registry VALUES ('",profileHash,"','test','0',decode('",hex,"','hex'),convert_from(decode('",hex,"','hex'),'UTF8')::jsonb)"))
  execute(paste0("INSERT INTO ",a,".achillesnext_source_release VALUES ('00000000-0000-0000-0000-000000000001','fixture:test','{}','{}',repeat('a',64),'5.5',now());",
   "INSERT INTO ",a,".achillesnext_analysis_run(run_id,source_release_id,request_sha256,profile_id,profile_revision,profile_sha256,state,consistency_basis) VALUES ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001',repeat('b',64),'test','0','",profileHash,"','succeeded','single_repeatable_read');",
   "INSERT INTO ",a,".achillesnext_result_release VALUES ('00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002','building',1,0,null);",
   "INSERT INTO ",a,".achillesnext_dataset VALUES ('00000000-0000-0000-0000-000000000003','test.count','1','person','source','counts',repeat('d',64),'computed',null,true,'{}',1,'{}');",
   "INSERT INTO ",a,".achillesnext_aggregate_cell(release_id,metric_id,row_key,route_key,sort_key,dimensions,state,payload_kind,person_count) VALUES ('00000000-0000-0000-0000-000000000003','test.count',repeat('1',64),'all','all','{}','computed','counts',9007199254740993);"))
  stopifnot(identical(q(paste0('SELECT person_count::text AS value FROM ',a,'.achillesnext_aggregate_cell'))$VALUE,'9007199254740993'))
  sealedRevision <- sealResultRelease(details,a,'00000000-0000-0000-0000-000000000003')
  stopifnot(identical(sealedRevision,'2'))
  execute(paste0("DO $test$ BEGIN BEGIN UPDATE ",a,".achillesnext_aggregate_cell SET person_count=0; RAISE EXCEPTION 'Mutation accepted'; EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Release is not writable' THEN RAISE; END IF; END; END $test$;"))
  stopifnot(identical(q(paste0('SELECT person_count::text AS value FROM ',a,'.achillesnext_aggregate_cell'))$VALUE,'9007199254740993'))
  execute(paste0("INSERT INTO ",a,".achillesnext_validation_receipt VALUES ('00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000003',",sealedRevision,",'test-only','",profileHash,"',true,now(),repeat('e',64)); UPDATE ",a,".achillesnext_result_release SET state='validated';"))
  for (pub in c('00000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000008')) {
    # Deliberately minimal root tests SQL context guards, not full wire validation.
    root <- jsonlite::toJSON(list(source_schema=list(sha256=strrep('a',64),declared_cdm_version='5.5'),contract_version='2.0.0',publication_id=pub,release_id='00000000-0000-0000-0000-000000000003',source_id='fixture:test',profile_id='test',profile_revision='0',profile_sha256=profileHash,access_scope_id='test',eligible_for_current_pointer=TRUE,publication_state='ready'),auto_unbox=TRUE)
    rootHash <- digest::digest(charToRaw(root),algo='sha256',serialize=FALSE)
    rootHex <- paste(sprintf('%02x',as.integer(charToRaw(root))),collapse='')
    execute(paste0("INSERT INTO ",a,".achillesnext_publication VALUES ('",pub,"','00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000004','test',repeat('f',64),'test-only','",rootHash,"','building',now(),null); INSERT INTO ",a,".achillesnext_page_object VALUES ('",pub,"','",rootHash,"','root',decode('",rootHex,"','hex')); UPDATE ",a,".achillesnext_publication SET state='ready',approved_at=now() WHERE publication_id='",pub,"';"))
  }
  first <- '00000000-0000-0000-0000-000000000005';second <- '00000000-0000-0000-0000-000000000006'
  stopifnot(identical(promoteResultPublication(details,a,first,'0'),'1'))
  stopifnot(identical(promoteResultPublication(details,a,first,'0'),'1'))
  expectError(function() promoteResultPublication(details,a,second,'0'))
  stopifnot(identical(q(paste0('SELECT publication_id::text AS id FROM ',a,'.achillesnext_current_publication'))$ID,first))
  stopifnot(identical(promoteResultPublication(details,a,second,'1'),'2'))
  execute(paste0("DO $test$ BEGIN BEGIN UPDATE ",a,".achillesnext_publication SET state='building'; RAISE EXCEPTION 'Reopen accepted'; EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Approved publication is immutable' THEN RAISE; END IF; END; END $test$;"))
  cluster <- parallel::makePSOCKcluster(2L)
  on.exit(parallel::stopCluster(cluster),add=TRUE,after=FALSE)
  candidates <- c('00000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000008')
  outcomes <- parallel::parLapply(cluster,candidates,function(pub,lib,config,schema) {
    library(AchillesNext,lib.loc=lib,character.only=FALSE)
    e <- new.env();sys.source(config,envir=e)
    tryCatch(list(ok=TRUE,revision=promoteResultPublication(e$fixtureConnection('owner'),schema,pub,'2')),
      error=function(error) list(ok=FALSE,conflict=identical(conditionMessage(error),'Current publication conflict')))
  },lib=normalizePath(Sys.getenv('R_LIBS')),config=normalizePath(commandArgs(trailingOnly=TRUE)[[1]]),schema=a)
  stopifnot(sum(vapply(outcomes,function(x) x$ok,TRUE))==1L)
  stopifnot(all(vapply(outcomes,function(x) if(x$ok) identical(x$revision,'3') else isTRUE(x$conflict),TRUE)))
  stopifnot(identical(q(paste0('SELECT revision::text AS value FROM ',a,'.achillesnext_current_publication'))$VALUE,'3'))
  for(verb in c('DELETE FROM','TRUNCATE')) expectError(function()execute(paste(verb,paste0(a,'.achillesnext_current_publication'))))
  stopifnot(identical(q(paste0('SELECT revision::text AS value FROM ',a,'.achillesnext_current_publication'))$VALUE,'3'))
  expectError(function()promoteResultPublication(details,a,first,'0'))

  # Explicit terminology enablement refuses a modified guard/marker instead of
  # overwriting institutional changes. Existing publications/pointers survive.
  f<-function(n)get(n,asNamespace('AchillesNext'));def<-f('.term_extension_definition')(paste0('"',a,'"'))
  stopifnot(identical(f('.store_transaction')(details,'public',function(tx)tx$one("SELECT 'source-read-test'"),readOnly=TRUE,sourceRead=TRUE),'source-read-test'))
  expectError(function()f('.store_transaction')(details,'public',function(tx)NULL))
  expectError(function()f('.store_transaction')(details,'public',function(tx)NULL,sourceRead=TRUE))
  body<-function()q(paste0("SELECT p.prosrc AS body FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid WHERE n.nspname='",a,"' AND p.proname='guard_publication_transition'"))$BODY
  setBody<-function(value)f('.store_transaction')(details,a,function(tx)tx$execute(sub(def$new,value,def$sql,fixed=TRUE)))
  custom<-paste0(def$old,'\n-- institutional customization\n');setBody(custom)
  expectError(function()enableSavedTerminology(details,a));stopifnot(identical(body(),custom),is.na(q(paste0("SELECT to_regclass('",a,".achillesnext_storage_extension')::text AS name"))$NAME))
  setBody(def$old)
  # An intact function body is insufficient without its complete trigger binding.
  publication<-paste0('"',a,'".achillesnext_publication')
  baseline<-paste0('CREATE TRIGGER publication_transition BEFORE INSERT OR UPDATE ON ',publication,' FOR EACH ROW EXECUTE FUNCTION "',a,'".guard_publication_transition()')
  triggerSql<-function(sql)f('.store_transaction')(details,a,function(tx)tx$execute(sql))
  restoreTrigger<-function()triggerSql(paste0('DROP TRIGGER IF EXISTS publication_transition ON ',publication,';',baseline))
  bindingChecks<-function(enabled) {
    expectedBody<-body()
    variants<-list(
      paste0('DROP TRIGGER publication_transition ON ',publication),
      paste0('ALTER TABLE ',publication,' DISABLE TRIGGER publication_transition'),
      paste0('ALTER TABLE ',publication,' ENABLE REPLICA TRIGGER publication_transition'),
      paste0('DROP TRIGGER publication_transition ON ',publication,';',sub('guard_publication_transition()','guard_current_pointer()',baseline,fixed=TRUE)),
      paste0('DROP TRIGGER publication_transition ON ',publication,';',sub('FOR EACH ROW','FOR EACH STATEMENT',baseline,fixed=TRUE)),
      paste0('DROP TRIGGER publication_transition ON ',publication,';',sub('INSERT OR UPDATE','UPDATE',baseline,fixed=TRUE)),
      paste0('DROP TRIGGER publication_transition ON ',publication,';',sub('EXECUTE FUNCTION',"WHEN (NEW.state='ready') EXECUTE FUNCTION",baseline,fixed=TRUE)))
    for(sql in variants) {
      triggerSql(sql)
      tryCatch({
        error<-tryCatch({enableSavedTerminology(details,a);NULL},error=identity)
        stopifnot(inherits(error,'error'),identical(conditionMessage(error),'Modified publication trigger; no migration or repair attempted'),identical(body(),expectedBody),
          identical(!is.na(q(paste0("SELECT to_regclass('",a,".achillesnext_storage_extension')::text AS name"))$NAME),enabled))
      },finally=restoreTrigger())
    }
  }
  bindingChecks(FALSE)
  stopifnot(isTRUE(enableSavedTerminology(details,a)),identical(enableSavedTerminology(details,a),FALSE))
  bindingChecks(TRUE)
  custom<-paste0(def$new,'\n-- institutional customization\n');setBody(custom)
  expectError(function()enableSavedTerminology(details,a));stopifnot(identical(body(),custom))
  setBody(def$new);execute(paste0('DELETE FROM ',a,'.achillesnext_storage_extension'))
  expectError(function()enableSavedTerminology(details,a));stopifnot(identical(body(),def$new))
  execute(paste0('INSERT INTO ',a,".achillesnext_storage_extension VALUES ('saved-terminology','1.0.0')"))
  stopifnot(identical(enableSavedTerminology(details,a),FALSE),identical(q(paste0('SELECT revision::text AS value FROM ',a,'.achillesnext_current_publication'))$VALUE,'3'))
  cat('SAVED_TERMINOLOGY_EXPLICIT_ENABLEMENT_REFUSES_GUARD_DRIFT_OR_MISSING_MARKER_WITHOUT_REPAIR_OK\n')

  race<-paste0('term_race_',Sys.getpid());raceServe<-paste0('term_race_serve_',Sys.getpid())
  initializeResultStore(details,race,raceServe,'cdm_tiny_a_55')
  on.exit(execute(paste0('DROP SCHEMA "',raceServe,'" CASCADE; DROP SCHEMA "',race,'" CASCADE')),add=TRUE,after=FALSE)
  barrier<-tempfile('term-enable-barrier-');stopifnot(dir.create(barrier));on.exit(unlink(barrier,recursive=TRUE),add=TRUE)
  concurrent<-parallel::parLapply(cluster,1:2,function(i,lib,config,schema,barrier) {
    library(AchillesNext,lib.loc=lib);e<-new.env();sys.source(config,e)
    ns<-asNamespace('AchillesNext');original<-get('.store_transaction',ns);trace<-character()
    observed<-function(details,schema,work,...)original(details,schema,function(tx) {
      execute<-tx$execute;stream<-tx$stream
      tx$execute<-function(sql){trace<<-c(trace,paste0('execute:',sql));value<-execute(sql);if(grepl('achillesnext_storage_version IN EXCLUSIVE MODE',sql,fixed=TRUE))Sys.sleep(0.3);value}
      tx$stream<-function(sql,visit){trace<<-c(trace,paste0('stream:',sql));stream(sql,visit)}
      work(tx)
    },...)
    assignInNamespace('.store_transaction',observed,ns='AchillesNext');on.exit(assignInNamespace('.store_transaction',original,ns='AchillesNext'))
    stopifnot(file.create(file.path(barrier,as.character(i))))
    deadline<-Sys.time()+10
    while(!all(file.exists(file.path(barrier,c('1','2'))))&&Sys.time()<deadline)Sys.sleep(0.01)
    stopifnot(all(file.exists(file.path(barrier,c('1','2')))))
    value<-enableSavedTerminology(e$fixtureConnection('owner'),schema)
    list(value=value,first=trace[[1]])
  },lib=normalizePath(Sys.getenv('R_LIBS')),config=normalizePath(commandArgs(TRUE)[[1]]),schema=race,barrier=barrier)
  stopifnot(identical(sort(vapply(concurrent,function(x)x$value,TRUE)),c(FALSE,TRUE)),
    all(vapply(concurrent,function(x)identical(x$first,paste0('execute:LOCK TABLE "',race,'".achillesnext_storage_version IN EXCLUSIVE MODE')),TRUE)))
  cat('SAVED_TERMINOLOGY_TRIGGER_BINDING_14_MUTATIONS_AND_CONCURRENT_FIRST_ENABLE_TRUE_FALSE_OK\n')

  cat('RESULT_STORE_INSTALL_SEAL_AND_CONCURRENT_CAS_OK\n')
})
