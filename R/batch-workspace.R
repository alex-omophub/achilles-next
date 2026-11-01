# Internal execution substrate: one owned JDBC transaction, session-private
# temporary tables only. No durable staging reuse or result publication API.
.batch_plan_stats <- function(doc,sourceSchema) {
  nodes<-list()
  walk<-function(n) {nodes[[length(nodes)+1L]]<<-n;for(child in n$Plans %||% list()) walk(child)}
  walk(doc$Plan)
  source<-Filter(function(n)identical(n$Schema,sourceSchema) && .string(n$`Relation Name`),nodes)
  list(source_scan_nodes=length(source),source_scan_rows=sum(vapply(source,function(n)(n$`Actual Rows` %||% 0)*(n$`Actual Loops` %||% 0),0)),
    source_scan_relations=as.list(unique(vapply(source,function(n)n$`Relation Name`,""))),
    shared_read_blocks=doc$Plan$`Shared Read Blocks` %||% NULL,shared_hit_blocks=doc$Plan$`Shared Hit Blocks` %||% NULL,
    temp_read_blocks=doc$Plan$`Temp Read Blocks` %||% NULL,temp_written_blocks=doc$Plan$`Temp Written Blocks` %||% NULL,
    execution_ms=doc$`Execution Time` %||% NULL,source_bytes=NULL,source_bytes_reason="EXPLAIN does not expose physical source row bytes; block counters are I/O operations, not unique bytes")
}
.batch_with_workspace <- function(connectionDetails,plan,work,maxStageBytes=64*1024^2,statementTimeoutMs=30000L,analyze=FALSE,check=NULL) {
  .batch_check_plan(plan)
  if(!inherits(connectionDetails,"ConnectionDetails") || !identical(connectionDetails$dbms,"postgresql") || !is.function(work) ||
    !is.numeric(maxStageBytes) || length(maxStageBytes)!=1L || !is.finite(maxStageBytes) || maxStageBytes<0 ||
    !is.numeric(statementTimeoutMs) || length(statementTimeoutMs)!=1L || !is.finite(statementTimeoutMs) || statementTimeoutMs<1 || statementTimeoutMs>2147483647 ||
    statementTimeoutMs!=floor(statementTimeoutMs) || !is.logical(analyze) || length(analyze)!=1L || is.na(analyze) || (!is.null(check) && !is.function(check))) stop("Invalid batch workspace configuration",call.=FALSE)
  if(!is.null(check)) check()
  connection<-DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection),add=TRUE)
  statements<-list()
  observer<-function(record) {statements[[length(statements)+1L]]<<-record;invisible(NULL)}
  # Reuse JDBC string transport, explicitly switching this dedicated worker to
  # writable before its first statement. Source safety is enforced by role grants.
  session<-.tracer_session(connection,observer=observer)
  rJava::.jcall(connection@jConnection,"V","setReadOnly",FALSE)
  on.exit(try(session$rollback(),silent=TRUE),add=TRUE,after=FALSE)
  session$execute(paste0("SET LOCAL statement_timeout=",as.integer(statementTimeoutMs)))
  session$execute("SET LOCAL lock_timeout=2000; SET LOCAL timezone='UTC'")
  snapshot<-session$query("SELECT pg_backend_pid()::text AS pid,txid_current_snapshot()::text AS snapshot")
  schemaIdentity<-session$query(paste0("SELECT encode(sha256(convert_to(COALESCE(string_agg(c.oid::text||':'||c.relname||':'||a.attnum::text||':'||a.attname||':'||a.atttypid::text||':'||a.atttypmod::text,',' ORDER BY c.oid,a.attnum),''),'UTF8')),'hex') AS hash FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid WHERE n.nspname=",.store_literal(plan$source$cdm_schema)," AND a.attnum>0 AND NOT a.attisdropped"))$HASH
  person<-session$query(paste0('SELECT COUNT(*)::text AS records,COUNT(person_id)::text AS nonnull,COUNT(DISTINCT person_id)::text AS people FROM "',plan$source$cdm_schema,'".person'))
  if(!identical(person$RECORDS,person$NONNULL) || !identical(person$RECORDS,person$PEOPLE)) stop("Invalid PERSON identity; batch cannot proceed",call.=FALSE)
  token<-.hash(paste(plan$plan_sha256,schemaIdentity,snapshot$PID,snapshot$SNAPSHOT,.stamp(),tempfile(),sep=":"))
  stages<-new.env(parent=emptyenv());events<-list();peak<-0
  tick<-function() if(!is.null(check)) check()
  stage<-function(id,sql,dependencies=character(),indexColumns=character()) {
    tick()
    if(!.string(id) || !grepl("^[a-z][a-z0-9_.]{0,80}$",id) || !.string(sql) ||
      !is.character(dependencies) || anyNA(dependencies) || anyDuplicated(dependencies) || id%in%dependencies ||
      !all(dependencies%in%ls(stages,all.names=TRUE)) || !is.character(indexColumns) || anyNA(indexColumns) || anyDuplicated(indexColumns) ||
      !all(grepl("^[a-z][a-z0-9_]{0,62}$",indexColumns))) stop("Invalid or unverified intermediate dependencies",call.=FALSE)
    deps<-stats::setNames(lapply(dependencies,function(k)get(k,stages,inherits=FALSE)$key),dependencies)
    key<-.hash(.json(.object(plan=plan$plan_sha256,transaction=token,sql_sha256=.hash(sql),dependencies=deps,index_columns=as.list(indexColumns))))
    if(exists(id,stages,inherits=FALSE)) {
      prior<-get(id,stages,inherits=FALSE)
      if(!identical(prior$key,key)) stop("Intermediate identity changed; recompute in a new workspace",call.=FALSE)
      events[[length(events)+1L]]<<-list(id=id,state="reused",key=key,source_statements=0L)
      return(prior$relation)
    }
    name<-paste0("achillesnext_",substr(token,1L,16L),"_",substr(.hash(id),1L,16L));relation<-paste0('pg_temp."',name,'"')
    create<-paste0('CREATE TEMP TABLE "',name,'" ON COMMIT DROP AS ',sql)
    started<-proc.time()[["elapsed"]]
    stats<-NULL
    if(analyze) {
      result<-session$query(paste("EXPLAIN (ANALYZE,BUFFERS,VERBOSE,FORMAT JSON)",create))
      stats<-.batch_plan_stats(jsonlite::fromJSON(result[[1]][1],simplifyVector=FALSE)[[1]],plan$source$cdm_schema)
    } else session$execute(create)
    # No grant is made; these tables are backend-private and disappear on
    # rollback/disconnect. Analyze statistics stay with the same temp relation.
    if(length(indexColumns)) session$execute(paste0('CREATE INDEX ON ',relation,' (',paste0('"',indexColumns,'"',collapse=","),')'))
    session$execute(paste("ANALYZE",relation))
    bytes<-as.numeric(session$query(paste0("SELECT pg_total_relation_size('",relation,"'::regclass)::text AS bytes"))$BYTES)
    priorBytes<-sum(vapply(ls(stages,all.names=TRUE),function(k)get(k,stages,inherits=FALSE)$bytes,0))
    peak<<-max(peak,priorBytes+bytes)
    if(peak>maxStageBytes) stop("Intermediate byte budget exceeded; transaction rolled back",call.=FALSE)
    assign(id,list(key=key,relation=relation,bytes=bytes),stages)
    events[[length(events)+1L]]<<-list(id=id,state="computed",key=key,sql_sha256=.hash(sql),elapsed_ms=(proc.time()[["elapsed"]]-started)*1000,
      relation_bytes=as.character(bytes),plan_stats=stats,sql_statements=1L,
      source_statements=if(is.null(stats)) NULL else as.integer(stats$source_scan_nodes>0L))
    tick();relation
  }
  aggregate<-function(id,sql,dependencies=character()) {
    relation<-stage(id,sql,dependencies)
    session$query(paste("SELECT * FROM",relation))
  }
  value<-work(list(stage=stage,aggregate=aggregate,transaction_key=token))
  tick();session$rollback()
  list(value=value,telemetry=list(transaction_key=token,snapshot=snapshot$SNAPSHOT,snapshot_durable=FALSE,schema_sha256=schemaIdentity,
    statements=statements,statement_count=length(statements),statement_count_scope="All SQL submitted through this worker, including control, metadata, indexes, statistics, materialization and aggregate reads; JDBC rollback is separate",
    preflight_source_statements=1L,preflight_source_rows=person$RECORDS,
    stages=events,peak_intermediate_bytes=as.character(peak),cleanup="transaction_rollback",cross_run_reuse=FALSE,
    retention="backend_private_transaction_only",budget_enforcement="after_each_materialization; statement timeout bounds statement time, not peak disk allocation"))
}
