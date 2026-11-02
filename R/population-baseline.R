.population_ids <- function() names(.v2_assets()$metrics)[grepl("^core[.](person|observation_period)[.]",names(.v2_assets()$metrics))]
.population_need <- function(ok,message) {
  if(!isTRUE(ok)) stop(structure(list(message=message,call=NULL),class=c("AchillesPopulationFailure","error","condition")))
}
.population_sql <- function(name,tokens) {
  stopifnot(name%in%c("demographics","union","people","periods","observation"))
  path<-system.file(paste0("sql/postgresql/population-",name,".sql"),package="AchillesNext",mustWork=TRUE)
  sql<-paste(readLines(path,warn=FALSE),collapse="\n")
  for(k in names(tokens))sql<-gsub(paste0("{{",k,"}}"),tokens[[k]],sql,fixed=TRUE)
  .nv_need(!grepl("{{",sql,fixed=TRUE),"Unbound population SQL token");sql
}
.population_preflight <- function(tx,schema) {
  tables<-list(person=c("person_id","year_of_birth","gender_concept_id","race_concept_id","ethnicity_concept_id"),
    observation_period=c("person_id","observation_period_start_date","observation_period_end_date","period_type_concept_id"))
  metadata<-list()
  tx$stream(paste0("SELECT jsonb_build_object('table',c.relname,'column',a.attname,'type',t.typname,'readable',has_schema_privilege(n.oid,'USAGE') AND has_column_privilege(c.oid,a.attname,'SELECT'))::text ",
    "FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid JOIN pg_type t ON t.oid=a.atttypid WHERE n.nspname=",.store_literal(schema),
    " AND c.relkind IN ('r','p','v','m','f') AND a.attnum>0 AND NOT a.attisdropped AND c.relname IN ('person','observation_period')"),function(text) {
      v<-.store_decode(text);metadata[[paste(v$table,v$column,sep=".")]]<<-v
    })
  for(table in names(tables)) {
    for(column in tables[[table]]) {
      m<-metadata[[paste(table,column,sep=".")]]
      .population_need(!is.null(m),paste("Missing required population column:",table,column))
      .population_need(isTRUE(m$readable),paste("Inaccessible population column:",table,column))
      .population_need(m$type%in%if(grepl("_date$",column))"date" else c("int2","int4","int8"),paste("Unsupported exact population type:",table,column))
    }
    source<-paste0('"',schema,'"."',table,'"')
    writable<-tx$one(paste0("SELECT (has_table_privilege(current_user,",.store_literal(source),",'INSERT,UPDATE,DELETE,TRUNCATE') OR has_any_column_privilege(current_user,",.store_literal(source),",'INSERT,UPDATE'))::text"))
    .population_need(writable=="false","Use a worker with SELECT-only source privileges")
  }
  .v2_hash(.v2_bytes(metadata))
}
.population_reconcile <- function(tx,id,datasets,totals) {
  s<-tx$schema;rid<-.store_uuid(id)
  sumField<-function(mid,field)tx$one(paste0("SELECT COALESCE(sum(",field,"),0)::text FROM ",s,".achillesnext_aggregate_cell WHERE release_id=",rid," AND metric_id=",.store_literal(mid)))
  for(mid in c(setdiff(.population_ids()[startsWith(.population_ids(),"core.person.")],"core.person.count"),
    "core.observation_period.person_interval_histogram","core.observation_period.total_days_histogram"))
    .population_need(sumField(mid,"person_count")==totals$person_count,"Stored population partitions do not reconcile")
  for(mid in c("core.observation_period.type_count","core.observation_period.integrity_count"))
    .population_need(sumField(mid,"record_count")==totals$raw_observation_count,"Stored observation integrity/type totals do not reconcile")
  .store_summary_checks(tx,id,datasets)
  invisible(TRUE)
}

