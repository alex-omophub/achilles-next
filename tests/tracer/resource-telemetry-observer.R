# Observer fault handling; optional marked-fixture transaction probe.
library(AchillesNext)
source('tools/benchmark/matched_reference.R')
source('tools/benchmark/resource_telemetry.R')
local({
  directories<-character()
  on.exit(for(path in directories)unlink(path,recursive=TRUE),add=TRUE)
  fresh<-function() {
    out<-tempfile('telemetry-observer-');dir.create(out);directories<<-c(directories,out)
    observer<-resourceTelemetry(out,NULL,character(),'cdm_synthetic_probe')
    list(observer=observer,scope=environment(observer$phase),out=out)
  }
  failure<-function(work)tryCatch({work();NULL},error=identity)
  closed<-function(log)!tryCatch(isOpen(log),error=function(e)FALSE)

  # A secondary end-record error must preserve the original condition object.
  test<-fresh();write<-test$scope$write
  test$scope$write<-function(row)if(row$event=='end')stop('end record failed') else write(row)
  original<-structure(list(message='analytical failure',call=NULL),class=c('analytical_probe','error','condition'))
  error<-failure(function()test$observer$phase('failure',function()stop(original)))
  stopifnot(identical(error,original),!length(test$scope$stack))
  test$scope$write<-write;test$observer$finish('failed')
  stopifnot(closed(test$scope$log))

  # An end-record failure after successful work must still reject the phase.
  test<-fresh();write<-test$scope$write
  test$scope$write<-function(row)if(row$event=='end')stop('end record failed') else write(row)
  error<-failure(function()test$observer$phase('success',function()42L))
  stopifnot(identical(conditionMessage(error),'end record failed'),!length(test$scope$stack))
  test$scope$write<-write;test$observer$finish('failed')

  # Summary errors close the connection, retain their condition, and are idempotent.
  test<-fresh();original<-simpleError('summary failed')
  test$scope$write<-function(row)stop(original)
  error<-failure(function()test$observer$finish('failed'))
  stopifnot(identical(error,original),isTRUE(test$scope$closed),closed(test$scope$log))
  stopifnot(is.null(test$observer$finish('failed')))

  # A complete normal journal is closed and has one summary.
  test<-fresh();stopifnot(identical(test$observer$phase('normal',function()42L),42L))
  test$observer$finish('passed');test$observer$finish('passed')
  records<-lapply(readLines(file.path(test$out,'phases.jsonl')),jsonlite::fromJSON)
  stopifnot(closed(test$scope$log),identical(vapply(records,`[[`,'','event'),c('begin','end','summary')))
  cat('PASS: observer preserves primary errors, rejects missing successful end records and closes journals\n')

  args<-commandArgs(TRUE);stopifnot(length(args)<=1L)
  if(!length(args))return(invisible(NULL))
  config<-new.env();sys.source(args[1],config)
  owner<-DatabaseConnector::connect(config$fixtureConnection('owner'))
  on.exit(DatabaseConnector::disconnect(owner),add=TRUE)
  f<-function(n)get(n,asNamespace('AchillesNext'))
  guard<-f('.store_decode')(referenceOne(owner,"SELECT jsonb_build_object('db',current_database(),'usr',current_user,'marker',shobj_description(oid,'pg_database'))::text FROM pg_database WHERE datname=current_database()"))
  stopifnot(guard$db=='achilles_next_fixtures',guard$usr=='achilles_next_fixture_owner',guard$marker=='AchillesNext synthetic fixture sandbox v1')

  # Reproduce the PostgreSQL failure: catching a SQL error does not clear abort.
  aborted<-FALSE
  error<-failure(function()f('.store_transaction')(config$fixtureConnection('owner'),'achillesnext_telemetry_probe',function(tx) {
    stopifnot(inherits(failure(function()tx$one('SELECT 1/0')),'error'))
    error<-failure(function()tx$one('SELECT 1::text'))
    aborted<<-inherits(error,'error')&&grepl('current transaction is aborted',conditionMessage(error),fixed=TRUE)
    stop('expected raw probe abort')
  }))
  stopifnot(aborted,identical(conditionMessage(error),'expected raw probe abort'))

  # Inject real division-by-zero ONLY for optional temp-size SQL, then continue
  # using the same PostgreSQL transaction. Its created relation must survive.
  test<-fresh();injected<-0L
  result<-f('.store_transaction')(config$fixtureConnection('owner'),'achillesnext_telemetry_probe',function(tx) {
    one<-tx$one
    tx$one<-function(sql)if(grepl('pg_my_temp_schema()',sql,fixed=TRUE)) {
      injected<<-injected+1L;one('SELECT 1/0')
    } else one(sql)
    observed<-test$scope$decorate(tx)
    observed$execute('CREATE TEMP TABLE telemetry_probe AS SELECT 7 AS value')
    stopifnot(identical(observed$one('SELECT value::text FROM telemetry_probe'),'7'))
    observed$execute('CREATE INDEX telemetry_probe_idx ON telemetry_probe(value)')
    stopifnot(identical(observed$one('SELECT (value+1)::text FROM telemetry_probe'),'8'),
      identical(observed$one("SELECT (to_regclass('pg_temp.telemetry_probe_idx') IS NOT NULL)::text"),'true'))
    TRUE
  })
  stopifnot(isTRUE(result),injected==2L,test$scope$tempUnavailable==2L,test$scope$tempSamples==0L)
  test$observer$finish('passed')
  summary<-tail(lapply(readLines(file.path(test$out,'phases.jsonl')),jsonlite::fromJSON),1L)[[1]]
  stopifnot(summary$sampled_temp_relation_peak_bytes$state=='unavailable',summary$temp_samples_unavailable==2L)
  cat('PASS: raw SQL probe abort reproduced; two failed saved probes preserve created data and subsequent SQL\n')
})
