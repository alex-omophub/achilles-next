# Bounded aggregate-only persistence pilot; no CDM reads or scale qualification.
library(AchillesNext)
source("tools/benchmark/implementation_identity.R")
main<-function() {
  args<-commandArgs(TRUE);stopifnot(length(args)==4L)
  identity<-implementationIdentity(getwd());env<-new.env();sys.source(args[[1]],env)
  out<-normalizePath(args[[2]],mustWork=TRUE);sizes<-as.integer(strsplit(args[[3]],",",fixed=TRUE)[[1]]);trials<-as.integer(args[[4]])
  stopifnot(length(sizes)>0L,length(sizes)<=8L,!anyDuplicated(sizes),all(!is.na(sizes)&sizes>=1L&sizes<=5000L),!is.na(trials),trials>=1L,trials<=3L)
  f<-function(n)get(n,asNamespace("AchillesNext"));o<-f(".object");lit<-f(".store_literal");uuid<-f(".store_uuid")
  details<-env$fixtureConnection("owner");connection<-DatabaseConnector::connect(details)
  on.exit(DatabaseConnector::disconnect(connection),add=TRUE)
  metadata<-rJava::.jcall(connection@jConnection,"Ljava/sql/DatabaseMetaData;","getMetaData")
  runtime<-list(R=R.version.string,platform=R.version$platform,architecture=Sys.info()[["machine"]],
    database_connector=as.character(utils::packageVersion("DatabaseConnector")),
    java=rJava::.jcall("java/lang/System","S","getProperty","java.version"),
    jdbc_driver=rJava::.jcall(metadata,"S","getDriverVersion"),logical_cpus=parallel::detectCores())
  harness<-stats::setNames(lapply(c("tools/benchmark/persistence.R","tools/benchmark/persistence.py"),function(p)digest::digest(file=p,algo="sha256")),c("R","python"))
  q<-function(sql)DatabaseConnector::querySql(connection,sql,integer64AsNumeric=FALSE)
  ex<-function(sql)DatabaseConnector::executeSql(connection,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,"error.txt"))
  guard<-q("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB=="achilles_next_fixtures",guard$MARKER=="AchillesNext synthetic fixture sandbox v1")
  schema<-paste0("persistence_test_",Sys.getpid());serving<-paste0("persistence_serve_",Sys.getpid());installed<-FALSE
  on.exit(if(installed)ex(paste0('DROP SCHEMA "',serving,'","',schema,'" CASCADE')),add=TRUE,after=FALSE)
  initializeResultStore(details,schema,serving,"cdm_tiny_a_55");installed<-TRUE
  a<-f(".profile_assets")("reference-person-v1");ids<-names(a$metrics);big<-"9007199254740993"
  fixture<-function(n) {
    start<-proc.time()[["elapsed"]];total<-f(".nv_add")(big,as.character(n-1L))
    row<-function(mid,dims,value,refs=list()) {
      r<-o(row_key="",dimensions=dims,row_kind="counts",state="computed",reason_code=NULL,values=o(person_count=value),denominator_refs=refs)
      r$row_key<-f(".v2_row_identity")(a$rows[[mid]],r);list(mid=mid,row=r)
    }
    all<-row(ids[[1]],o(),total)
    ref<-list(o(measure="person_count",metric_id=ids[[1]],row_key=all$row$row_key,field="person_count",value=total))
    rows<-c(list(all),lapply(seq_len(n),function(i)row(ids[[2]],o(gender_concept_id=as.character(i)),if(i==1L)big else "1",ref)))
    list(rows=rows,total=total,preparation_seconds=proc.time()[["elapsed"]]-start)
  }
  setup<-function(n)f(".store_transaction")(details,schema,function(tx) {
    s<-tx$schema;source<-f(".store_new_uuid")();run<-f(".store_new_uuid")();release<-f(".store_new_uuid")()
    tx$execute(paste0("INSERT INTO ",s,".achillesnext_source_release VALUES (",uuid(source),",'fixture:persistence','{}','{}',repeat('a',64),'5.5',now()); INSERT INTO ",s,
      ".achillesnext_analysis_run(run_id,source_release_id,request_sha256,profile_id,profile_revision,profile_sha256,state,consistency_basis) VALUES (",uuid(run),",",uuid(source),",repeat('b',64),",lit(a$profile$profile_id),",",lit(a$profile$revision),",",lit(a$hash),",'succeeded','single_repeatable_read'); INSERT INTO ",s,".achillesnext_result_release VALUES (",uuid(release),",",uuid(run),",'building',2,0,NULL)"))
    for(i in seq_along(ids)) {
      m<-a$metrics[[ids[[i]]]]
      values<-c(uuid(release),vapply(c(m$id,m$version,m$population,m$grain,a$rows[[m$id]]$row_schema_id,f(".v2_hash")(f(".v2_bytes")(m)),"computed"),lit,""),
        "NULL","true","'{\"state\":\"supported\",\"reason_code\":null}'::jsonb",as.character(if(i==1L)1L else n),"'{\"scope_kind\":\"standard_full\",\"complete\":true,\"excluded_record_count\":\"0\",\"reason_code\":null}'::jsonb")
      tx$execute(paste0("INSERT INTO ",s,".achillesnext_dataset VALUES (",paste(values,collapse=","),")"))
    }
    release
  })
  snapshots<-list();expectedHashes<-list()
  for(n in sizes) {
    input<-fixture(n)
    for(trial in seq_len(trials))for(strategy in if(trial%%2L)c("row","batch") else c("batch","row")) {
      release<-setup(n);outer<-proc.time()[["elapsed"]]
      result<-f(".store_transaction")(details,schema,function(tx) {
        before<-tx$one(paste0("SELECT content_revision::text FROM ",tx$schema,".achillesnext_result_release WHERE release_id=",uuid(release)))
        wrapped<-tx;submissions<-0;sqlBytes<-0
        wrapped$execute<-function(sql){submissions<<-submissions+1;sqlBytes<<-sqlBytes+nchar(enc2utf8(sql),type="bytes");tx$execute(sql)}
        gc(reset=TRUE);start<-proc.time()
        if(strategy=="row") {
          for(i in seq_along(input$rows)) {
            if(i%%128L==0L)stopifnot(proc.time()[["elapsed"]]-start[["elapsed"]]<=60)
            item<-input$rows[[i]];f(".store_put_row")(wrapped,release,item$mid,item$row,a)
          }
          stats<-NULL
        } else {
          writer<-f(".store_writer")(wrapped,release,a)
          for(i in seq_along(input$rows)) {
            if(i%%128L==0L)stopifnot(proc.time()[["elapsed"]]-start[["elapsed"]]<=60)
            item<-input$rows[[i]];writer$add(item$mid,item$row)
          }
          stats<-writer$finish()
        }
        timing<-proc.time()-start;memory<-gc()
        stopifnot(timing[["elapsed"]]<=60)
        revision<-tx$one(paste0("SELECT (content_revision-",before,"::bigint)::text FROM ",tx$schema,".achillesnext_result_release WHERE release_id=",uuid(release)))
        stopifnot(revision==as.character(2L*n+1L))
        db<-f(".store_decode")(tx$one(paste0("SELECT COALESCE(jsonb_object_agg(relname,jsonb_build_object('inserted',n_tup_ins::text,'updated',n_tup_upd::text)),'{}'::jsonb)::text FROM pg_stat_xact_user_tables WHERE schemaname=",lit(schema))))
        stopifnot(db$achillesnext_result_release$updated==revision)
        list(writer_seconds=unname(timing[["elapsed"]]),cpu_seconds=unname(timing[["user.self"]]+timing[["sys.self"]]),
          r_managed_heap_peak_mb=sum(memory[,match("max used",colnames(memory))+1L]),jdbc_write_submissions=submissions,sql_bytes=sqlBytes,revision_updates=revision,
          db_transaction_rows=db,batch=stats)
      })
      result$transaction_seconds_including_probes<-proc.time()[["elapsed"]]-outer
      # Independent SQL oracle and bounded canonical readback, outside timing.
      where<-paste0(" FROM \"",schema,"\".achillesnext_aggregate_cell WHERE release_id=",uuid(release))
      stopifnot(q(paste0("SELECT count(*)::text AS n",where))$N==as.character(n+1L))
      stopifnot(q(paste0("SELECT sum(person_count)::text AS n",where," AND metric_id=",lit(ids[[2]])))$N==input$total)
      stopifnot(q(paste0("SELECT count(*)::text AS n",where," AND metric_id=",lit(ids[[2]])," AND person_count<>CASE WHEN dimensions->>'gender_concept_id'='1' THEN 9007199254740993::numeric ELSE 1 END"))$N=="0")
      stopifnot(q(paste0("SELECT count(*)::text AS n FROM \"",schema,"\".achillesnext_denominator_edge WHERE release_id=",uuid(release)))$N==as.character(n))
      digest<-q(paste0("SELECT encode(sha256(convert_to(string_agg(jsonb_build_array(metric_id,row_key,sort_key,dimensions,state,person_count::text)::text,'' ORDER BY metric_id COLLATE \"C\",sort_key COLLATE \"C\"),'UTF8')),'hex') AS h",where))$H
      if(is.null(expectedHashes[[as.character(n)]]))expectedHashes[[as.character(n)]]<-digest
      stopifnot(digest==expectedHashes[[as.character(n)]])
      result<-c(list(cardinality=n,trial=trial,strategy=strategy,rows=n+1L,edges=n,preparation_seconds=input$preparation_seconds,readback_sha256=digest),result)
      snapshots[[length(snapshots)+1L]]<-result
      jsonlite::write_json(list(runs=snapshots,implementation=identity),file.path(out,"partial-report.json"),auto_unbox=TRUE,null="null",pretty=TRUE)
      cat("PERSISTENCE ",n," ",strategy," ",format(result$writer_seconds),"s ",result$jdbc_write_submissions," submissions\n",sep="")
    }
  }
  # Diagnostic server work only: EXPLAIN executes the inserts/triggers. Its
  # timing excludes R preparation and is not an end-to-end comparator.
  probe<-fixture(128L);release<-setup(128L)
  plans<-f(".store_transaction")(details,schema,function(tx) {
    captured<-list();wrapped<-tx
    wrapped$execute<-function(sql){captured[[length(captured)+1L]]<<-f(".store_decode")(tx$one(paste0("EXPLAIN (ANALYZE, BUFFERS, WAL, FORMAT JSON) ",sql)));invisible(NULL)}
    writer<-f(".store_writer")(wrapped,release,a)
    for(item in probe$rows)writer$add(item$mid,item$row)
    stats<-writer$finish();list(plans=captured,writer=stats)
  })
  jsonlite::write_json(list(runs=snapshots,implementation=identity,harness_sha256=harness,runtime=runtime,
    server_plan_probe=plans,postgresql=q("SELECT version() AS version")$VERSION,
    limitations=c("Bounded aggregate-only pilot; no source aggregation/publication/S2 qualification","R managed-heap high water excludes JVM/native memory","JDBC execute submissions measured, network packets not captured","Per-row SQL guards/revision updates unchanged")),file.path(out,"report.json"),auto_unbox=TRUE,null="null",pretty=TRUE)
}
main()
