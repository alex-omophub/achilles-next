# Small marked synthetic database only. Source fixtures are owned/disposable;
# all execution uses SELECT-only runner privileges plus session-private TEMP.
library(AchillesNext)
source("tools/benchmark/implementation_identity.R")
main<-function() {
  args<-commandArgs(TRUE);stopifnot(length(args)==3L,args[3]%in%c("1","3"))
  trials<-as.integer(args[3])
  identity<-implementationIdentity(getwd())
  env<-new.env(parent=globalenv());sys.source(args[1],env)
  out<-normalizePath(args[2],mustWork=TRUE)
  input<-jsonlite::fromJSON(file.path(out,"input.json"),simplifyVector=FALSE)
  owner<-DatabaseConnector::connect(env$fixtureConnection("owner"))
  on.exit(DatabaseConnector::disconnect(owner),add=TRUE)
  q<-function(sql)DatabaseConnector::querySql(owner,sql,integer64AsNumeric=FALSE)
  ex<-function(sql)DatabaseConnector::executeSql(owner,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,"sql-error.txt"))
  guard<-q("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB=="achilles_next_fixtures",guard$MARKER=="AchillesNext synthetic fixture sandbox v1")
  environment<-list(R=R.version.string,DatabaseConnector=as.character(utils::packageVersion("DatabaseConnector")),
    java=rJava::.jcall('java/lang/System','S','getProperty','java.version'),
    PostgreSQL=as.list(q("SELECT version() AS version,current_setting('work_mem') AS work_mem,current_setting('shared_buffers') AS shared_buffers,current_setting('max_parallel_workers_per_gather') AS parallel_workers,current_setting('jit') AS jit,current_setting('block_size') AS block_size")[1,]))
  hadTemp<-q("SELECT has_database_privilege('achilles_next_runner',current_database(),'TEMPORARY')::text AS allowed")$ALLOWED=="true"
  if(!hadTemp) {
    ex('GRANT TEMPORARY ON DATABASE achilles_next_fixtures TO achilles_next_runner')
    on.exit(ex('REVOKE TEMPORARY ON DATABASE achilles_next_fixtures FROM achilles_next_runner'),add=TRUE,after=FALSE)
  }
  schema<-paste0("cdm_tiny_batch_",Sys.getpid(),"_55")
  created<-FALSE
  on.exit(if(created) ex(paste0('DROP SCHEMA "',schema,'" CASCADE')),add=TRUE,after=FALSE)
  ex(paste0('CREATE SCHEMA "',schema,'"; COMMENT ON SCHEMA "',schema,'" IS \'AchillesNext synthetic fixture sandbox v1: batch primitives\''));created<-TRUE
  literal<-AchillesNext:::.store_literal
  table<-function(name)paste0('"',schema,'"."',name,'"')
  domains<-AchillesNext:::.v2_assets()$profile$domains
  ex(paste0('CREATE TABLE ',table('person'),'(person_id bigint); CREATE TABLE ',table('observation_period'),
    '(person_id bigint,observation_period_start_date date,observation_period_end_date date); CREATE TABLE ',table('concept'),
    "(concept_id integer,domain_id text); INSERT INTO ",table('concept')," VALUES(201,'Unit'),(201,'Unit'),(202,'Unit'),(203,'Measurement')"))
  for(d in domains) ex(paste0('CREATE TABLE ',table(d$table),'(person_id bigint,"',d$concept,'" integer,"',d$event_date,
    '" date,value_as_number numeric,unit_concept_id integer,operator_concept_id integer)'))
  ex(paste0('GRANT USAGE ON SCHEMA "',schema,'" TO achilles_next_runner; GRANT SELECT ON ALL TABLES IN SCHEMA "',schema,'" TO achilles_next_runner'))
  noTemps<-function() q("SELECT count(*)::text AS n FROM pg_class WHERE relpersistence='t' AND relname~'^achillesnext_[0-9a-f]{16}_[0-9a-f]{16}$'")$N
  baseline<-noTemps()
  window<-list(start="2020-01-15",end="2020-02-15")
  runs<-list()
  rows<-function(df) {
    names(df)<-tolower(names(df))
    jsonlite::fromJSON(jsonlite::toJSON(df,dataframe="rows",na="null"),simplifyVector=FALSE)
  }
  batch<-AchillesNext:::.batch_with_workspace
  for(case in input) {
    ex(paste0('TRUNCATE ',paste(vapply(c('person','observation_period',vapply(domains,function(d)d$table,"")),table,""),collapse=',')))
    if(length(case$data$people)) ex(paste0('INSERT INTO ',table('person'),' VALUES ',paste0('(',unlist(case$data$people),')',collapse=',')))
    values<-vapply(case$data$intervals,function(r)paste0('(',paste(vapply(r,function(v)if(is.null(v))'NULL' else literal(as.character(v)),""),collapse=','),')'),"")
    if(length(values)) ex(paste0('INSERT INTO ',table('observation_period'),' VALUES ',paste(values,collapse=',')))
    json<-literal(AchillesNext:::.json(case$data$events))
    for(d in domains) ex(paste0('INSERT INTO ',table(d$table),' SELECT person_id,concept_id,event_date,value_as_number,unit_concept_id,operator_concept_id FROM jsonb_to_recordset(',json,
      '::jsonb) AS x(person_id bigint,concept_id integer,event_date date,value_as_number numeric,unit_concept_id integer,operator_concept_id integer)'))
    for(t in c('person','observation_period',vapply(domains,function(d)d$table,""))) ex(paste('ANALYZE',table(t)))
    for(trial in seq_len(trials)) for(mode in if(trial%%2L==1L)c("reference","shared") else c("shared","reference")) {
      plan<-planCharacterizationBatch(schema,"fixture:batch","5.5",window,mode)
      started<-proc.time()[["elapsed"]]
      result<-batch(env$fixtureConnection(),plan,function(w) {
        permission<-w$aggregate("role.check",paste0("SELECT has_table_privilege(current_user,'",table('person'),"','SELECT')::text AS readable,has_table_privilege(current_user,'",table('person'),"','INSERT,UPDATE,DELETE')::text AS writable"))
        stopifnot(permission$READABLE=="true",permission$WRITABLE=="false")
        settings<-w$aggregate("settings.check","SELECT current_setting('statement_timeout') AS statement_timeout,current_setting('lock_timeout') AS lock_timeout,current_setting('timezone') AS timezone")
        stopifnot(settings$STATEMENT_TIMEOUT=="30s",settings$LOCK_TIMEOUT=="2s",settings$TIMEZONE=="UTC")
        interval<-if(mode=="shared")w$stage("observation.union",AchillesNext:::.batch_interval_sql(plan),indexColumns=c("person_id","start_date","end_date")) else NULL
        coverageSql<-paste0('WITH intervals AS (',if(mode=="shared")paste('SELECT * FROM',interval) else AchillesNext:::.batch_interval_sql(plan),') SELECT * FROM (',AchillesNext:::.batch_coverage_sql(plan),') coverage')
        coverage<-rows(w$aggregate("observation.coverage",coverageSql,if(mode=="shared")"observation.union" else character()))
        output<-list()
        for(domain in names(domains)) {
          classId<-paste0(domain,".classification")
          classified<-if(mode=="shared")w$stage(classId,paste0('WITH intervals AS (SELECT * FROM ',interval,') ',AchillesNext:::.batch_classification_sql(plan,domain)),"observation.union") else NULL
          compile<-function(sql) if(mode=="shared")paste0('WITH classified AS (SELECT * FROM ',classified,') SELECT * FROM (',sql,') output') else AchillesNext:::.batch_reference_sql(plan,domain,sql)
          deps<-if(mode=="shared")classId else character()
          capture<-w$aggregate(paste0(domain,".capture"),compile(AchillesNext:::.batch_capture_sql(window)),deps)
          # An independent set-based consumer exercises sharing across grains;
          # no per-concept statements and no additive distinct-person rollup.
          histogram<-w$aggregate(paste0(domain,".person.frequencies"),compile('SELECT concept_id::text AS concept_id,n::text AS records_per_person,COUNT(*)::text AS people FROM (SELECT concept_id,person_id,COUNT(*) AS n FROM classified WHERE linked_person GROUP BY concept_id,person_id) h GROUP BY concept_id,n'),deps)
          stopifnot(sum(as.numeric(histogram$PEOPLE)*as.numeric(histogram$RECORDS_PER_PERSON))<=length(case$data$events))
          numeric<-if(domain%in%c("measurement","observation")) rows(w$aggregate(paste0(domain,".numeric"),compile(AchillesNext:::.batch_numeric_sql("reference")),deps)) else list()
          if(domain%in%c("measurement","observation")) {
            weighted<-rows(w$aggregate(paste0(domain,".weighted"),compile(AchillesNext:::.batch_numeric_sql("weighted")),deps))
            # SQL may render equivalent decimal strings with different scales;
            # Python compares both strategies independently to exact Decimal.
            output[[paste0(domain,"_weighted")]]<-list(capture=rows(capture),numeric=weighted,linked_event_frequency=rows(histogram))
          }
          output[[domain]]<-list(capture=rows(capture),numeric=numeric,linked_event_frequency=rows(histogram))
        }
        list(domains=output,coverage=coverage)
      },analyze=TRUE)
      controls<-result$telemetry$statements[seq_len(3L)]
      expected<-c("SET LOCAL statement_timeout=30000","SET LOCAL lock_timeout=2000","SET LOCAL timezone='UTC'")
      stopifnot(identical(vapply(controls,function(s)s$sql_sha256,""),vapply(expected,AchillesNext:::.hash,"",USE.NAMES=FALSE)),
        all(vapply(controls,function(s)s$kind=="execute" && s$state=="succeeded",TRUE)),
        result$telemetry$statement_count==length(result$telemetry$statements))
      stopifnot(noTemps()==baseline)
      runs[[length(runs)+1L]]<-list(case=case$id,trial=trial,mode=mode,elapsed_ms=(proc.time()[["elapsed"]]-started)*1000,
        outputs=result$value$domains,coverage=result$value$coverage,telemetry=result$telemetry)
    }
  }
  plan<-planCharacterizationBatch(schema,"fixture:batch","5.5",window,"shared")
  fails<-function(work,text)stopifnot(grepl(text,tryCatch({work();"accepted"},error=conditionMessage),fixed=TRUE),noTemps()==baseline)
  failures<-list()
  fails(function()batch(env$fixtureConnection(),plan,function(w){w$stage("oversize","SELECT generate_series(1,10) AS n")},maxStageBytes=0),"Intermediate byte budget exceeded")
  fails(function()batch(env$fixtureConnection(),plan,function(w){w$stage("temporary","SELECT 1 AS n");stop("injected failure")}),"injected failure")
  fails(function()batch(env$fixtureConnection(),plan,function(w){w$stage("timeout","SELECT 1 AS n FROM pg_sleep(5)")},statementTimeoutMs=100,analyze=TRUE),"TRACER_QUERY_FAILED")
  count<-0L
  fails(function()batch(env$fixtureConnection(),plan,function(w){w$stage("temporary","SELECT 1 AS n")},check=function(){count<<-count+1L;if(count==3L)stop("cancelled")}),"cancelled")
  fails(function()batch(env$fixtureConnection(),plan,function(w){w$stage("dependent","SELECT 1",dependencies="absent")}),"unverified intermediate")
  fails(function()batch(env$fixtureConnection(),plan,function(w){w$stage("temporary","SELECT 1 AS n");w$stage("temporary","SELECT 2 AS n")}),"Intermediate identity changed")
  first<-batch(env$fixtureConnection(),plan,function(w) {
    relation<-w$stage("same","SELECT 1 AS n")
    stopifnot(identical(relation,w$stage("same","SELECT 1 AS n")))
    tempSchema<-w$aggregate("temp.schema","SELECT pg_my_temp_schema()::regnamespace::text AS schema")$SCHEMA
    foreign<-sub("pg_temp",tempSchema,relation,fixed=TRUE)
    error<-tryCatch({batch(env$fixtureConnection(),plan,function(other)other$aggregate("foreign",paste("SELECT * FROM",foreign)));"accepted"},error=conditionMessage)
    stopifnot(error!="accepted")
    second<-batch(env$fixtureConnection(),plan,function(other){other$stage("same","SELECT 1 AS n");other$transaction_key})
    stopifnot(second$value!=w$transaction_key,second$telemetry$stages[[1]]$state=="computed")
    w$transaction_key
  })
  stopifnot(any(vapply(first$telemetry$stages,function(s)s$state=="reused",TRUE)),noTemps()==baseline,
    identical(identity,implementationIdentity(getwd())))
  before<-batch(env$fixtureConnection(),plan,function(w)w$aggregate("population",paste('SELECT COUNT(*)::text AS n FROM',table('person'))))
  ex(paste0('INSERT INTO ',table('person'),' VALUES(6)'))
  after<-batch(env$fixtureConnection(),plan,function(w)w$aggregate("population",paste('SELECT COUNT(*)::text AS n FROM',table('person'))))
  stopifnot(before$value$N=="5",after$value$N=="6",before$telemetry$transaction_key!=after$telemetry$transaction_key)
  ex(paste0('ALTER TABLE ',table('person'),' ADD COLUMN changed_schema integer'))
  changed<-batch(env$fixtureConnection(),plan,function(w)w$aggregate("population",paste('SELECT COUNT(*)::text AS n FROM',table('person'))))
  stopifnot(changed$value$N=="6",changed$telemetry$schema_sha256!=after$telemetry$schema_sha256,
    changed$telemetry$stages[[1]]$state=="computed")
  ex(paste0('INSERT INTO ',table('person'),'(person_id) VALUES(6)'))
  fails(function()batch(env$fixtureConnection(),plan,function(w)stop('must not reach work')),"Invalid PERSON identity")
  report<-list(runs=runs,implementation=identity,environment=environment,cleanup="verified_no_owned_temporary_relations_after_success_failure_cancellation_budget_error",
    unmeasured=list(CPU="not collected in this bounded primitive probe",RSS="not collected",source_bytes="not exposed by EXPLAIN",OS_cache="uncontrolled"),
    access="source_SELECT_only; other_backend_TEMP_denied",reuse="same_transaction_verified_keys_only; new_transaction_recomputed",
    failure_tests="budget,callback_error,statement_timeout,cancellation,missing_dependency,changed_SQL,invalid_PERSON,source_change_recompute; old_publications_untouched")
  writeLines(AchillesNext:::.json(report),file.path(out,"report.json"),useBytes=TRUE)
  cat("PASS: run-scoped source-read-only staging; exact period/numeric probes; isolation, dependency identity, budget/failure/cancellation cleanup\n")
}
main()
