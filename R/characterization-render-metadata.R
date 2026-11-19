# Dataset states are data-derived SQL, not guessed from a declared CDM version.
.render_inventory <- function(output,person,raw,intervals,tables,unsupported) {
  ids<-setdiff(names(.v2_assets()$metrics),.core_metadata_ids())
  rows<-lapply(ids,function(mid) {
    domain<-strsplit(mid,".",fixed=TRUE)[[1]][2]
    personCount<-"p.person_count";reason<-unsupported[[mid]]
    if(mid%in%.domain_ids(TRUE)) {
      base<-if(domain=="density")personCount else "d.raw"
      state<-paste0("CASE WHEN ",base,"=0 THEN 'empty_source' ELSE 'computed' END")
      if(startsWith(mid,"observed."))state<-paste0("CASE WHEN ",base,"=0 THEN 'empty_source' WHEN d.observed=0 THEN 'empty_population' ELSE 'computed' END")
      if(endsWith(mid,".distinct_concepts_histogram"))state<-paste0("CASE WHEN ",personCount,">0 THEN 'computed' ELSE ",state," END")
    } else {
      base<-if(startsWith(mid,"core.person.")||mid%in%c("core.observation_period.person_interval_histogram","core.observation_period.total_days_histogram"))personCount else if(mid%in%c("core.observation_period.type_count","core.observation_period.integrity_count"))"p.raw_count" else "p.interval_count"
      state<-paste0("CASE WHEN ",base,"<>0 THEN 'computed' WHEN ",personCount,"=0",if(mid%in%c("core.observation_period.type_count","core.observation_period.integrity_count"))" OR TRUE" else ""," THEN 'empty_source' ELSE 'empty_population' END")
    }
    if(!is.null(reason))state<-"'unsupported'::text"
    paste0("SELECT ",.store_literal(mid),"::text AS metric_id,",state," AS state,",
      if(is.null(reason))"NULL::text" else .store_literal(reason)," AS conditional_reason,COALESCE(c.n,0)::text AS rows FROM totals p ",
      if(domain%in%names(tables))paste0("CROSS JOIN domain_totals d ") else "",
      "LEFT JOIN counts c ON c.metric_id=",.store_literal(mid),if(domain%in%names(tables))paste0(" WHERE d.domain=",.store_literal(domain)) else "")
  })
  stats<-paste(vapply(names(tables),function(d)paste0("SELECT ",.store_literal(d),"::text AS domain,COUNT(*) AS raw,COUNT(*) FILTER(WHERE observed) AS observed FROM ",tables[[d]]),""),collapse=" UNION ALL ")
  paste0("WITH totals AS MATERIALIZED (SELECT (SELECT COUNT(*) FROM ",person,") AS person_count,(SELECT COUNT(*) FROM ",raw,") AS raw_count,(SELECT COUNT(*) FROM ",intervals,") AS interval_count),domain_totals AS MATERIALIZED (",stats,"),counts AS (SELECT metric_id,COUNT(*) AS n FROM ",output," GROUP BY metric_id), states AS (",
    paste(unlist(rows),collapse=" UNION ALL "),") SELECT metric_id,state,CASE WHEN state='computed' THEN NULL WHEN state='unsupported' THEN conditional_reason WHEN state='empty_source' THEN 'source.empty' WHEN metric_id LIKE 'core.person.%' OR metric_id LIKE 'core.observation_period.%' THEN 'observation.no_valid_intervals' ELSE 'population.no_qualifying_events' END AS reason_code,rows,",
    "jsonb_build_object('state',CASE WHEN state='unsupported' THEN 'schema_absent' ELSE 'supported' END,'reason_code',conditional_reason) AS conditional_support,",
    "jsonb_build_object('scope_kind',CASE WHEN state='unsupported' THEN 'schema_conditional' ELSE 'standard_full' END,'complete',true,'excluded_record_count',CASE WHEN state='unsupported' THEN NULL ELSE '0' END,'reason_code',conditional_reason) AS completeness FROM states")
}
.render_metadata_queries <- function(batch,inventory,withInventory=FALSE) {
  assets<-.v2_assets();ids<-.core_metadata_ids();lit<-.store_literal
  facts<-"WITH facts AS (SELECT ?::jsonb AS v) "
  query<-function(mid,dimensions,values,from="facts")paste0(facts,"SELECT ",lit(mid),"::text AS metric_id,'metadata'::text AS row_kind,",dimensions," AS dimensions,",values," AS values FROM ",from)
  unknown<-"jsonb_build_object('state','unknown','value',NULL,'basis',NULL,'assertion_id',NULL,'reason_code','source.no_verified_release')"
  coverage<-"jsonb_build_object('scope_kind','standard_full','complete',true,'excluded_record_count','0','reason_code',NULL)"
  profile<-paste0(lit(.json(.object(id=assets$profile$profile_id,revision=assets$profile$revision,sha256=assets$hash))),"::jsonb")
  passport<-paste0("jsonb_build_object('source_id',",lit(batch$source$source_id),",'source_release',",unknown,",
    'declared_cdm_version',",lit(batch$source$declared_cdm_version),",'observed_schema',jsonb_build_object('sha256',v->'observed_schema_sha256','reason_code',NULL),",
    "'vocabulary_release',",unknown,",'profile',",profile,",'coverage',",coverage,",'generation',jsonb_build_object('started_at',v->'started_at','ended_at',v->'ended_at'),",
    "'consistency',jsonb_build_object('within_run','single_repeatable_read','reusable',false,'reason_code','source.no_verified_release'))")
  numericInventory<-paste0("inventory AS (",inventory,")")
  # Each metadata definition contributes one inventory row, even with no data.
  ledgerCount<-paste0("(SELECT (COUNT(*)+",length(ids),")::text FROM inventory)")
  metadataInventory<-vapply(ids,function(mid)paste0("SELECT ",lit(mid),"::text AS metric_id,'computed'::text AS state,NULL::text AS reason_code,",
    if(mid==ids[1])"'1'::text" else if(mid==ids[2])"(SELECT COUNT(*)::text FROM jsonb_object_keys(v->'capabilities'))" else if(mid==ids[3])ledgerCount else "jsonb_array_length(v->'timings')::text",
    " AS rows,jsonb_build_object('state','supported','reason_code',NULL) AS conditional_support,",coverage," AS completeness FROM facts"),"")
  fullInventory<-paste0("WITH facts AS (SELECT ?::jsonb AS v),",numericInventory,",complete_inventory AS (SELECT * FROM inventory UNION ALL ",paste(metadataInventory,collapse=" UNION ALL "),") ")
  if(withInventory)return(paste0(fullInventory,"SELECT * FROM complete_inventory"))
  ledger<-paste0(fullInventory,"SELECT ",lit(ids[3]),"::text AS metric_id,'metadata'::text AS row_kind,jsonb_build_object('metric_id',metric_id) AS dimensions,",
    "jsonb_build_object('state',state,'reason_code',reason_code,'required',true,'coverage',completeness,'integrity',jsonb_build_object('state','not_validated','sha256',NULL,'reason_code','validation.pending_receipt')) AS values FROM complete_inventory")
  timing<-paste0("jsonb_build_object('duration_ms',t->'duration_ms','telemetry',jsonb_build_object('cpu_ms',NULL,'peak_memory_bytes',NULL,'source_rows',NULL,'temp_bytes',NULL),",
    "'availability',CASE WHEN t->>'duration_ms' IS NULL THEN 'unavailable' ELSE 'measured' END,'reason_code',CASE WHEN t->>'duration_ms' IS NULL THEN 'execution.not_started_at_metadata_capture' END)")
  stats::setNames(list(query(ids[1],"'{}'::jsonb",passport),
    query(ids[2],"jsonb_build_object('probe_id',c.key)","c.value","facts CROSS JOIN LATERAL jsonb_each(v->'capabilities') c"),
    ledger,query(ids[4],"jsonb_build_object('operation_id',t->'operation_id','phase',t->'phase')",timing,"facts CROSS JOIN LATERAL jsonb_array_elements(v->'timings') t")),ids)
}
.render_numeric_query <- function(mid,output,inventory,careReason) {
  empty<-"o.row_kind='summary' AND o.values->>'n'='0'"
  values<-"o.values";state<-paste0("CASE WHEN ",empty," THEN 'empty_population' ELSE i.state END")
  reason<-paste0("CASE WHEN ",empty," THEN 'summary.no_eligible' ELSE i.reason_code END")
  if(mid=="core.visit.care_setting_count") {
    missing<-paste0("o.dimensions->>'setting_kind'='place_of_service' AND (",careReason,") IS NOT NULL")
    values<-paste0("CASE WHEN ",missing," THEN NULL::jsonb ELSE ",values," END")
    state<-paste0("CASE WHEN ",missing," THEN CASE WHEN (",careReason,")='capability.care_site_absent'",
      " THEN 'unsupported' ELSE 'unavailable' END ELSE ",state," END")
    reason<-paste0("CASE WHEN ",missing," THEN ",careReason," ELSE ",reason," END")
  }
  paste0("SELECT o.metric_id,o.row_kind,o.dimensions,",values," AS values,",state," AS state,",reason," AS reason_code FROM (SELECT * FROM ",
    output,") o JOIN ",inventory," i ON i.metric_id=o.metric_id WHERE o.metric_id=",.store_literal(mid))
}
