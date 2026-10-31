# JDBC strings preserve NUMERIC exactly. Each cursor fetch is bounded; it never
# uses DatabaseConnector's data-frame conversion for aggregate values.
.store_commit <- function(jdbc) rJava::.jcall(jdbc, "V", "commit")
.store_transaction <- function(details, schema, work, readOnly = FALSE, isolation = 4L) {
  .nv_need(identical(details$dbms, "postgresql"), "PostgreSQL is required")
  .nv_need(.string(schema) && grepl("^[a-z][a-z0-9_]{0,62}$", schema) && !grepl("^pg_|^public$|^information_schema$", schema), "Invalid results schema")
  connection <- DatabaseConnector::connect(details)
  on.exit(DatabaseConnector::disconnect(connection), add = TRUE)
  jdbc <- connection@jConnection
  rJava::.jcall(jdbc, "V", "setAutoCommit", FALSE)
  rJava::.jcall(jdbc, "V", "setReadOnly", readOnly)
  rJava::.jcall(jdbc, "V", "setTransactionIsolation", isolation)
  committed <- FALSE
  on.exit(if (!committed) try(rJava::.jcall(jdbc, "V", "rollback"), silent = TRUE), add = TRUE, after = FALSE)
  execute <- function(sql) {
    statement <- rJava::.jcall(jdbc, "Ljava/sql/Statement;", "createStatement")
    on.exit(rJava::.jcall(statement, "V", "close"))
    rJava::.jcall(statement, "V", "setQueryTimeout", 60L)
    invisible(rJava::.jcall(statement, "Z", "execute", sql))
  }
  stream <- function(sql, visit) {
    statement <- rJava::.jcall(jdbc, "Ljava/sql/Statement;", "createStatement")
    on.exit(rJava::.jcall(statement, "V", "close"))
    rJava::.jcall(statement, "V", "setFetchSize", 128L)
    rJava::.jcall(statement, "V", "setQueryTimeout", 60L)
    rs <- rJava::.jcall(statement, "Ljava/sql/ResultSet;", "executeQuery", sql)
    on.exit(rJava::.jcall(rs, "V", "close"), add = TRUE, after = FALSE)
    while (rJava::.jcall(rs, "Z", "next")) visit(rJava::.jcall(rs, "S", "getString", 1L))
    invisible(NULL)
  }
  one <- function(sql) {
    rows <- list(); stream(sql, function(x) { .nv_need(length(rows) < 1L, "Expected one store row"); rows[[length(rows)+1L]] <<- x })
    .nv_need(length(rows) == 1L, "Missing store row"); rows[[1]]
  }
  result <- work(list(schema = paste0('"', schema, '"'), execute = execute, stream = stream, one = one))
  .store_commit(jdbc); committed <- TRUE; result
}
.store_literal <- function(x) paste0("'", gsub("'", "''", x, fixed = TRUE), "'")
.store_uuid <- function(x) {
  .nv_need(.string(x) && grepl("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", x), "A lowercase UUID is required")
  .store_literal(x)
}
.store_new_uuid <- function() {
  h <- paste(sample(c(0:9, letters[1:6]), 32L, replace = TRUE), collapse = "")
  paste(substr(h,1,8),substr(h,9,12),paste0("4",substr(h,14,16)),paste0("8",substr(h,18,20)),substr(h,21,32),sep="-")
}
.store_decode <- function(x) .nv_json(charToRaw(enc2utf8(x)))
.store_context <- function(tx, releaseId) {
  id <- .store_uuid(releaseId); s <- tx$schema
  .store_decode(tx$one(paste0("SELECT jsonb_build_object('release_id',r.release_id::text,'run_id',a.run_id::text,",
    "'state',r.state,'content_revision',r.content_revision::text,'source_id',s.source_id,'observed_schema_sha256',s.observed_schema_sha256,'declared_cdm_version',s.declared_cdm_version,",
    "'source_release_id',s.source_release_id::text,'profile_id',a.profile_id,'profile_revision',a.profile_revision,",
    "'profile_sha256',a.profile_sha256,'run_state',a.state,'consistency_basis',a.consistency_basis)::text FROM ",
    s,".result_release r JOIN ",s,".analysis_run a USING(run_id) JOIN ",s,".source_release s USING(source_release_id) WHERE r.release_id=",id," FOR SHARE OF r")))
}
.v2_dataset <- function(d) {
  m <- .v2_assets()$metrics[[d$metric_id]]; registry <- .v2_assets()$rows[[d$metric_id]]
  .nv_need(!is.null(m), "Unknown dataset")
  .v2_keys(d, c("metric_id", "version", "population", "grain", "row_schema_id", "definition_sha256", "state", "reason_code", "required", "conditional_support", "rows", "completeness"))
  .nv_need(identical(d$version, m$version) && identical(d$population, m$population) && identical(d$grain, m$grain) && identical(d$row_schema_id, registry$row_schema_id))
  .nv_need(identical(d$definition_sha256, .v2_hash(.v2_bytes(m))), "Metric definition hash mismatch")
  .nv_need(isTRUE(d$required) && .v2_count(d$rows))
  .nv_need(d$state %in% c("computed", "empty_source", "empty_population", "suppressed", "unsupported"), "Incomplete dataset")
  .nv_need(d$state!="unsupported" || d$metric_id!="core.device.quantity_summary","Quantity is required even when unit columns are absent")
  .nv_need(if (d$state == "computed") is.null(d$reason_code) else .string(d$reason_code) && grepl("^[a-z0-9_.:-]{1,96}$", d$reason_code))
  .v2_keys(d$conditional_support, c("state", "reason_code"))
  .nv_need(d$conditional_support$state %in% c("supported", "schema_absent"))
  if (d$state == "unsupported" || (d$state=="suppressed" && d$conditional_support$state=="schema_absent")) .nv_need(m$availability != "required_when_table_readable" && d$conditional_support$state == "schema_absent" && .string(d$conditional_support$reason_code) && d$rows == "0") else
    .nv_need(d$conditional_support$state == "supported" && is.null(d$conditional_support$reason_code))
  schema <- .v2_assets()$metadata
  .nv_schema(d$completeness, schema$`$defs`$coverage, schema)
  .nv_need(isTRUE(d$completeness$complete) && d$completeness$scope_kind %in% c("standard_full", "schema_conditional"))
  .nv_need(identical(d$completeness$excluded_record_count, "0") ||
    (d$conditional_support$state=="schema_absent" && d$completeness$scope_kind=="schema_conditional" &&
      is.null(d$completeness$excluded_record_count) && .string(d$completeness$reason_code)), "Incomplete full-profile coverage")
  invisible(TRUE)
}
.store_datasets <- function(tx, releaseId) {
  result <- list(); s <- tx$schema
  tx$stream(paste0("SELECT jsonb_build_object('metric_id',metric_id,'version',metric_version,'population',population_id,",
    "'grain',grain_id,'row_schema_id',row_schema_id,'definition_sha256',definition_sha256,'state',state,'reason_code',reason_code,",
    "'required',required,'conditional_support',conditional_support,'rows',row_count::text,'completeness',completeness)::text FROM ",s,
    ".dataset WHERE release_id=",.store_uuid(releaseId)," ORDER BY metric_id COLLATE \"C\""), function(x) {
      .nv_need(nchar(x,type="bytes") <= 65536L && length(result) < 142L)
      d <- .store_decode(x); .v2_dataset(d); result[[d$metric_id]] <<- d
    })
  .nv_need(setequal(names(result), names(.v2_assets()$metrics)), "Incomplete metric inventory"); result
}
.store_rows <- function(tx, releaseId, metricId, visit) {
  # Exact values cast to text at the server; scale normalization below never
  # passes through floating point. A correlated edge lookup is index bounded.
  s <- tx$schema; numeric <- c(record_count="record_count",person_count="person_count",person_days="person_days",interval_count="interval_count",n="n",sum="sum_value",min="minimum",max="maximum",p10="p10",p25="p25",p50="p50",p75="p75",p90="p90")
  fields <- paste(vapply(names(numeric), function(k) paste0(.store_literal(k),",c.",numeric[[k]],"::text"),""), collapse=",")
  sql <- paste0("SELECT jsonb_build_object('row_key',c.row_key,'dimensions',c.dimensions,'state',c.state,'reason_code',c.reason_code,",
    "'payload_kind',c.payload_kind,'route_key',c.route_key,'sort_key',c.sort_key,'metadata',c.metadata_value,'numeric',jsonb_build_object(",fields,"),",
    "'denominator_refs',COALESCE((SELECT jsonb_agg(jsonb_build_object('measure',e.measure_key,'metric_id',e.target_metric_id,'row_key',e.target_row_key,'field',e.target_measure_key,",
    "'value',CASE e.target_measure_key WHEN 'record_count' THEN t.record_count::text WHEN 'person_count' THEN t.person_count::text WHEN 'person_days' THEN t.person_days::text WHEN 'interval_count' THEN t.interval_count::text WHEN 'n' THEN t.n::text END) ORDER BY e.measure_key) FROM ",s,".denominator_edge e JOIN ",s,".aggregate_cell t ON (t.release_id,t.metric_id,t.row_key)=(e.release_id,e.target_metric_id,e.target_row_key) WHERE (e.release_id,e.metric_id,e.row_key)=(c.release_id,c.metric_id,c.row_key)), '[]'::jsonb))::text FROM ",s,".aggregate_cell c WHERE c.release_id=",.store_uuid(releaseId)," AND c.metric_id=",.store_literal(metricId)," ORDER BY c.route_key COLLATE \"C\",c.sort_key COLLATE \"C\"")
  sql <- paste0("SELECT CASE WHEN octet_length(doc)<=131072 THEN doc ELSE NULL END FROM (",sub("::text FROM", "::text AS doc FROM",sql,fixed=TRUE),") bounded")
  tx$stream(sql,function(text) {
    .nv_need(.string(text) && nchar(text,type="bytes") <= 131072L, "Stored row resource limit")
    c <- .store_decode(text); registry <- .v2_assets()$rows[[metricId]]
    kind <- if(c$payload_kind=="counts" && "eligibility_reason" %in% names(c$dimensions)) "eligibility_counts" else c$payload_kind
    keys <- unlist(registry$value_keys_by_row_kind[[kind]])
    .nv_need(length(keys)>0L, "Unknown payload kind")
    values <- if(c$state%in%c("suppressed","unsupported","unavailable")) NULL else if(kind=="metadata") c$metadata else {
      numeric <- c$numeric
      normalize <- function(x) if(is.null(x)) NULL else if(grepl(".",x,fixed=TRUE)) {
        x <- sub("0+$","",x);x <- sub("[.]$","",x);if(x=="-0") "0" else x
      } else x
      numeric <- lapply(numeric,normalize)
      numeric["mean_numerator"] <- list(numeric$sum);numeric["mean_denominator"] <- list(if(identical(numeric$n,"0"))NULL else numeric$n)
      .nv_need(all(vapply(numeric[setdiff(names(numeric),c(keys,"mean_numerator","mean_denominator"))],is.null,TRUE)),"Unexpected stored value")
      numeric[keys]
    }
    row <- .object(row_key=c$row_key,dimensions=c$dimensions,row_kind=kind,state=c$state,reason_code=c$reason_code,values=values,denominator_refs=c$denominator_refs)
    sort <- .v2_row(metricId,row)
    .nv_need(identical(sort,c$sort_key),"Stored sort key mismatch")
    .nv_need(identical(c$route_key,"A"),"This exporter requires the registered ALL route")
    visit(row,sort)
  })
}
.store_validate <- function(tx, releaseId) {
  context <- .store_context(tx,releaseId); assets <- .v2_assets()
  .nv_need(context$state %in% c("sealed","validated") && context$run_state=="succeeded", "A sealed successful release is required")
  .nv_need(context$profile_id==assets$profile$profile_id && context$profile_revision==assets$profile$revision && context$profile_sha256==assets$hash, "Unregistered runtime profile")
  s <- tx$schema; id <- .store_uuid(releaseId)
  .nv_need(tx$one(paste0("SELECT count(*)::text FROM ",s,".operation WHERE run_id=",.store_uuid(context$run_id)," AND state NOT IN ('succeeded','skipped')"))=="0","Incomplete operations")
  datasets <- .store_datasets(tx,releaseId)
  # Every edge must resolve to an unsuppressed exact measure. Source/target
  # dimensions and declared population are checked below, independently of FK.
  .nv_need(tx$one(paste0("SELECT count(*)::text FROM ",s,".denominator_edge e JOIN ",s,".aggregate_cell c ON (c.release_id,c.metric_id,c.row_key)=(e.release_id,e.metric_id,e.row_key) JOIN ",s,".aggregate_cell t ON (t.release_id,t.metric_id,t.row_key)=(e.release_id,e.target_metric_id,e.target_row_key) WHERE e.release_id=",id," AND (c.state='suppressed' OR t.state='suppressed')"))=="0","Suppressed denominator endpoint")
  capabilities <- list()
  for(mid in names(datasets)) {
    count <- "0"; last <- NULL; d <- datasets[[mid]]
    .store_rows(tx,releaseId,mid,function(row,key) {
      .nv_need(is.null(last) || .v2_less(last,key),"Duplicate or unordered row")
      last <<- key; count <<- .nv_add(count,"1")
      if(d$state=="suppressed") .nv_need(row$state=="suppressed")
      if(d$state %in% c("empty_source","empty_population")) .nv_need(row$state %in% c(d$state,"suppressed"))
      .store_denominators(tx,releaseId,mid,row)
      if(mid=="core.source.capabilities" && row$state!="suppressed") capabilities[[row$dimensions$probe_id]] <<- row$values
      if(mid=="core.execution.output_status" && row$state!="suppressed") {
        target <- datasets[[row$dimensions$metric_id]]
        .nv_need(row$values$state==target$state && identical(row$values$reason_code,target$reason_code) && identical(row$values$required,target$required),"Output ledger mismatch")
      }
      if(mid=="core.source.passport" && row$state!="suppressed") {
        .nv_need(row$values$source_id==context$source_id && row$values$profile$id==context$profile_id && row$values$profile$revision==context$profile_revision && row$values$profile$sha256==context$profile_sha256 && row$values$observed_schema$sha256==context$observed_schema_sha256 && row$values$declared_cdm_version==context$declared_cdm_version && row$values$consistency$within_run==context$consistency_basis,"Passport context mismatch")
      }
    })
    .nv_need(count==d$rows,"Dataset row count mismatch")
    if(mid=="core.execution.output_status" && d$state!="suppressed") .nv_need(count=="142","Missing output ledger rows")
    if(mid %in% c("core.person.count","core.source.passport") && d$state!="suppressed") .nv_need(count=="1","Missing singleton")
  }
  .v2_capability_check(datasets,capabilities)
  .store_summary_checks(tx,releaseId,datasets)
  .store_domain_reconcile(tx,releaseId,datasets)
  .store_reconcile(tx,releaseId)
  list(context=context,datasets=datasets)
}
# ASCII keys only; comparison must not inherit the user's locale.
.v2_less <- function(a,b) !identical(a,b) && identical(order(c(a,b),method="radix"),c(1L,2L))
.v2_denominator_check <- function(mid, row, lookup) {
  m <- .v2_assets()$metrics[[mid]];dims <- row$dimensions
  target <- NULL;targetDims <- .object();measures <- "person_count";partial <- FALSE
  if(!is.null(m$denominator) && row$state!="suppressed" && row$row_kind=="counts") {
    target <- strsplit(m$denominator," ",fixed=TRUE)[[1]][1]
    if(grepl("for full-scope",m$denominator,fixed=TRUE) && !identical(dims$period_kind,"full_scope")) target <- NULL
    if(grepl("same period",m$denominator,fixed=TRUE)) targetDims <- dims[c("period_kind","period_start","period_end")]
    if(grepl("same year/gender/age",m$denominator,fixed=TRUE)) targetDims <- dims[c("year","gender_concept_id","year_age_decile")]
    if(grepl("in full scope",m$denominator,fixed=TRUE)) {
      targetDims <- c(dims["concept_tag"],.object(period_kind="full_scope"));partial <- TRUE
      measures <- c("record_count","person_count")
    }
  }
  if(is.null(target)) measures <- character()
  .nv_need(length(row$denominator_refs)==length(measures),"Missing or unexpected denominator")
  seen <- character()
  for(ref in row$denominator_refs) {
    .nv_need(ref$metric_id==target && ref$measure%in%measures && ref$field==ref$measure && !ref$measure%in%seen,"Wrong denominator population")
    seen <- c(seen,ref$measure)
    targetDimensions <- lookup(ref$metric_id,ref$row_key)
    .nv_need(identical(.json(if(partial)targetDimensions[names(targetDims)] else targetDimensions),.json(targetDims)),"Wrong denominator dimensions")
    .nv_need(.nv_unsigned_cmp(row$values[[ref$measure]],ref$value)<=0,"Numerator exceeds denominator")
  }
  invisible(TRUE)
}
.store_denominators <- function(tx,releaseId,mid,row) {
  .v2_denominator_check(mid,row,function(id,key) .store_decode(tx$one(paste0("SELECT dimensions::text FROM ",tx$schema,".aggregate_cell WHERE release_id=",.store_uuid(releaseId)," AND metric_id=",.store_literal(id)," AND row_key=",.store_literal(key)))))
}
.store_reconcile <- function(tx, releaseId) {
  # Additive PERSON partitions are checked in NUMERIC on the database; these
  # checks cannot round large counts through an R/Java floating-point adapter.
  s <- tx$schema; id <- .store_uuid(releaseId)
  for(mid in c("core.person.gender_count","core.person.birth_year_count","core.person.race_count","core.person.ethnicity_count","core.person.birth_year_gender_count","core.person.race_ethnicity_count","core.density.domain_count","core.density.domain_presence_count")) {
    .nv_need(tx$one(paste0("SELECT CASE WHEN EXISTS(SELECT 1 FROM ",s,".dataset WHERE release_id=",id," AND metric_id IN (",.store_literal(mid),",'core.person.count') AND state='suppressed') THEN 'ok' WHEN (SELECT COALESCE(sum(person_count),0) FROM ",s,".aggregate_cell WHERE release_id=",id," AND metric_id=",.store_literal(mid),")=(SELECT person_count FROM ",s,".aggregate_cell WHERE release_id=",id," AND metric_id='core.person.count') THEN 'ok' ELSE 'invalid' END"))=="ok","PERSON partition does not reconcile")
  }
}
#' Validate a sealed aggregate release using native R
#' @inheritParams initializeResultStore
#' @param releaseId UUID of a sealed release using the shipped core profile.
#' @export
validateResultRelease <- function(connectionDetails, resultsSchema, releaseId) {
  tryCatch(.store_transaction(connectionDetails,resultsSchema,function(tx) {
    validated <- .store_validate(tx,releaseId); c <- validated$context
    if(c$state=="validated") return(invisible(c))
    receipt <- .store_new_uuid()
    report <- .v2_hash(.v2_bytes(.object(release_id=releaseId,content_revision=c$content_revision,profile_sha256=c$profile_sha256,validator_version="native-2.0.0",passed=TRUE)))
    tx$execute(paste0("INSERT INTO ",tx$schema,".validation_receipt VALUES (",.store_uuid(receipt),",",.store_uuid(releaseId),",",c$content_revision,",'native-2.0.0',",.store_literal(c$profile_sha256),",true,now(),",.store_literal(report),"); UPDATE ",tx$schema,".result_release SET state='validated' WHERE release_id=",.store_uuid(releaseId)))
    invisible(c)
  }),error=function(e) stop("Aggregate release validation failed",call.=FALSE))
}

