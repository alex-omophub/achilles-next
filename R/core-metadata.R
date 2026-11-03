# Metadata is assembled in the same source snapshot as the numeric reports.
.core_metadata_ids <- function() c("core.source.passport","core.source.capabilities","core.execution.output_status","core.execution.timing")
.core_probes <- function() sort(unique(unlist(lapply(.v2_assets()$metrics,function(m)
  c(unlist(m$inputs),unlist(m$conditional_inputs),unlist(m$input_aliases))))),method="radix")
.core_capabilities <- function(tx,schema) {
  probes<-.core_probes();physical<-probes[grepl("^[a-z_]+[.][a-z_]+$",probes)]
  tables<-sort(unique(c(sub("[.].*","",physical),"cdm_source","vocabulary")),method="radix")
  metadata<-list()
  tx$stream(paste0("SELECT jsonb_build_object('table',c.relname,'kind',c.relkind::text,'column',a.attname,'type',format_type(a.atttypid,a.atttypmod),",
    "'readable',has_schema_privilege(n.oid,'USAGE') AND has_column_privilege(c.oid,a.attname,'SELECT'))::text ",
    "FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid ",
    "WHERE n.nspname=",.store_literal(schema)," AND c.relkind IN ('r','p','v','m','f') AND a.attnum>0 AND NOT a.attisdropped ",
    "AND c.relname IN (",paste(vapply(tables,.store_literal,""),collapse=","),") ORDER BY c.relname COLLATE \"C\",a.attname COLLATE \"C\""),function(text) {
      m<-.store_decode(text);metadata[[paste(m$table,m$column,sep=".")]]<<-m
    })
  # One bounded existence read per readable relation, never COUNT(*) or patient
  # values. Choosing a readable column also supports column-level SELECT grants.
  empty<-list()
  for(table in tables) {
    columns<-Filter(function(m)m$table==table&&isTRUE(m$readable),metadata)
    if(length(columns)) {
      col<-columns[[1L]]$column
      quote<-function(x)paste0('"',gsub('"','""',x,fixed=TRUE),'"')
      empty[[table]]<-tx$one(paste0("SELECT (NOT EXISTS(SELECT ",quote(col)," FROM ",quote(schema),".",quote(table)," LIMIT 1))::text"))=="true"
    }
  }
  value<-function(state,type=NULL,reason=NULL).object(state=state,reason_code=reason,observed_type=type)
  capabilities<-stats::setNames(lapply(probes,function(probe) {
    if(probe%in%c("capability_probes","schema_metadata"))return(value("available","pg_catalog"))
    if(probe=="operator_assertions")return(value("absent",reason="source.no_operator_assertions"))
    if(probe%in%c("cdm_source","vocabulary")) {
      cols<-Filter(function(m)m$table==probe,metadata)
      if(!length(cols))return(value("absent",reason="capability.table_absent"))
      if(is.null(empty[[probe]]))return(value("inaccessible","relation","capability.select_denied"))
      return(value(if(empty[[probe]])"available_empty" else "available","relation"))
    }
    m<-metadata[[probe]]
    if(is.null(m))return(value("absent",reason="capability.column_absent"))
    if(!isTRUE(m$readable))return(value("inaccessible",m$type,"capability.select_denied"))
    value(if(isTRUE(empty[[m$table]]))"available_empty" else "available",m$type)
  }),probes)
  list(values=capabilities,schema_sha256=.v2_hash(.v2_bytes(metadata)))
}
.core_timing <- function(stages,duration) {
  telemetry<-.object(cpu_ms=NULL,peak_memory_bytes=NULL,source_rows=NULL,temp_bytes=NULL)
  row<-function(id,phase,ms=NULL).object(dimensions=.object(operation_id=id,phase=phase),
    values=.object(duration_ms=ms,telemetry=telemetry,availability=if(is.null(ms))"unavailable" else "measured",
      reason_code=if(is.null(ms))"execution.not_started_at_metadata_capture" else NULL))
  c(list(row("core.numeric_generation","generation",duration)),
    lapply(names(stages),function(id)row(paste0("stage.",id),"materialization",stages[[id]]$duration_ms)),
    lapply(c("validation","projection","export","publication"),function(phase)row(paste0("core.",phase),phase)))
}
.core_write_metadata <- function(tx,release,sourceId,version,schemaHash,capabilities,datasets,started,ended,timings,maxRows,numericRows,check) {
  # The caller supplies a lazy timing expression. Capture it before any metadata
  # assembly or writer flush so numeric-generation timing excludes all four outputs.
  force(timings)
  assets<-.v2_assets();ids<-.core_metadata_ids();writer<-.store_writer(tx,release)
  counts<-stats::setNames(rep(0L,length(ids)),ids)
  put<-function(mid,dimensions,values) {
    check();.population_need(numericRows+sum(counts)<maxRows,"Aggregate row budget exceeded; generation rolled back")
    row<-.object(row_key="",dimensions=dimensions,row_kind="metadata",state="computed",reason_code=NULL,values=values,denominator_refs=list())
    row$row_key<-.v2_row_identity(assets$rows[[mid]],row);writer$add(mid,row);counts[[mid]]<<-counts[[mid]]+1L
  }
  unknown<-.object(state="unknown",value=NULL,basis=NULL,assertion_id=NULL,reason_code="source.no_verified_release")
  coverage<-.object(scope_kind="standard_full",complete=TRUE,excluded_record_count="0",reason_code=NULL)
  passport<-.object(source_id=sourceId,source_release=unknown,declared_cdm_version=version,
    observed_schema=.object(sha256=schemaHash,reason_code=NULL),vocabulary_release=unknown,
    profile=.object(id=assets$profile$profile_id,revision=assets$profile$revision,sha256=assets$hash),coverage=coverage,
    generation=.object(started_at=started,ended_at=ended),consistency=.object(within_run="single_repeatable_read",reusable=FALSE,reason_code="source.no_verified_release"))
  put(ids[1],.object(),passport)
  for(probe in names(capabilities))put(ids[2],.object(probe_id=probe),capabilities[[probe]])
  for(mid in names(datasets)) {
    d<-datasets[[mid]]
    put(ids[3],.object(metric_id=mid),.object(state=d$state,reason_code=d$reason_code,required=d$required,coverage=d$completeness,
      integrity=.object(state="not_validated",sha256=NULL,reason_code="validation.pending_receipt")))
  }
  for(timing in timings)put(ids[4],timing$dimensions,timing$values)
  persistence<-writer$finish()
  for(mid in ids).population_need(as.character(counts[[mid]])==datasets[[mid]]$rows,"Metadata row count mismatch")
  .v2_capability_check(datasets,capabilities)
  list(persistence=persistence,rows=sum(counts))
}