#' Generate and persist the population/observation baseline
#' @param connectionDetails PostgreSQL worker credentials: SELECT-only CDM,
#'   TEMPORARY and writes to an already initialized restricted result store.
#' @param cdmSchema Source schema identifier.
#' @param sourceId Source identifier (at most 256 UTF-8 bytes).
#' @param resultsSchema Existing restricted result schema, distinct from source.
#' @param declaredCdmVersion Declared CDM version: 5.3, 5.4 or 5.5.
#' @param window Optional inclusive observed window; NULL derives full history.
#' @param maxStageBytes Total temporary relation/index bytes checked after stages.
#' @param check Optional cooperative cancellation callback; signal to roll back.
#' @param statementTimeoutMs Positive integer per-statement timeout in milliseconds.
#' @return Building release identity. This generates 19 of 142 outputs, not a
#'   publishable complete core release. No approval or current pointer is changed.
#' @export
generatePopulationObservationBaseline <- function(connectionDetails,cdmSchema,sourceId,resultsSchema,declaredCdmVersion,
  window=NULL,maxStageBytes=64*1024^2,check=NULL,statementTimeoutMs=30000L) {
  .baseline_generate(connectionDetails,cdmSchema,sourceId,resultsSchema,declaredCdmVersion,window,maxStageBytes,check,statementTimeoutMs,FALSE)
}
.baseline_generate <- function(connectionDetails,cdmSchema,sourceId,resultsSchema,declaredCdmVersion,
  window,maxStageBytes,check,statementTimeoutMs,domainMode,measurementMode=FALSE,numericStrategy="weighted",maxAggregateRows=NULL) {
  plan<-planCharacterizationBatch(cdmSchema,sourceId,declaredCdmVersion,window,"shared")
  .population_need(nchar(sourceId,type="bytes")<=256L && .batch_identifier(resultsSchema) && resultsSchema!="public" && resultsSchema!=cdmSchema,"Invalid baseline source/results configuration")
  .population_need(is.numeric(maxStageBytes)&&length(maxStageBytes)==1L&&is.finite(maxStageBytes)&&maxStageBytes>=0&&maxStageBytes<=2^53,"Invalid intermediate byte budget")
  .population_need(is.null(check)||is.function(check),"Invalid cancellation callback")
  .population_need(is.numeric(statementTimeoutMs)&&length(statementTimeoutMs)==1L&&!is.na(statementTimeoutMs)&&is.finite(statementTimeoutMs)&&
    statementTimeoutMs>=1&&statementTimeoutMs<=2147483647&&statementTimeoutMs==floor(statementTimeoutMs),"Invalid statement timeout")
  tick<-function()if(!is.null(check))check()
  tick();started<-.stamp();assets<-.v2_assets();ids<-c(.population_ids(),if(domainMode).domain_ids(measurementMode) else character())
  requested<-.object(producer_id=if(measurementMode)"measurement_baseline" else if(domainMode)"domain_baseline" else "population_observation_baseline",producer_revision="1.0.0",plan_sha256=plan$plan_sha256,
    requested_metric_ids=as.list(ids),scope=plan$scope)
  if(measurementMode)requested$numeric_strategy<-numericStrategy
  requestHash<-.hash(.json(requested))
  tryCatch(.store_transaction(connectionDetails,resultsSchema,function(tx) {
    tick();tx$execute(paste0("SET LOCAL statement_timeout=",as.integer(statementTimeoutMs)));tx$execute("SET LOCAL lock_timeout=2000")
    tx$execute("SET LOCAL timezone='UTC'");tx$execute("SET LOCAL datestyle='ISO,YMD'");tx$execute("SET LOCAL standard_conforming_strings=on")
    .population_need(tx$one(paste0("SELECT count(*)::text FROM ",tx$schema,".achillesnext_profile_registry WHERE profile_sha256=",.store_literal(assets$hash)))=="1","Install the matching core profile in the result store first")
    schemaHash<-.population_preflight(tx,cdmSchema)
    cap<-if(domainMode).domain_preflight(tx,cdmSchema,measurementMode) else NULL
    if(domainMode)schemaHash<-.hash(paste0(schemaHash,cap$hash))
    release<-.store_new_uuid();run<-.store_new_uuid();sourceRelease<-.store_new_uuid()
    prefix<-paste0("achillesnext_",gsub("-","",run,fixed=TRUE));stages<-character();stageTimings<-list();peak<-0
    stage<-function(suffix,sql,index=NULL) {
      tick();name<-paste0(prefix,"_",suffix);relation<-paste0('pg_temp."',name,'"');begin<-proc.time()[["elapsed"]]
      tx$execute(paste0('CREATE TEMP TABLE "',name,'" ON COMMIT DROP AS ',sql))
      if(!is.null(index))tx$execute(paste0("CREATE INDEX ON ",relation," (",index,")"))
      tx$execute(paste("ANALYZE",relation));stages<<-c(stages,relation)
      bytes<-as.numeric(tx$one(paste0("SELECT COALESCE(sum(pg_total_relation_size(to_regclass(x))),0)::text FROM unnest(ARRAY[",paste(vapply(stages,.store_literal,""),collapse=","),"]) x")))
      peak<<-max(peak,bytes);.population_need(bytes<=maxStageBytes,"Intermediate byte budget exceeded; generation rolled back")
      stageTimings[[suffix]]<<-list(duration_ms=.run_ms(begin),sql_sha256=.hash(sql));tick();relation
    }
    source<-paste0('"',cdmSchema,'"')
    person<-stage("person",paste0("SELECT person_id,year_of_birth,gender_concept_id,race_concept_id,ethnicity_concept_id FROM ",source,".person"),"person_id")
    integrity<-.store_decode(tx$one(paste0("SELECT jsonb_build_object('person_count',count(*)::text,'nonnull',count(person_id)::text,'distinct',count(DISTINCT person_id)::text)::text FROM ",person)))
    .population_need(integrity$person_count==integrity$nonnull&&integrity$person_count==integrity$distinct,"Null/duplicate PERSON identity; generation rolled back")
    raw<-stage("raw",paste0("SELECT o.person_id,o.observation_period_start_date AS start_date,o.observation_period_end_date AS end_date,o.period_type_concept_id,CASE WHEN o.person_id IS NULL THEN 'null_person' WHEN NOT EXISTS(SELECT 1 FROM ",person," p WHERE p.person_id=o.person_id) THEN 'orphan_person' WHEN o.observation_period_start_date IS NULL OR o.observation_period_end_date IS NULL THEN 'null_endpoints' WHEN o.observation_period_start_date>o.observation_period_end_date THEN 'reversed_interval' ELSE 'valid' END AS reason FROM ",source,".observation_period o"))
    .population_need(tx$one(paste0("SELECT count(*)::text FROM ",raw," WHERE (start_date IS NOT NULL AND NOT(start_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31')) OR (end_date IS NOT NULL AND NOT(end_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31'))"))=="0","Observation endpoints outside finite Gregorian contract; generation rolled back")
    intervals<-stage("union",.population_sql("union",list(raw=raw)),"person_id,start_date,end_date")
    people<-stage("people",.population_sql("people",list(person=person,intervals=intervals)))
    bounds<-.store_decode(tx$one(paste0("SELECT jsonb_build_object('start',min(start_date)::text,'end',max(end_date)::text)::text FROM ",intervals)))
    populationEffective<-window %||% bounds
    populationPeriods<-stage("populationperiods",.population_sql("periods",lapply(populationEffective,function(v)if(is.null(v))"NULL" else paste0("DATE ",.store_literal(v)))))
    domains<-if(domainMode).domain_prepare(list(one=tx$one,execute=tx$execute),cdmSchema,stage,person,intervals,cap,measurementMode) else NULL
    if(domainMode) {
      starts<-c(bounds$start,unlist(lapply(domains$counts,function(x)x$start)));ends<-c(bounds$end,unlist(lapply(domains$counts,function(x)x$end)))
      bounds<-list(start=if(length(starts))min(starts) else NULL,end=if(length(ends))max(ends) else NULL)
    }
    effective<-window %||% bounds
    periods<-if(domainMode)stage("periods",.domain_periods(effective)) else populationPeriods
    tokens<-list(person=person,raw=raw,intervals=intervals,people=people,periods=populationPeriods)
    populationSql<-paste0("SELECT * FROM (",.population_sql("demographics",tokens),") demographic UNION ALL SELECT * FROM (",.population_sql("observation",tokens),") observation")
    if(domainMode) {
      # Preserve the population producer's clipped scopes. Add exact canonical
      # coverage targets for domain denominators, without duplicating year people,
      # histograms or samples. UNION deduplicates coincident complete periods.
      tokens$periods<-periods
      populationSql<-paste0(populationSql," UNION SELECT * FROM (",.population_sql("observation",tokens),") calendar WHERE metric_id IN ('core.observation_period.coverage_count','core.observation_period.continuous_person_count')")
    }
    outputs<-c(stage("population",populationSql,"metric_id"))
    if(domainMode) {
      for(domain in .domain_names(measurementMode))outputs<-c(outputs,stage(paste0(domain,"reports"),
        if(domain=="measurement").measurement_reports(domains$tables[[domain]],person,periods,cap,numericStrategy) else .domain_reports(domain,domains$tables[[domain]],person,periods,cap),"metric_id"))
      outputs<-c(outputs,stage("density",.domain_density(person,domains$tables[.domain_names()],domains$measurement),"metric_id"))
    }
    output<-paste0("(",paste(paste("SELECT * FROM",outputs),collapse=" UNION ALL "),") output")
    if(measurementMode).population_need(.nv_unsigned_cmp(tx$one(paste("SELECT count(*)::text FROM",output)),format(maxAggregateRows,scientific=FALSE,trim=TRUE))<=0,"Aggregate row budget exceeded; generation rolled back")
    totals<-list(person_count=integrity$person_count,raw_observation_count=tx$one(paste("SELECT count(*)::text FROM",raw)),
      merged_interval_count=tx$one(paste("SELECT count(*)::text FROM",intervals)))
    unknown<-.object(state="unknown",value=NULL,basis=NULL,assertion_id=NULL,reason_code="source.no_verified_release")
    lit<-.store_literal;s<-tx$schema
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_source_release VALUES (",.store_uuid(sourceRelease),",",lit(sourceId),",",lit(.json(unknown)),"::jsonb,",lit(.json(unknown)),"::jsonb,",lit(schemaHash),",",lit(declaredCdmVersion),",now())"))
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_analysis_run(run_id,source_release_id,request_sha256,profile_id,profile_revision,profile_sha256,state,consistency_basis,started_at) VALUES (",
      .store_uuid(run),",",.store_uuid(sourceRelease),",",lit(requestHash),",",lit(assets$profile$profile_id),",",lit(assets$profile$revision),",",lit(assets$hash),",'running','single_repeatable_read',",lit(started),"::timestamptz)"))
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_result_release VALUES (",.store_uuid(release),",",.store_uuid(run),",'building',142,0,NULL)"))
    datasets<-list()
    for(mid in names(assets$metrics)) {
      m<-assets$metrics[[mid]];present<-mid%in%ids
      base<-if(startsWith(mid,"core.person.") || mid%in%c("core.observation_period.person_interval_histogram","core.observation_period.total_days_histogram"))totals$person_count else if(mid%in%c("core.observation_period.type_count","core.observation_period.integrity_count"))totals$raw_observation_count else totals$merged_interval_count
      state<-if(!present)"not_requested" else if(base!="0")"computed" else if(totals$person_count=="0" || mid%in%c("core.observation_period.type_count","core.observation_period.integrity_count"))"empty_source" else "empty_population"
      conditionalReason<-if(domainMode)domains$unsupported[[mid]] else NULL
      if(domainMode && mid%in%.domain_ids(measurementMode)) {
        domain<-strsplit(mid,".",fixed=TRUE)[[1]][2]
        base<-if(domain=="density")totals$person_count else domains$counts[[domain]]$raw
        state<-if(!is.null(conditionalReason))"unsupported" else if(base=="0")"empty_source" else "computed"
        if(is.null(conditionalReason) && startsWith(mid,"observed.") && domains$counts[[domain]]$observed=="0" && base!="0")state<-"empty_population"
        # A zero-domain histogram still describes every PERSON, rather than an
        # empty set. Capture ALL zero cells retain an explicit empty-source state.
        if(is.null(conditionalReason) && endsWith(mid,".distinct_concepts_histogram") && totals$person_count!="0")state<-"computed"
      }
      reason<-if(state=="computed")NULL else if(!present)"generator.not_implemented" else if(state=="unsupported")conditionalReason else if(state=="empty_source")"source.empty" else if(mid%in%.population_ids())"observation.no_valid_intervals" else "population.no_qualifying_events"
      count<-if(present)tx$one(paste0("SELECT count(*)::text FROM ",output," WHERE metric_id=",lit(mid))) else "0"
      d<-.object(metric_id=mid,version=m$version,population=m$population,grain=m$grain,row_schema_id=assets$rows[[mid]]$row_schema_id,
        definition_sha256=.v2_hash(.v2_bytes(m)),state=state,reason_code=reason,required=TRUE,
        conditional_support=.object(state=if(!present)"not_probed" else if(state=="unsupported")"schema_absent" else "supported",reason_code=if(!present || state=="unsupported")reason else NULL),rows=count,
        completeness=.object(scope_kind=if(!present)"declared_reduced" else if(state=="unsupported")"schema_conditional" else "standard_full",complete=present,excluded_record_count=if(present && state!="unsupported")"0" else NULL,reason_code=if(!present || state=="unsupported")reason else NULL))
      if(present){.v2_dataset(d);datasets[[mid]]<-d}
      tx$execute(paste0("INSERT INTO ",s,".achillesnext_dataset VALUES (",paste(c(.store_uuid(release),vapply(c(mid,m$version,m$population,m$grain,d$row_schema_id,d$definition_sha256,state),lit,""),if(is.null(reason))"NULL" else lit(reason),"true",paste0(lit(.json(d$conditional_support)),"::jsonb"),count,paste0(lit(.json(d$completeness)),"::jsonb")),collapse=","),")"))
    }
    writer<-.store_writer(tx,release);writtenRows<-0L
    for(mid in c("core.person.count",setdiff(ids,"core.person.count"))) {
      tick();d<-datasets[[mid]]
      tx$stream(.domain_stream_sql(tx,release,output,mid),function(text) {
        tick();writtenRows<<-writtenRows+1L
        if(measurementMode).population_need(writtenRows<=maxAggregateRows,"Aggregate row budget exceeded; generation rolled back")
        v<-.store_decode(text);state<-d$state;reason<-d$reason_code
        v$values<-lapply(v$values,.baseline_normalize)
        if(v$row_kind=="summary"&&v$values$n=="0"){state<-"empty_population";reason<-"summary.no_eligible"}
        row<-.object(row_key="",dimensions=v$dimensions,row_kind=v$row_kind,state=state,reason_code=reason,values=v$values,denominator_refs=list())
        if(domainMode && mid%in%.domain_ids(measurementMode)) {
          if(mid=="core.visit.care_setting_count" && v$dimensions$setting_kind=="place_of_service" && !is.null(domains$care_reason)) {
            row$state<-if(domains$care_reason=="capability.care_site_absent")"unsupported" else "unavailable";row$reason_code<-domains$care_reason;row['values']<-list(NULL)
          }
        }
        row$denominator_refs<-.domain_denominators(mid,row,v$denominator)
        row$row_key<-.v2_row_identity(assets$rows[[mid]],row);writer$add(mid,row)
      })
      # Subsequent metric queries may join these persisted denominator targets.
      writer$flush()
    }
    persistence<-writer$finish()
    .population_reconcile(tx,release,datasets,totals)
    if(domainMode).domain_reconcile(tx,release,datasets,domains$counts)
    ended<-.stamp();telemetry<-.object(request=plan$scope,producer_request=requested,source_schema=cdmSchema,observed_window=effective,totals=totals,domain_totals=if(domainMode)domains$counts else NULL,started_at=started,ended_at=ended,
      population_window=populationEffective,schema_conditional=if(domainMode)domains$unsupported else NULL,care_reason=if(domainMode)domains$care_reason else NULL,
      definitions=plan$definitions,stages=stageTimings,peak_intermediate_bytes=format(peak,scientific=FALSE,trim=TRUE),
      resource_limits=.object(statement_timeout_ms=as.character(statementTimeoutMs),max_stage_bytes=format(maxStageBytes,scientific=FALSE,trim=TRUE),max_aggregate_rows=if(measurementMode)as.character(maxAggregateRows) else NULL),persistence=persistence,reusable=FALSE)
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_operation VALUES (",.store_uuid(run),",",lit(if(measurementMode)"measurement_baseline.generate" else if(domainMode)"domain_baseline.generate" else "population_observation.generate"),",",lit(.hash(.json(plan$definitions))),",'succeeded','[]',",lit(.json(telemetry)),"::jsonb)"))
    tx$execute(paste0("UPDATE ",s,".achillesnext_analysis_run SET state='succeeded',finished_at=",lit(ended),"::timestamptz WHERE run_id=",.store_uuid(run)))
    tick();.object(release_id=release,run_id=run,profile_id=assets$profile$profile_id,profile_sha256=assets$hash,state="building",generated_metrics=as.list(ids),expected_metric_count="142",generated_metric_count=as.character(length(ids)),publishable=FALSE)
  },queryTimeoutSeconds=ceiling(statementTimeoutMs/1000)+1),error=function(e){if(inherits(e,"AchillesPopulationFailure"))stop(e);stop(if(domainMode)"Domain baseline generation failed; transaction rolled back" else "Population/observation generation failed; transaction rolled back",call.=FALSE)})
}