.store_summary_checks <- function(tx,releaseId,datasets) {
  s <- tx$schema;rid <- .store_uuid(releaseId)
  for(mid in names(datasets)) {
    if(!"summary"%in%names(.v2_assets()$rows[[mid]]$value_keys_by_row_kind) || datasets[[mid]]$state%in%c("suppressed","unsupported")) next
    # Each exact summary binds its included n to the eligible category under
    # precisely the same declared dimensions, including unit/operator strata.
    where <- paste0(" release_id=",rid," AND metric_id=",.store_literal(mid))
    invalid <- tx$one(paste0("SELECT count(*)::text FROM ",s,".aggregate_cell a WHERE a.",trimws(where)," AND a.payload_kind='summary' AND a.state<>'suppressed' AND NOT EXISTS (SELECT 1 FROM ",s,".aggregate_cell e WHERE (e.release_id,e.metric_id)=(a.release_id,a.metric_id) AND e.payload_kind='counts' AND e.state<>'suppressed' AND e.dimensions-'eligibility_reason'=a.dimensions AND e.dimensions->>'eligibility_reason'='eligible' AND COALESCE(e.record_count,e.person_count)=a.n)"))
    .nv_need(invalid=="0","Summary eligibility does not reconcile")
  }
}

.store_domain_reconcile <- function(tx,releaseId,datasets) {
  s <- tx$schema;rid <- .store_uuid(releaseId)
  available <- function(mid) !is.null(datasets[[mid]]) && !datasets[[mid]]$state%in%c("suppressed","unsupported")
  for(domain in c("condition","drug","procedure","visit","device","observation","death","specimen","measurement")) {
    capture <- paste0("core.",domain,".capture_count")
    if(!available(capture)) next
    for(suffix in c("source_count","type_count","representation_count","unit_count","coded_value_count","operator_count","numeric_eligibility_count","observation_qualification_count","range_status_count","status_type_count")) {
      mid <- paste0("core.",domain,".",suffix);if(!available(mid)) next
      # Suppressed facts cannot be used to manufacture a reconciliation. The
      # approved projection may suppress whole outputs; it never recomputes them.
      skipped <- tx$one(paste0("SELECT count(*)::text FROM ",s,".aggregate_cell WHERE release_id=",rid," AND metric_id IN (",.store_literal(mid),",",.store_literal(capture),") AND state='suppressed'"))!="0"
      if(skipped) next
      txcheck <- tx$one(paste0("WITH parts AS (SELECT dimensions->'concept_tag' AS tag,sum(record_count) AS n FROM ",s,".aggregate_cell WHERE release_id=",rid," AND metric_id=",.store_literal(mid)," GROUP BY 1), totals AS (SELECT dimensions->'concept_tag' AS tag,sum(record_count) AS n,count(*) AS cells FROM ",s,".aggregate_cell WHERE release_id=",rid," AND metric_id=",.store_literal(capture)," AND dimensions->>'period_kind'='full_scope' GROUP BY 1) SELECT count(*)::text FROM parts p FULL JOIN totals t USING(tag) WHERE p.n IS DISTINCT FROM t.n OR t.cells<>1"))
      .nv_need(txcheck=="0","Domain record partitions do not reconcile")
    }
    observed <- paste0("observed.",domain,".capture_count")
    if(available(observed)) {
      bad <- tx$one(paste0("SELECT count(*)::text FROM ",s,".aggregate_cell a LEFT JOIN ",s,".aggregate_cell b ON b.release_id=a.release_id AND b.metric_id=",.store_literal(capture)," AND b.dimensions=a.dimensions WHERE a.release_id=",rid," AND a.metric_id=",.store_literal(observed)," AND a.state<>'suppressed' AND (b.row_key IS NULL OR (b.state<>'suppressed' AND (a.record_count>b.record_count OR a.person_count>b.person_count)))"))
      .nv_need(bad=="0","Observed counts exceed matching all-recorded counts")
    }
  }
}

.v2_capability_check <- function(datasets,capabilities) {
  if(datasets[["core.source.capabilities"]]$state=="suppressed")return(invisible(TRUE))
  metrics <- .v2_assets()$metrics
  probes <- unique(unlist(lapply(metrics,function(m)c(unlist(m$inputs),unlist(m$conditional_inputs),unlist(m$input_aliases)))))
  .nv_need(setequal(names(capabilities),probes),"Incomplete capability inventory")
  for(mid in names(datasets)) {
    m <- metrics[[mid]]
    if(datasets[[mid]]$state=="suppressed")next
    physical <- Filter(function(x)grepl("^[a-z_]+[.][a-z_]+$",x),setdiff(unlist(m$inputs),unlist(m$conditional_inputs)))
    for(probe in physical) {
      alternatives <- unique(c(probe,unlist(m$input_aliases[[probe]])))
      .nv_need(any(vapply(alternatives,function(p)capabilities[[p]]$state%in%c("available","available_empty"),TRUE)),"Required input is not readable")
    }
  }
  invisible(TRUE)
}
