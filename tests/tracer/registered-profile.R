# Independent fixture -> registered SQL -> guarded store -> approved pages -> read.
library(AchillesNext)
source("tools/benchmark/implementation_identity.R")
main <- function() {
  args <- commandArgs(TRUE);stopifnot(length(args)==2L)
  implementationIdentity(getwd())
  env <- new.env();sys.source(args[[1]],env)
  out <- args[[2]];stopifnot(!file.exists(out));dir.create(out,recursive=TRUE,mode="0700");out <- normalizePath(out)
  fixture <- jsonlite::fromJSON("tests/fixtures/reference-person-v1.json",simplifyVector=FALSE)
  f <- function(n)get(n,asNamespace("AchillesNext"));o <- f(".object");lit <- f(".store_literal");wire <- f(".json")
  rejects <- function(work)stopifnot(inherits(try(work(),silent=TRUE),"try-error"))
  assets <- f(".profile_assets")(fixture$profile_id);owner <- env$fixtureConnection("owner");runner <- env$fixtureConnection()
  connection <- DatabaseConnector::connect(owner);on.exit(DatabaseConnector::disconnect(connection),add=TRUE)
  ex <- function(sql)DatabaseConnector::executeSql(connection,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,"expected-error.txt"))
  q <- function(sql)DatabaseConnector::querySql(connection,sql,integer64AsNumeric=FALSE)
  guard <- q("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB=="achilles_next_fixtures",guard$MARKER=="AchillesNext synthetic fixture sandbox v1")
  source <- paste0("registered_source_",Sys.getpid());results <- paste0("registered_store_",Sys.getpid());serve <- paste0("registered_serve_",Sys.getpid())
  madeSource <- FALSE;madeStore <- FALSE
  on.exit({if(madeStore)ex(paste0('DROP SCHEMA "',serve,'","',results,'" CASCADE'));if(madeSource)ex(paste0('DROP SCHEMA "',source,'" CASCADE'))},add=TRUE,after=FALSE)
  ex(paste0('CREATE SCHEMA "',source,'"; CREATE TABLE "',source,'".person(person_id bigint,gender_concept_id bigint)'));madeSource <- TRUE
  for(person in fixture$people)ex(paste0('INSERT INTO "',source,'".person VALUES (',person$person_id,',',person$gender_concept_id %||% "NULL",')'))
  initializeResultStore(owner,results,serve,source);madeStore <- TRUE
  # Simulate a previously initialized core-only store. Registering the extension
  # appends definitions; it must not migrate or modify the original core profile.
  ex(paste0('DELETE FROM "',results,'".achillesnext_profile_registry WHERE profile_id=',lit(fixture$profile_id)))
  coreHash <- q(paste0('SELECT profile_sha256 AS h FROM "',results,'".achillesnext_profile_registry'))$H
  ex(paste0('GRANT USAGE ON SCHEMA "',source,'","',results,'" TO achilles_next_runner; GRANT SELECT ON "',source,'".person TO achilles_next_runner; GRANT SELECT ON ALL TABLES IN SCHEMA "',results,'" TO achilles_next_runner'))
  tables <- paste0('"',results,'".achillesnext_',c("source_release","analysis_run","operation","result_release","dataset","aggregate_cell","denominator_edge"))
  ex(paste0("GRANT INSERT ON ",paste(tables,collapse=",")," TO achilles_next_runner; GRANT UPDATE ON ",paste(tables[c(2,4,5)],collapse=",")," TO achilles_next_runner"))
  generate <- function(...) generateAnalysisProfile(runner,source,"fixture:registered",results,"5.5",fixture$profile_id,...)
  rejects(function()generate())
  stopifnot(identical(registerAnalysisProfile(owner,results,fixture$profile_id),assets$hash),
    identical(registerAnalysisProfile(owner,results,fixture$profile_id),assets$hash))
  rejects(function()registerAnalysisProfile(runner,results,fixture$profile_id))
  stopifnot(q(paste0('SELECT profile_sha256 AS h FROM "',results,'".achillesnext_profile_registry WHERE profile_id=\'core-characterization-v2\''))$H==coreHash)
  generated <- generate();stopifnot(generated$profile_complete,generated$aggregate_rows=="5",!generated$publishable)
  sealResultRelease(owner,results,generated$release_id);validateResultRelease(owner,results,generated$release_id)
  policy <- o(id="fixture-registered",revision="1",scope_kind="restricted",allow_metrics=as.list(names(assets$metrics)))
  approved <- publishResultRelease(owner,results,generated$release_id,file.path(out,"approved"),"fixture-registered","synthetic-review",policy,function(candidate)TRUE,"0")
  validateResultArtifact(approved$export_dir)
  root <- f(".v2_directory")(approved$export_dir);stopifnot(root$expected_metric_count=="2")
  compare <- function(rows) {
    stopifnot(setequal(names(rows),names(fixture$expected)))
    normalize <- function(rs)sort(vapply(rs,function(r)wire(o(dimensions=r$dimensions,values=r$values)),""),method="radix")
    for(mid in names(fixture$expected))stopifnot(identical(normalize(rows[[mid]]),normalize(fixture$expected[[mid]])))
  }
  collect <- function(directory) {
    rows <- list();f(".v2_directory")(directory,function(d,b){doc <- f(".nv_json")(b);if(doc$kind=="data")rows[[doc$metric_id]] <<- c(rows[[doc$metric_id]],doc$rows)});rows
  }
  compare(collect(approved$export_dir))
  concepts <- character();f(".v2_directory")(approved$export_dir,function(d,b){doc <- f(".nv_json")(b);if(doc$kind=="concept_catalogue")concepts <<- c(concepts,vapply(doc$entries,function(e)e$concept_tag$value,""))})
  stopifnot(setequal(concepts,c("-1","0","9007199254740993")))
  before <- q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N
  rejects(function()generate(maxRows=1L))
  ex(paste0('INSERT INTO "',source,'".person VALUES (1,0)'));rejects(function()generate());ex(paste0('DELETE FROM "',source,'".person WHERE ctid IN (SELECT ctid FROM "',source,'".person WHERE person_id=1 LIMIT 1)'))
  ex(paste0('INSERT INTO "',source,'".person VALUES (NULL,0)'));rejects(function()generate());ex(paste0('DELETE FROM "',source,'".person WHERE person_id IS NULL'))
  ex(paste0('ALTER TABLE "',source,'".person ALTER COLUMN gender_concept_id TYPE double precision'));rejects(function()generate())
  ex(paste0('ALTER TABLE "',source,'".person ALTER COLUMN gender_concept_id TYPE bigint USING gender_concept_id::bigint'))
  # Reload exact integers after the deliberately inexact source-type fixture.
  ex(paste0('TRUNCATE "',source,'".person'))
  for(person in fixture$people)ex(paste0('INSERT INTO "',source,'".person VALUES (',person$person_id,',',person$gender_concept_id %||% "NULL",')'))
  stopifnot(q(paste0('SELECT count(*)::text AS n FROM "',results,'".achillesnext_result_release'))$N==before)
  bad <- generate()
  ex(paste0('UPDATE "',results,'".achillesnext_aggregate_cell SET person_count=person_count+1 WHERE release_id=',lit(bad$release_id)," AND dimensions->>'gender_concept_id'='0'"))
  sealResultRelease(owner,results,bad$release_id);rejects(function()validateResultRelease(owner,results,bad$release_id))
  omitted <- policy;omitted$allow_metrics <- as.list(names(assets$metrics)[2])
  projection <- publishResultRelease(owner,results,generated$release_id,file.path(out,"omitted"),"fixture-omitted","synthetic-review",omitted,function(candidate)TRUE)
  stopifnot(!length(collect(projection$export_dir)))
  ex(paste0('TRUNCATE "',source,'".person'));empty <- generate();sealResultRelease(owner,results,empty$release_id);validateResultRelease(owner,results,empty$release_id)
  reader <- jsonlite::fromJSON(Sys.getenv("ACHILLES_NEXT_SERVING_FIXTURE"));role <- reader$user;stopifnot(grepl("^achilles_test_reader_[0-9a-f]+$",role))
  ex(paste0('GRANT USAGE ON SCHEMA "',serve,'" TO ',role,'; GRANT SELECT ON "',serve,'".achillesnext_approved_pages,"',serve,'".achillesnext_approved_current TO ',role,
    '; INSERT INTO "',results,'".achillesnext_audience_grant VALUES (\'fixture-registered\',',lit(role),',true)'))
  ex(paste0('REVOKE ALL ON SCHEMA "',source,'" FROM achilles_next_runner; DROP TABLE "',source,'".person'))
  jsonlite::write_json(list(serving_schema=serve,source_id="fixture:registered",publication_id=approved$publication_id,scope_id="fixture-registered",root_sha256=approved$root$sha256),file.path(out,"binding.json"),auto_unbox=TRUE)
  status <- system2(file.path(R.home("bin"),"Rscript"),c("--vanilla","tests/tracer/registered-profile-reader.R",shQuote(out)))
  stopifnot(status==0L);compare(jsonlite::fromJSON(file.path(out,"saved-readback.json"),simplifyVector=FALSE))
  stopifnot(q(paste0('SELECT publication_id::text AS id FROM "',results,'".achillesnext_current_publication'))$ID==approved$publication_id)
  jsonlite::write_json(list(status="passed",profile=fixture$profile_id,metrics=2,rows=5,independent_fixture=TRUE,source_table_dropped=TRUE,rollback="passed",partition_corruption="rejected",dependency_projection="passed",empty_source="passed",serving_only_fresh_process="passed"),file.path(out,"report.json"),auto_unbox=TRUE,pretty=TRUE)
  cat("REGISTERED_DEFINITION_SQL_FIXTURE_GENERATION_VALIDATION_PUBLICATION_SOURCE_DENIED_READ_OK\n")
}
`%||%` <- function(x,y)if(is.null(x))y else x
main()
