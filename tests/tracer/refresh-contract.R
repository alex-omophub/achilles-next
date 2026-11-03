# Read-only compatibility probe, restricted to the marked synthetic database.
library(AchillesNext)
main<-function() {
  args<-commandArgs(TRUE);stopifnot(length(args)==2L)
  env<-new.env();sys.source(args[1],env);out<-normalizePath(args[2],mustWork=FALSE)
  stopifnot(dir.create(out,mode='0700'));out<-normalizePath(out)
  owner<-env$fixtureConnection('owner');connection<-DatabaseConnector::connect(owner)
  on.exit(DatabaseConnector::disconnect(connection),add=TRUE)
  ex<-function(sql)DatabaseConnector::executeSql(connection,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,'expected-error.txt'))
  q<-function(sql)DatabaseConnector::querySql(connection,sql,integer64AsNumeric=FALSE)
  guard<-q("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB=='achilles_next_fixtures',guard$MARKER=='AchillesNext synthetic fixture sandbox v1')
  results<-paste0('refresh_test_',Sys.getpid());serving<-paste0('refresh_serve_',Sys.getpid());installed<-FALSE
  on.exit(if(installed)ex(paste0('DROP SCHEMA "',serving,'","',results,'" CASCADE')),add=TRUE,after=FALSE)
  initializeResultStore(owner,results,serving,'cdm_tiny_a_55');installed<-TRUE
  reader<-jsonlite::fromJSON(Sys.getenv('ACHILLES_NEXT_SERVING_FIXTURE'));role<-reader$user
  stopifnot(grepl('^achilles_test_reader_[0-9a-f]+$',role))
  details<-DatabaseConnector::createConnectionDetails(dbms='postgresql',server='127.0.0.1/achilles_next_fixtures',port=as.integer(reader$port),user=role,password=reader$password)
  ex(paste0('GRANT USAGE ON SCHEMA "',results,'" TO ',role,'; GRANT SELECT ON "',results,'".achillesnext_storage_version TO ',role))
  probe<-function()inspectResultStore(details,results)
  compatible<-probe();stopifnot(compatible$storage_version=='2.0.0',compatible$version_compatible,
    !compatible$result_data_validated,!compatible$write_privileges_verified,!compatible$upgrade_performed,
    q(paste0("SELECT has_schema_privilege('",role,"','cdm_tiny_a_55','USAGE')::text AS allowed"))$ALLOWED=='false')
  rejects<-function(work) {
    message<-tryCatch({work();'accepted'},error=conditionMessage)
    stopifnot(message=='Result store version unavailable or unsupported; no migration performed')
  }
  marker<-paste0('"',results,'".achillesnext_storage_version')
  ex(paste0('REVOKE SELECT ON ',marker,' FROM ',role));rejects(probe)
  ex(paste0('GRANT SELECT ON ',marker,' TO ',role,'; ALTER TABLE ',marker,' RENAME TO original_version'))
  ex(paste0('CREATE TABLE ',marker,'(version text); GRANT SELECT ON ',marker,' TO ',role))
  rejects(probe)
  for(values in c("('3.0.0')","('2.0.0'),('2.0.0')","(NULL)","(repeat('x',33))")) {
    ex(paste0('TRUNCATE ',marker,'; INSERT INTO ',marker,' VALUES ',values));rejects(probe)
    stopifnot(q(paste0('SELECT count(*)::text AS n FROM ',marker))$N==if(values=="('2.0.0'),('2.0.0')")'2' else '1')
  }
  ex(paste0('DROP TABLE ',marker,'; ALTER TABLE "',results,'".original_version RENAME TO achillesnext_storage_version'))
  stopifnot(identical(probe(),compatible),q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N=='0',
    q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_current_publication'))$N=='0')
  jsonlite::write_json(list(status='passed',read_only_version_probe=TRUE,reader_has_no_cdm_access=TRUE,denied_empty_future_duplicate_null_oversized_markers='rejected',candidate_count='0',current_pointer_count='0'),file.path(out,'report.json'),pretty=TRUE,auto_unbox=TRUE)
  cat('REFRESH_STORE_VERSION_MINIMAL_PRIVILEGES_FAILURES_NO_CANDIDATE_OR_PROMOTION_OK\n')
}
main()