#' Generate a complete restricted core characterization candidate
#' @inheritParams generateMeasurementBaseline
#' @return A building candidate containing all 142 frozen outputs. It is not
#'   approved or current; seal, natively validate and approve it separately.
#' @details Uses one PostgreSQL repeatable-read transaction for numeric reports
#'   and metadata. Unknown source/vocabulary identities never authorize reuse.
#'   This generator does not execute a refresh plan or publish automatically.
#' @export
generateCharacterizationCandidate <- function(connectionDetails,cdmSchema,sourceId,resultsSchema,declaredCdmVersion,
  maxStageBytes=64*1024^2,check=NULL,statementTimeoutMs=30000L,numericStrategy="weighted",maxAggregateRows=1000000L) {
  .nv_need(.string(numericStrategy)&&numericStrategy%in%c("weighted","reference"),"Choose an exact measurement summary strategy")
  .nv_need(is.numeric(maxAggregateRows)&&length(maxAggregateRows)==1L&&is.finite(maxAggregateRows)&&maxAggregateRows>=1&&
    maxAggregateRows<=1000000&&maxAggregateRows==floor(maxAggregateRows),"Invalid aggregate row budget")
  .baseline_generate(connectionDetails,cdmSchema,sourceId,resultsSchema,declaredCdmVersion,NULL,maxStageBytes,check,
    statementTimeoutMs,TRUE,TRUE,numericStrategy,maxAggregateRows=as.integer(maxAggregateRows),coreMode=TRUE)
}
