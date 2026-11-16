# Pure compilation only. Declarations never stand in for execution observations.
.render_columns <- function(columns) {
  .nv_need(is.data.frame(columns)&&nrow(columns)>0L&&nrow(columns)<=4096L&&
    setequal(names(columns),c("table","column","type","readable")),"Declare table, column, type and readable columns")
  for(k in c("table","column","type")) .nv_need(is.character(columns[[k]])&&
    all(!is.na(columns[[k]]))&&all(grepl("^[a-z][a-z0-9_]{0,62}$",columns[[k]])),"Invalid declared column identifier/type")
  .nv_need(is.logical(columns$readable)&&!anyNA(columns$readable),"Declare logical column readability")
  keys<-paste(columns$table,columns$column,sep=".");.nv_need(!anyDuplicated(keys),"Duplicate declared column")
  probes<-.render_probes();keep<-keys%in%probes
  columns<-columns[keep,c("table","column","type","readable"),drop=FALSE];keys<-keys[keep]
  order<-order(keys,method="radix");columns<-columns[order,,drop=FALSE];keys<-keys[order]
  metadata<-stats::setNames(lapply(seq_along(keys),function(i)as.list(columns[i,,drop=FALSE])),keys)
  column<-.domain_column_resolver(metadata);assets<-.v2_assets()
  population<-list(person=c("person_id","year_of_birth","gender_concept_id","race_concept_id","ethnicity_concept_id"),
    observation_period=c("person_id","observation_period_start_date","observation_period_end_date","period_type_concept_id"))
  for(table in names(population))for(name in population[[table]])column(paste(table,name,sep="."))
  needed<-unique(unlist(lapply(assets$metrics[.domain_ids(TRUE)],function(m)setdiff(unlist(m$inputs),unlist(m$conditional_inputs)))))
  needed<-setdiff(needed,c("care_site.care_site_id","care_site.place_of_service_concept_id"))
  for(probe in unique(c(needed,"concept.concept_id","concept.domain_id","measurement.person_id")))column(probe)
  conditional<-unique(unlist(lapply(assets$metrics[.domain_ids(TRUE)],function(m)unlist(m$conditional_inputs))))
  for(probe in setdiff(conditional,c("care_site.care_site_id","care_site.place_of_service_concept_id")))column(probe,FALSE)
  list(metadata=metadata,column=column,hash=.hash(.json(metadata)))
}
.render_probes <- function() sort(unique(c(.core_probes()[grepl("^[a-z_]+[.][a-z_]+$",.core_probes())],
  "concept.concept_id","concept.domain_id","visit_occurrence.admitting_source_concept_id",
  "visit_occurrence.discharge_to_concept_id")),method="radix")
