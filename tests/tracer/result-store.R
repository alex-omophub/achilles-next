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
  expectError <- function(work) { failed <- FALSE;tryCatch(work(),error=function(e) failed<<-TRUE);stopifnot(failed) }
  expectError(function() initializeResultStore(details,a,a,'cdm_tiny_a_55'))
  expectError(function() initializeResultStore(details,'cdm_tiny_a_55',b,'cdm_tiny_a_55'))
  stopifnot(identical(q(paste0('SELECT version FROM ',a,'.storage_version'))$VERSION,'2.0.0'))
  definition <- jsonlite::toJSON(list(profile_id='test',revision='0',metrics=list(list(id='test.count',version='1',population='person',grain='source',availability='required_when_table_readable'))),auto_unbox=TRUE)
  profileHash <- digest::digest(charToRaw(definition),algo='sha256',serialize=FALSE)
  hex <- paste(sprintf('%02x',as.integer(charToRaw(definition))),collapse='')
  execute(paste0("INSERT INTO ",a,".profile_registry VALUES ('",profileHash,"','test','0',decode('",hex,"','hex'),convert_from(decode('",hex,"','hex'),'UTF8')::jsonb)"))
  execute(paste0("INSERT INTO ",a,".source_release VALUES ('00000000-0000-0000-0000-000000000001','fixture:test','{}','{}',repeat('a',64),'5.5',now());",
   "INSERT INTO ",a,".analysis_run(run_id,source_release_id,request_sha256,profile_id,profile_revision,profile_sha256,state,consistency_basis) VALUES ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001',repeat('b',64),'test','0','",profileHash,"','succeeded','single_repeatable_read');",
   "INSERT INTO ",a,".result_release VALUES ('00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002','building',1,0,null);",
   "INSERT INTO ",a,".dataset VALUES ('00000000-0000-0000-0000-000000000003','test.count','1','person','source','counts',repeat('d',64),'computed',null,true,'{}',1,'{}');",
   "INSERT INTO ",a,".aggregate_cell(release_id,metric_id,row_key,route_key,sort_key,dimensions,state,payload_kind,person_count) VALUES ('00000000-0000-0000-0000-000000000003','test.count',repeat('1',64),'all','all','{}','computed','counts',9007199254740993);"))
  stopifnot(identical(q(paste0('SELECT person_count::text AS value FROM ',a,'.aggregate_cell'))$VALUE,'9007199254740993'))
  sealedRevision <- sealResultRelease(details,a,'00000000-0000-0000-0000-000000000003')
  stopifnot(identical(sealedRevision,'2'))
  execute(paste0("DO $test$ BEGIN BEGIN UPDATE ",a,".aggregate_cell SET person_count=0; RAISE EXCEPTION 'Mutation accepted'; EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Release is not writable' THEN RAISE; END IF; END; END $test$;"))
  stopifnot(identical(q(paste0('SELECT person_count::text AS value FROM ',a,'.aggregate_cell'))$VALUE,'9007199254740993'))
  execute(paste0("INSERT INTO ",a,".validation_receipt VALUES ('00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000003',",sealedRevision,",'test-only','",profileHash,"',true,now(),repeat('e',64)); UPDATE ",a,".result_release SET state='validated';"))
  for (pub in c('00000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000008')) {
    # Deliberately minimal root tests SQL context guards, not full wire validation.
    root <- jsonlite::toJSON(list(contract_version='2.0.0',publication_id=pub,release_id='00000000-0000-0000-0000-000000000003',source_id='fixture:test',profile_id='test',profile_revision='0',profile_sha256=profileHash,access_scope_id='test',eligible_for_current_pointer=TRUE,publication_state='ready'),auto_unbox=TRUE)
    rootHash <- digest::digest(charToRaw(root),algo='sha256',serialize=FALSE)
    rootHex <- paste(sprintf('%02x',as.integer(charToRaw(root))),collapse='')
    execute(paste0("INSERT INTO ",a,".publication VALUES ('",pub,"','00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000004','test',repeat('f',64),'test-only','",rootHash,"','building',now(),null); INSERT INTO ",a,".page_object VALUES ('",pub,"','",rootHash,"','root',decode('",rootHex,"','hex')); UPDATE ",a,".publication SET state='ready',approved_at=now() WHERE publication_id='",pub,"';"))
  }
  first <- '00000000-0000-0000-0000-000000000005';second <- '00000000-0000-0000-0000-000000000006'
  stopifnot(identical(promoteResultPublication(details,a,first,'0'),'1'))
  stopifnot(identical(promoteResultPublication(details,a,first,'0'),'1'))
  expectError(function() promoteResultPublication(details,a,second,'0'))
  stopifnot(identical(q(paste0('SELECT publication_id::text AS id FROM ',a,'.current_publication'))$ID,first))
  stopifnot(identical(promoteResultPublication(details,a,second,'1'),'2'))
  execute(paste0("DO $test$ BEGIN BEGIN UPDATE ",a,".publication SET state='building'; RAISE EXCEPTION 'Reopen accepted'; EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Approved publication is immutable' THEN RAISE; END IF; END; END $test$;"))
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
  stopifnot(identical(q(paste0('SELECT revision::text AS value FROM ',a,'.current_publication'))$VALUE,'3'))
  cat('RESULT_STORE_INSTALL_SEAL_AND_CONCURRENT_CAS_OK\n')
})
