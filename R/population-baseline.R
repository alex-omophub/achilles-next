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
  plan<-planCharacterizationBatch(cdmSchema,sourceId,declaredCdmVersion,window,"shared")
  .population_need(nchar(sourceId,type="bytes")<=256L && .batch_identifier(resultsSchema) && resultsSchema!="public" && resultsSchema!=cdmSchema,"Invalid baseline source/results configuration")
  .population_need(is.numeric(maxStageBytes)&&length(maxStageBytes)==1L&&is.finite(maxStageBytes)&&maxStageBytes>=0&&maxStageBytes<=2^53,"Invalid intermediate byte budget")
  .population_need(is.null(check)||is.function(check),"Invalid cancellation callback")
  .population_need(is.numeric(statementTimeoutMs)&&length(statementTimeoutMs)==1L&&!is.na(statementTimeoutMs)&&is.finite(statementTimeoutMs)&&
    statementTimeoutMs>=1&&statementTimeoutMs<=2147483647&&statementTimeoutMs==floor(statementTimeoutMs),"Invalid statement timeout")
  tick<-function()if(!is.null(check))check()
  tick();started<-.stamp();assets<-.v2_assets();ids<-.population_ids()
  requested<-.object(producer_id="population_observation_baseline",producer_revision="1.0.0",plan_sha256=plan$plan_sha256,
    requested_metric_ids=as.list(ids),scope=plan$scope)
  requestHash<-.hash(.json(requested))
  tryCatch(.store_transaction(connectionDetails,resultsSchema,function(tx) {
    tick();tx$execute(paste0("SET LOCAL statement_timeout=",as.integer(statementTimeoutMs)));tx$execute("SET LOCAL lock_timeout=2000")
    tx$execute("SET LOCAL timezone='UTC'");tx$execute("SET LOCAL datestyle='ISO,YMD'");tx$execute("SET LOCAL standard_conforming_strings=on")
    .population_need(tx$one(paste0("SELECT count(*)::text FROM ",tx$schema,".achillesnext_profile_registry WHERE profile_sha256=",.store_literal(assets$hash)))=="1","Install the matching core profile in the result store first")
    schemaHash<-.population_preflight(tx,cdmSchema)
    release<-.store_new_uuid();run<-.store_new_uuid();sourceRelease<-.store_new_uuid()
    prefix<-paste0("achillesnext_",gsub("-","",run,fixed=TRUE));stages<-character();stageTimings<-list();peak<-0
    stage<-function(suffix,sql,index=NULL) {
      tick();name<-paste0(prefix,"_",suffix);relation<-paste0('pg_temp."',name,'"');begin<-proc.time()[["elapsed"]]
      tx$execute(paste0('CREATE TEMP TABLE "',name,'" ON COMMIT DROP AS ',sql))
      if(!is.null(index))tx$execute(paste0("CREATE INDEX ON ",relation," (",index,")"))
      tx$execute(paste("ANALYZE",relation));stages<<-c(stages,relation)
      bytes<-as.numeric(tx$one(paste0("SELECT sum(pg_total_relation_size(x::regclass))::text FROM unnest(ARRAY[",paste(vapply(stages,.store_literal,""),collapse=","),"]) x")))
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
    effective<-window %||% bounds
    periods<-stage("periods",.population_sql("periods",lapply(effective,function(v)if(is.null(v))"NULL" else paste0("DATE ",.store_literal(v)))))
    tokens<-list(person=person,raw=raw,intervals=intervals,people=people,periods=periods)
    output<-stage("output",paste0("SELECT * FROM (",.population_sql("demographics",tokens),") demographic UNION ALL SELECT * FROM (",.population_sql("observation",tokens),") observation"))
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
      reason<-if(state=="computed")NULL else if(!present)"generator.not_implemented" else if(state=="empty_source")"source.empty" else "observation.no_valid_intervals"
      count<-if(present)tx$one(paste0("SELECT count(*)::text FROM ",output," WHERE metric_id=",lit(mid))) else "0"
      d<-.object(metric_id=mid,version=m$version,population=m$population,grain=m$grain,row_schema_id=assets$rows[[mid]]$row_schema_id,
        definition_sha256=.v2_hash(.v2_bytes(m)),state=state,reason_code=reason,required=TRUE,
        conditional_support=.object(state=if(present)"supported" else "not_probed",reason_code=if(present)NULL else reason),rows=count,
        completeness=.object(scope_kind=if(present)"standard_full" else "declared_reduced",complete=present,excluded_record_count=if(present)"0" else NULL,reason_code=if(present)NULL else reason))
      if(present){.v2_dataset(d);datasets[[mid]]<-d}
      tx$execute(paste0("INSERT INTO ",s,".achillesnext_dataset VALUES (",paste(c(.store_uuid(release),vapply(c(mid,m$version,m$population,m$grain,d$row_schema_id,d$definition_sha256,state),lit,""),if(is.null(reason))"NULL" else lit(reason),"true",paste0(lit(.json(d$conditional_support)),"::jsonb"),count,paste0(lit(.json(d$completeness)),"::jsonb")),collapse=","),")"))
    }
    personKey<-.v2_row_identity(assets$rows[["core.person.count"]],.object(row_kind="counts",dimensions=.object()))
    for(mid in c("core.person.count",setdiff(ids,"core.person.count"))) {
      tick();d<-datasets[[mid]]
      tx$stream(paste0("SELECT jsonb_build_object('row_kind',row_kind,'dimensions',dimensions,'values',values)::text FROM ",output," WHERE metric_id=",lit(mid)),function(text) {
        tick();v<-.store_decode(text);state<-d$state;reason<-d$reason_code
        if(v$row_kind=="summary"&&v$values$n=="0"){state<-"empty_population";reason<-"summary.no_eligible"}
        row<-.object(row_key="",dimensions=v$dimensions,row_kind=v$row_kind,state=state,reason_code=reason,values=v$values,denominator_refs=list())
        if(startsWith(mid,"core.person.")&&mid!="core.person.count")row$denominator_refs<-list(.object(measure="person_count",metric_id="core.person.count",row_key=personKey,field="person_count",value=totals$person_count))
        row$row_key<-.v2_row_identity(assets$rows[[mid]],row);.store_put_row(tx,release,mid,row)
      })
    }
    .population_reconcile(tx,release,datasets,totals)
    ended<-.stamp();telemetry<-.object(request=plan$scope,producer_request=requested,source_schema=cdmSchema,observed_window=effective,totals=totals,started_at=started,ended_at=ended,
      definitions=plan$definitions,stages=stageTimings,peak_intermediate_bytes=format(peak,scientific=FALSE,trim=TRUE),
      resource_limits=.object(statement_timeout_ms=as.character(statementTimeoutMs),max_stage_bytes=format(maxStageBytes,scientific=FALSE,trim=TRUE)),reusable=FALSE)
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_operation VALUES (",.store_uuid(run),",'population_observation.generate',",lit(.hash(.json(plan$definitions))),",'succeeded','[]',",lit(.json(telemetry)),"::jsonb)"))
    tx$execute(paste0("UPDATE ",s,".achillesnext_analysis_run SET state='succeeded',finished_at=",lit(ended),"::timestamptz WHERE run_id=",.store_uuid(run)))
    tick();.object(release_id=release,run_id=run,profile_id=assets$profile$profile_id,profile_sha256=assets$hash,state="building",generated_metrics=as.list(ids),expected_metric_count="142",generated_metric_count="19",publishable=FALSE)
  },queryTimeoutSeconds=ceiling(statementTimeoutMs/1000)+1),error=function(e){if(inherits(e,"AchillesPopulationFailure"))stop(e);stop("Population/observation generation failed; transaction rolled back",call.=FALSE)})
}