.render_schema_guard <- function(schema,cap) {
  expected<-lapply(cap$metadata,function(m)m[c("type","readable")])
  paste0("SELECT (COALESCE(jsonb_object_agg(c.relname||'.'||a.attname,jsonb_build_object('type',t.typname,'readable',",
    "has_schema_privilege(n.oid,'USAGE') AND has_column_privilege(c.oid,a.attname,'SELECT'))),'{}'::jsonb)=",
    .store_literal(.json(expected)),"::jsonb)::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace ",
    "JOIN pg_attribute a ON a.attrelid=c.oid JOIN pg_type t ON t.oid=a.atttypid WHERE n.nspname=",.store_literal(schema),
    " AND c.relkind IN ('r','p','v','m','f') AND a.attnum>0 AND NOT a.attisdropped AND c.relname||'.'||a.attname IN (",
    paste(vapply(.render_probes(),.store_literal,""),collapse=","),")")
}
#' Render a complete PostgreSQL core characterization program without a connection
#' @param cdmSchema Source schema identifier.
#' @param sourceId Institution-controlled source identifier.
#' @param declaredCdmVersion Declared CDM version: 5.3, 5.4 or 5.5.
#' @param sourceColumns Data frame with table, column, type (PostgreSQL typname)
#'   and logical readable fields. A declaration, checked again at execution.
#' @param numericStrategy Exact weighted or reference measurement summaries.
#' @param dialect Currently only postgresql is implemented.
#' @param stagePrefix Session-private table prefix, starting with achillesnext_.
#' @return Ordered SQL steps, assertions, 142 restricted output queries and
#'   explicit runtime metadata parameter requirements. Does not execute or publish.
#' @export
renderCharacterizationSql <- function(cdmSchema,sourceId,declaredCdmVersion,sourceColumns,
  numericStrategy="weighted",dialect="postgresql",stagePrefix="achillesnext_render") {
  .nv_need(identical(dialect,"postgresql"),"Only the PostgreSQL renderer is implemented")
  .nv_need(.string(sourceId)&&nchar(enc2utf8(sourceId),type="bytes")<=256L,"Invalid render source identifier")
  .nv_need(.string(numericStrategy)&&numericStrategy%in%c("weighted","reference"),"Choose an exact measurement summary strategy")
  .nv_need(.batch_identifier(stagePrefix)&&startsWith(stagePrefix,"achillesnext_")&&nchar(stagePrefix)<=32L,"Invalid private stage prefix")
  batch<-planCharacterizationBatch(cdmSchema,sourceId,declaredCdmVersion,NULL,"shared")
  cap<-.render_columns(sourceColumns);assets<-.v2_assets();steps<-list();relations<-list()
  add<-function(id,kind,sql,expected=NULL,message=NULL) {
    .nv_need(!id%in%vapply(steps,function(x)x$id,""),"Duplicate SQL step")
    steps[[length(steps)+1L]]<<-.object(id=id,kind=kind,sql=sql,expected=expected,message=message)
  }
  guard<-function(id,sql,expected="0",message=id)add(id,"assert_scalar",sql,expected,message)
  stage<-function(id,sql,index=NULL) {
    name<-paste0(stagePrefix,"_",id);relation<-paste0('pg_temp."',name,'"');relations[[id]]<<-relation
    add(paste0(id,".create"),"execute",paste0('CREATE TEMP TABLE "',name,'" ON COMMIT DROP AS ',sql))
    if(!is.null(index))add(paste0(id,".index"),"execute",paste0("CREATE INDEX ON ",relation," (",index,")"))
    add(paste0(id,".analyze"),"execute",paste("ANALYZE",relation));relation
  }
  guard("session.isolation","SELECT (current_setting('transaction_isolation')='repeatable read')::text","true","Use one repeatable-read transaction")
  guard("engine.version","SELECT (current_setting('server_version_num')::integer>=120000)::text","true","PostgreSQL 12 or newer is required by the rendered CTE syntax")
  add("session.timezone","execute","SET LOCAL timezone='UTC'")
  add("session.datestyle","execute","SET LOCAL datestyle='ISO,YMD'")
  add("session.strings","execute","SET LOCAL standard_conforming_strings=on")
  guard("source.declaration",.render_schema_guard(cdmSchema,cap),"true","Source columns/types/readability differ from declaration")
  source<-paste0('"',cdmSchema,'"')
  tables<-unique(c("person","observation_period","concept",vapply(assets$profile$domains,function(d)d$table,"")))
  for(table in tables)guard(paste0("source.readonly.",table),paste0("SELECT (has_table_privilege(current_user,",
    .store_literal(paste0(source,'."',table,'"')),",'INSERT,UPDATE,DELETE,TRUNCATE') OR has_any_column_privilege(current_user,",
    .store_literal(paste0(source,'."',table,'"')),",'INSERT,UPDATE'))::text"),"false","Use SELECT-only source privileges")
  person<-stage("person",.population_source_sql("person",source),"person_id")
  guard("person.identity",paste0("SELECT (COUNT(*)-COUNT(person_id)+COUNT(person_id)-COUNT(DISTINCT person_id))::text FROM ",person),message="Null/duplicate PERSON identity")
  raw<-stage("raw",.population_source_sql("raw",source,person))
  guard("observation.endpoints",paste0("SELECT count(*)::text FROM ",raw," WHERE (start_date IS NOT NULL AND NOT(start_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31')) OR (end_date IS NOT NULL AND NOT(end_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31'))"),message="Observation endpoints outside finite Gregorian contract")
  intervals<-stage("union",.population_sql("union",list(raw=raw)),"person_id,start_date,end_date")
  people<-stage("people",.population_sql("people",list(person=person,intervals=intervals)))
  bound<-function(field,table)paste0("(SELECT ",if(field=="start")"MIN(start_date)" else "MAX(end_date)"," FROM ",table,")")
  calendar<-list(start=bound("start",intervals),end=bound("end",intervals))
  popPeriods<-stage("populationperiods",.population_sql("periods",calendar))
  guard("concept.domains",paste0("SELECT COUNT(*)::text FROM (SELECT concept_id FROM ",source,".concept GROUP BY concept_id HAVING COUNT(DISTINCT domain_id)>1 OR (COUNT(domain_id)>0 AND COUNT(domain_id)<COUNT(*))) x"),message="Ambiguous local concept domains")
  vocabulary<-stage("vocab",paste0("SELECT concept_id,MIN(domain_id) AS domain_id FROM ",source,".concept GROUP BY concept_id"),"concept_id")
  careMeta<-cap$metadata[c("care_site.care_site_id","care_site.place_of_service_concept_id")]
  careReason<-if(any(vapply(careMeta,is.null,TRUE)))"capability.care_site_absent" else if(!all(vapply(careMeta,function(m)isTRUE(m$readable),TRUE)))"capability.care_site_denied" else NULL
  care<-NULL;careAmbiguous<-"FALSE"
  if(is.null(careReason)) {
    .nv_need(all(vapply(careMeta,function(m)m$type%in%c("int2","int4","int8"),TRUE)),"Unsupported CARE_SITE type")
    guard("care.readonly",paste0("SELECT (has_table_privilege(current_user,",.store_literal(paste0(source,'.care_site')),
      ",'INSERT,UPDATE,DELETE,TRUNCATE') OR has_any_column_privilege(current_user,",.store_literal(paste0(source,'.care_site')),",'INSERT,UPDATE'))::text"),"false","Use SELECT-only CARE_SITE privileges")
    careAmbiguous<-paste0("EXISTS(SELECT 1 FROM ",source,".care_site WHERE care_site_id IS NOT NULL GROUP BY care_site_id HAVING COUNT(*)>1)")
    care<-stage("care",paste0("SELECT care_site_id,place_of_service_concept_id FROM ",source,".care_site WHERE NOT (",careAmbiguous,")"),"care_site_id")
  }
  careReasonSql<-if(is.null(careReason))paste0("CASE WHEN ",careAmbiguous," THEN 'capability.care_site_ambiguous'::text END") else paste0(.store_literal(careReason),"::text")
  domainTables<-list();unsupported<-list();aliases<-character()
  for(domain in .domain_names(TRUE)) {
    d<-assets$profile$domains[[domain]]
    column<-function(name,required=TRUE) {
      found<-cap$column(paste(d$table,name,sep="."),required);if(!length(found))return(NULL)
      expr<-paste0('e."',found,'"')
      if(length(expr)==1L)return(expr)
      id<-paste0("alias.",d$table,".",name)
      if(!id%in%aliases) {
        guard(id,paste0("SELECT count(*)::text FROM ",source,'."',d$table,'" e WHERE ',expr[1]," IS NOT NULL AND ",expr[2]," IS NOT NULL AND ",expr[1],"<>",expr[2]),message="Conflicting populated visit aliases")
        aliases<<-c(aliases,id)
      }
      paste0("COALESCE(",paste(expr,collapse=","),")")
    }
    built<-.domain_source_fields(domain,cap,vocabulary,care,column);fields<-built$fields;unsupported<-c(unsupported,built$unsupported)
    if(domain=="visit"&&!is.null(care))fields$care_tag<-paste0("CASE WHEN ",careAmbiguous," THEN jsonb_build_object('kind','schema_absent') ELSE ",fields$care_tag," END")
    rawDomain<-stage(paste0(domain,"raw"),paste0("SELECT ",paste(paste0(unlist(fields),' AS "',names(fields),'"'),collapse=",")," FROM ",source,'."',d$table,'" e'))
    domainTables[[domain]]<-stage(paste0(domain,"class"),.domain_classification_sql(domain,rawDomain,person,intervals,vocabulary),"person_id,event_date")
    add(paste0(domain,"raw.drop"),"execute",paste("DROP TABLE",rawDomain))
  }
  histories<-c(paste0("SELECT start_date AS d FROM ",intervals),paste0("SELECT end_date AS d FROM ",intervals),
    paste0("SELECT event_date AS d FROM ",unlist(domainTables)," WHERE valid_date"))
  history<-paste0("(",paste(histories,collapse=" UNION ALL "),") history")
  calendar<-list(start=paste0("(SELECT MIN(d) FROM ",history,")"),end=paste0("(SELECT MAX(d) FROM ",history,")"))
  periods<-stage("periods",.domain_periods_sql(calendar$start,calendar$end))
  tokens<-list(person=person,raw=raw,intervals=intervals,people=people,periods=popPeriods)
  populationSql<-paste0("SELECT * FROM (",.population_sql("demographics",tokens),") demographic UNION ALL SELECT * FROM (",.population_sql("observation",tokens),") observation")
  tokens$periods<-periods
  populationSql<-paste0(populationSql," UNION SELECT * FROM (",.population_sql("observation",tokens),") calendar WHERE metric_id IN ('core.observation_period.coverage_count','core.observation_period.continuous_person_count')")
  reports<-stage("population",populationSql,"metric_id")
  for(domain in .domain_names(TRUE))reports<-c(reports,stage(paste0(domain,"reports"),
    if(domain=="measurement").measurement_reports(domainTables[[domain]],person,periods,cap,numericStrategy) else .domain_reports(domain,domainTables[[domain]],person,periods,cap),"metric_id"))
  reports<-c(reports,stage("density",.domain_density(person,domainTables[.domain_names()],domainTables$measurement),"metric_id"))
  output<-paste0("(",paste(paste("SELECT * FROM",reports),collapse=" UNION ALL "),") output")
  inventoryRelation<-stage("inventory",.render_inventory(output,person,raw,intervals,domainTables,unsupported),"metric_id")
  inventory<-paste0("SELECT * FROM ",inventoryRelation)
  metadata<-.render_metadata_queries(batch,inventory)
  ids<-names(assets$metrics)
  queries<-stats::setNames(lapply(ids,function(mid).object(metric_id=mid,kind=if(mid%in%names(metadata))"runtime_metadata" else "aggregate",
    sql=metadata[[mid]] %||% .render_numeric_query(mid,output,inventoryRelation,careReasonSql),
    parameters=if(mid%in%names(metadata))list("runtime_facts") else list())),ids)
  program<-.object(format_version="1.0.0",kind="characterization_sql_program",dialect=dialect,batch=batch,
    declarations=.object(columns=cap$metadata,columns_sha256=cap$hash,numeric_strategy=numericStrategy,stage_prefix=stagePrefix),
    transaction=.object(isolation="repeatable_read",read_only=FALSE,minimum_server_version_num=120000L,temporary_tables="on_commit_drop",source_privileges="select_only",publication_changed=FALSE),
    execution=.object(state="not_executed",adapter_implemented=FALSE,source_accessed=FALSE,requires_assertions=TRUE,
      limits="Configure query timeout, stage bytes, aggregate row/byte and transfer limits in the executor; no limits enforced by rendering"),
    steps=steps,inventory_sql=.render_metadata_queries(batch,inventory,TRUE),inventory_parameters=list("runtime_facts"),outputs=queries,
    runtime_parameters=.object(runtime_facts=.object(sql_type="jsonb",fields=as.list(c("observed_schema_sha256","capabilities","started_at","ended_at","timings")),
      provenance="Actual execution observations, never filled by compilation; validate before binding metadata queries")),
    care_reason_sql=paste0("SELECT ",careReasonSql," AS reason_code"))
  program$program_sha256<-.hash(.json(program));program
}
