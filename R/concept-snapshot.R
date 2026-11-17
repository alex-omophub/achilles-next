# This explicit batch producer is the only new vocabulary SQL path. Providers
# never receive its connection, schema or restricted snapshot file.
.term_header <- function(x) {
  .v2_keys(x,c("contract_version","kind","source_id","release_id","label_source","vocabulary_release","capture"))
  .nv_need(identical(x$contract_version,"1.0.0")&&identical(x$kind,"concept_snapshot")&&.string(x$source_id)&&nchar(x$source_id,type="bytes")<=256L)
  .store_uuid(x$release_id)
  .term_metadata(.object(extension_version="1.0.0",matching="ascii-fold-prefix-v1",label_source=x$label_source,
    vocabulary_release=x$vocabulary_release,snapshot_sha256=strrep("0",64),capture=x$capture))
  .nv_need(length(.v2_bytes(x))<=8192L,"Snapshot header limit")
  x
}
#' Capture a restricted local vocabulary snapshot for later approved projection
#' @param maxOutputBytes Finite total canonical JSONL output byte limit, including newlines.
#' @export
captureConceptSnapshot <- function(connectionDetails,vocabularySchema,outputFile,sourceId,releaseId,
    labelSource,vocabularyRelease,cancel=function()FALSE,queryTimeoutSeconds=900L,maxOutputBytes=1024^3) {
  .term_bound_limit(maxOutputBytes)
  .nv_need(.string(outputFile)&&!file.exists(outputFile)&&.string(sourceId)&&nchar(sourceId,type="bytes")<=256L)
  .store_uuid(releaseId);.term_identity(labelSource);.term_identity(vocabularyRelease);.term_check(cancel)
  header<-.term_header(.object(contract_version="1.0.0",kind="concept_snapshot",source_id=sourceId,release_id=releaseId,
    label_source=labelSource,vocabulary_release=vocabularyRelease,
    capture=.object(captured_at=.stamp(),within_capture="single_repeatable_read",with_aggregate_release="not_asserted")))
  parent<-.term_bound_io(function()normalizePath(dirname(outputFile),mustWork=TRUE))
  destination<-file.path(parent,basename(outputFile));lock<-file.path(parent,paste0(".achilles-terms-lock-",.hash(destination)))
  stage<-NULL;ownsLock<-FALSE;ownsStage<-FALSE;ownsDestination<-FALSE;out<-NULL;finished<-FALSE
  cleanup<-function(retain=FALSE) {
    .v2_scratch_cleanup(list(function().term_bound_close(out),
      function()if(!retain&&!finished&&ownsDestination){.term_bound_remove(destination);ownsDestination<<-FALSE},
      function()if(ownsStage){.term_bound_remove(stage,TRUE);ownsStage<<-FALSE},
      function()if(ownsLock){.term_bound_remove(lock,TRUE);ownsLock<<-FALSE}))
    invisible(NULL)
  }
  on.exit(suspendInterrupts(.v2_scratch_capture(cleanup)))
  result<-.v2_scratch_capture(function() {
    suspendInterrupts({
      .term_bound_io(function().nv_need(dir.create(lock,mode="0700",showWarnings=FALSE)));ownsLock<<-TRUE
      allowInterrupts(Sys.sleep(0))
    })
    .nv_need(!file.exists(destination),"Snapshot destination already exists")
    stage<<-tempfile(".achilles-terms-",tmpdir=parent)
    suspendInterrupts({
      .term_bound_io(function().nv_need(dir.create(stage,mode="0700",showWarnings=FALSE)));ownsStage<<-TRUE
      allowInterrupts(Sys.sleep(0))
    })
    path<-file.path(stage,"snapshot.jsonl")
    suspendInterrupts({out<<-.term_bound_io(function()file(path,"wb"));allowInterrupts(Sys.sleep(0))})
    .term_bound_io(function().nv_need(isTRUE(Sys.chmod(path,"0600"))))
    check<-function().term_check(cancel);writer<-.term_bound_writer(out,maxOutputBytes,"output_byte_limit",check)
    writer$write(.v2_bytes(header));previous<-NULL;count<-"0"
    state<-new.env(parent=emptyenv())
    .store_transaction(connectionDetails,vocabularySchema,function(tx) {
      # Oversized UTF-8 JSON is replaced at the engine before JDBC getString.
      sql<-paste0("SELECT CASE WHEN octet_length(convert_to(doc,'UTF8'))<=8192 THEN doc ELSE NULL END FROM (",
        "SELECT concept_id,jsonb_build_object('concept_tag',jsonb_build_object('kind','id','value',concept_id::text),",
        "'label',concept_name,'domain_id',domain_id,'vocabulary_id',vocabulary_id)::text AS doc FROM ",tx$schema,
        ".concept) bounded ORDER BY concept_id::numeric")
      tx$stream(sql,function(text) {
        check()
        if(!.string(text)||nchar(text,type="bytes")>8192L).term_bound_error("row_limit")
        parsed<-.v2_scratch_capture(function() {
          row<-.store_decode(text);.v2_keys(row,c("concept_tag","label","domain_id","vocabulary_id"))
          missing<-is.null(row$label)||(.string(row$label)&&!nzchar(.term_normalize(row$label)))
          if(missing)row["label"]<-list(NULL)
          row<-c(row,.object(label_state=if(missing)"unavailable" else "available",label_reason_code=if(missing)"terminology.missing_label" else NULL))
          list(row=row,key=.term_entry(row,"concept_catalogue","2.1.0"))
        })
        if(!parsed$ok){if(inherits(parsed$failure,"interrupt"))stop(parsed$failure);.term_bound_error("invalid_row")}
        row<-parsed$value$row;key<-parsed$value$key
        if(!is.null(previous)&&!.v2_less(previous,key)).term_bound_error("duplicate_id")
        raw<-.v2_bytes(row);if(length(raw)>8192L).term_bound_error("row_limit")
        writer$write(raw);previous<<-key;count<<-.nv_add(count,"1")
      })
    },readOnly=TRUE,queryTimeoutSeconds=queryTimeoutSeconds,sourceRead=TRUE,state=state)
    check();.term_bound_close(out);out<<-NULL
    .term_bound_io(function().nv_need(file.info(path)$size==writer$bytes()))
    sha<-.term_bound_io(function()digest::digest(file=path,algo="sha256"));check()
    # link() is exclusive and does not replace even an empty foreign file or
    # dangling symlink. Both paths are on the same parent filesystem.
    suspendInterrupts({
      .term_bound_io(function().nv_need(isTRUE(file.link(path,destination))));ownsDestination<<-TRUE
      allowInterrupts(Sys.sleep(0))
    })
    check();cleanup(retain=TRUE);check()
    list(path=destination,sha256=sha,rows=count)
  })
  if(!result$ok) {
    cleaned<-suspendInterrupts(.v2_scratch_capture(cleanup))
    if(!cleaned$ok).term_bound_error("cleanup_failed")
    if(inherits(result$failure,"interrupt")||inherits(result$failure,"achillesnext_terminology_error")||
      inherits(result$failure,"achillesnext_read_error"))stop(result$failure)
    .term_bound_error("capture_failed")
  }
  suspendInterrupts({finished<-TRUE;invisible(result$value)})
}
# Bounded canonical JSONL parser: a closed, hashed private copy precedes parsing.
.term_snapshot <- function(snapshot,visit,cancel=function()FALSE,maxSnapshotBytes=1024^3) {
  .term_bound_limit(maxSnapshotBytes)
  .nv_need(is.list(snapshot)&&!anyDuplicated(names(snapshot))&&all(c("path","sha256")%in%names(snapshot))&&all(names(snapshot)%in%c("path","sha256","rows")))
  .nv_need(.string(snapshot$path)&&!nzchar(Sys.readlink(snapshot$path))&&utils::file_test("-f",snapshot$path)&&
    .string(snapshot$sha256)&&grepl("^[a-f0-9]{64}$",snapshot$sha256))
  private<-NULL;con<-NULL
  cleanup<-function().v2_scratch_cleanup(list(function().term_bound_close(con),function()if(!is.null(private))private$cleanup()))
  on.exit(suspendInterrupts(.v2_scratch_capture(cleanup)))
  result<-.v2_scratch_capture(function() {
    .term_check(cancel)
    suspendInterrupts({private<<-.term_private_copy(snapshot$path,snapshot$sha256,maxSnapshotBytes,cancel);allowInterrupts(Sys.sleep(0))})
    suspendInterrupts({con<<-.term_bound_io(function()file(private$path,"rb"));allowInterrupts(Sys.sleep(0))})
    buffer<-raw();header<-NULL;last<-NULL;count<-"0"
    consume<-function(bytes) {
      .term_check(cancel);.nv_need(length(bytes)<=8192L)
      doc<-.nv_json(bytes);.nv_need(identical(bytes,.v2_bytes(doc)),"Noncanonical snapshot row")
      if(is.null(header)){header<<-.term_header(doc);return(invisible(NULL))}
      key<-.term_entry(doc,"concept_catalogue","2.1.0")
      .nv_need(is.null(last)||.v2_less(last,key),"Duplicate or unordered snapshot concept ID")
      last<<-key;visit(doc,key,header);count<<-.nv_add(count,"1")
    }
    repeat {
      .term_check(cancel);chunk<-.term_bound_io(function()readBin(con,"raw",n=8192L))
      if(!length(chunk))break
      buffer<-c(buffer,chunk)
      repeat {
        lf<-which(buffer==as.raw(10L));if(!length(lf))break
        end<-lf[[1]];consume(buffer[seq_len(end)])
        buffer<-if(end==length(buffer))raw() else buffer[seq.int(end+1L,length(buffer))]
      }
      .nv_need(length(buffer)<8192L,"Snapshot line limit")
    }
    .nv_need(!length(buffer)&&!is.null(header),"Truncated snapshot")
    if("rows"%in%names(snapshot)).nv_need(identical(count,snapshot$rows),"Snapshot row count mismatch")
    .term_check(cancel);header
  })
  cleaned<-suspendInterrupts(.v2_scratch_capture(cleanup))
  if(!cleaned$ok).term_bound_error("cleanup_failed")
  if(!result$ok)stop(result$failure)
  result$value
}
