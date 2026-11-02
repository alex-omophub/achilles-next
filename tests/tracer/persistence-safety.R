# Called by the marked registered-profile integration harness. These tests use
# only copied synthetic aggregates and leave the original publication untouched.
testPersistenceSafety<-function(details,schema,baseRelease,config,lib,out,execute,query) {
  ns<-asNamespace("AchillesNext");f<-function(n)get(n,ns);lit<-f(".store_literal");uuid<-f(".store_uuid")
  a<-f(".profile_assets")("reference-person-v1");ids<-names(a$metrics)
  rows<-f(".store_transaction")(details,schema,function(tx) {
    result<-list()
    for(mid in ids)f(".store_rows")(tx,baseRelease,mid,function(row,key)result[[length(result)+1L]]<<-list(mid=mid,row=row),a)
    result
  },readOnly=TRUE)
  stopifnot(length(rows)==5L)
  baseRun<-query(paste0("SELECT run_id::text AS run FROM ",schema,".achillesnext_result_release WHERE release_id=",uuid(baseRelease)))$RUN
  copyMetadata<-function() {
    run<-f(".store_new_uuid")();release<-f(".store_new_uuid")()
    execute(paste0("INSERT INTO ",schema,".achillesnext_analysis_run SELECT (jsonb_populate_record(NULL::",schema,".achillesnext_analysis_run,to_jsonb(a)||jsonb_build_object('run_id',",lit(run),"))).* FROM ",schema,".achillesnext_analysis_run a WHERE run_id=",uuid(baseRun),"; INSERT INTO ",schema,".achillesnext_result_release VALUES (",uuid(release),",",uuid(run),",'building',2,0,NULL); INSERT INTO ",schema,".achillesnext_dataset SELECT (jsonb_populate_record(NULL::",schema,".achillesnext_dataset,to_jsonb(a)||jsonb_build_object('release_id',",lit(release),"))).* FROM ",schema,".achillesnext_dataset a WHERE release_id=",uuid(baseRelease)))
    release
  }
  revision<-function(release)query(paste0("SELECT content_revision::text AS r FROM ",schema,".achillesnext_result_release WHERE release_id=",uuid(release)))$R
  count<-function(release)query(paste0("SELECT count(*)::text AS n FROM ",schema,".achillesnext_aggregate_cell WHERE release_id=",uuid(release)))$N
  fill<-function(tx,release,items=rows,maxRows=128L) {
    writer<-f(".store_writer")(tx,release,a,maxRows=maxRows)
    for(item in items)writer$add(item$mid,item$row)
    writer$finish()
  }
  good<-copyMetadata();f(".store_transaction")(details,schema,function(tx)fill(tx,good))
  stopifnot(count(good)=="5",revision(good)=="11")
  sealResultRelease(details,schema,good)
  stale<-paste(c(uuid(f(".store_new_uuid")()),uuid(good),"10",lit("stale-test"),lit(a$hash),"true","now()","repeat('a',64)"),collapse=",")
  stopifnot(inherits(try(execute(paste0("INSERT INTO ",schema,".achillesnext_validation_receipt VALUES (",stale,")")),silent=TRUE),"try-error"))
  validateResultRelease(details,schema,good)
  extra<-rows[[2]];extra$row$dimensions$gender_concept_id<-"999999999"
  extra$row$row_key<-f(".v2_row_identity")(a$rows[[extra$mid]],extra$row)
  error<-tryCatch({f(".store_transaction")(details,schema,function(tx)fill(tx,good,list(extra)));"ACCEPTED"},error=conditionMessage)
  stopifnot(grepl("Release is not writable",error,fixed=TRUE),revision(good)=="11",count(good)=="5")
  # Fail an edge after earlier flushes succeeded. Both cells and revision bumps
  # must roll back, not only the statement containing the invalid edge.
  broken<-copyMetadata();badRows<-rows;badRows[[5]]$row$denominator_refs[[1]]$row_key<-strrep("f",64)
  error<-tryCatch({f(".store_transaction")(details,schema,function(tx)fill(tx,broken,badRows,maxRows=1L));"ACCEPTED"},error=conditionMessage)
  stopifnot(error!="ACCEPTED",count(broken)=="0",revision(broken)=="2")
  cancelled<-copyMetadata()
  result<-tryCatch({f(".store_transaction")(details,schema,function(tx) {
    fill(tx,cancelled)
    stop(structure(list(message="Injected cancellation",call=NULL),class=c("interrupt","condition")))
  });FALSE},interrupt=function(e)TRUE)
  stopifnot(result,count(cancelled)=="0",revision(cancelled)=="2")
  cluster<-parallel::makePSOCKcluster(1L);on.exit(parallel::stopCluster(cluster),add=TRUE)
  job<-function(kind,config,lib,schema,release,row,signal) {
    library(AchillesNext,lib.loc=lib);e<-new.env();sys.source(config,e)
    ns<-asNamespace("AchillesNext");f<-function(n)get(n,ns)
    tryCatch({value<-f(".store_transaction")(e$fixtureConnection("owner"),schema,function(tx) {
      writeLines(tx$one("SELECT pg_backend_pid()::text"),signal)
      if(kind=="seal")tx$one(paste0("SELECT ",tx$schema,".seal_release(",f(".store_uuid")(release),")::text")) else {
        w<-f(".store_writer")(tx,release,f(".profile_assets")("reference-person-v1"));w$add(row$mid,row$row);w$finish();"WRITTEN"
      }
    },isolation=if(kind=="seal")2L else 4L,queryTimeoutSeconds=10L);list(ok=TRUE,value=value)},error=function(e)list(ok=FALSE,message=conditionMessage(e)))
  }
  environment(job)<-baseenv()
  waitBlocked<-function(signal) {
    started<-proc.time()[["elapsed"]]
    repeat {
      if(file.exists(signal)) {
        pid<-readLines(signal,warn=FALSE)
        if(length(pid)==1L&&grepl("^[0-9]+$",pid)) {
          n<-query(paste0("SELECT cardinality(pg_blocking_pids(",pid,"))::text AS n"))$N
          if(as.integer(n)>0L)return(invisible(TRUE))
        }
      }
      stopifnot(proc.time()[["elapsed"]]-started<8);Sys.sleep(.02)
    }
  }
  first<-copyMetadata();signal<-file.path(out,"sealer-pid")
  f(".store_transaction")(details,schema,function(tx) {
    fill(tx,first)
    parallel:::sendCall(cluster[[1]],job,list("seal",config,lib,schema,first,extra,signal))
    waitBlocked(signal) # Observe a real release-row lock wait before commit.
  })
  result<-parallel:::recvResult(cluster[[1]])
  stopifnot(isTRUE(result$ok),result$value=="11",count(first)=="5")
  validateResultRelease(details,schema,first)
  second<-copyMetadata();f(".store_transaction")(details,schema,function(tx)fill(tx,second))
  signal<-file.path(out,"writer-pid")
  f(".store_transaction")(details,schema,function(tx) {
    tx$one(paste0("SELECT ",tx$schema,".seal_release(",uuid(second),")::text"))
    parallel:::sendCall(cluster[[1]],job,list("write",config,lib,schema,second,extra,signal))
    waitBlocked(signal)
  },isolation=2L)
  result<-parallel:::recvResult(cluster[[1]])
  stopifnot(!isTRUE(result$ok),grepl("Release is not writable|could not serialize",result$message),count(second)=="5",revision(second)=="11")
  validateResultRelease(details,schema,second)
  cat("BATCH_ROLLBACK_CANCELLATION_SEALED_IMMUTABILITY_STALE_RECEIPT_AND_BOTH_SEAL_RACES_OK\n")
}
