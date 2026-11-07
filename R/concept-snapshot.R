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
#' @export
captureConceptSnapshot <- function(connectionDetails,vocabularySchema,outputFile,sourceId,releaseId,
    labelSource,vocabularyRelease,cancel=function()FALSE,queryTimeoutSeconds=900L) {
  .nv_need(.string(outputFile)&&!file.exists(outputFile)&&.string(sourceId)&&nchar(sourceId,type="bytes")<=256L)
  .store_uuid(releaseId);.term_identity(labelSource);.term_identity(vocabularyRelease);.term_check(cancel)
  parent<-normalizePath(dirname(outputFile),mustWork=TRUE);destination<-file.path(parent,basename(outputFile))
  lock<-file.path(parent,paste0(".achilles-terms-lock-",.hash(destination)))
  .nv_need(dir.create(lock,mode="0700",showWarnings=FALSE),"Snapshot destination is locked")
  on.exit(unlink(lock,recursive=TRUE),add=TRUE)
  .nv_need(!file.exists(destination),"Snapshot destination already exists")
  stage<-tempfile(".achilles-terms-",tmpdir=parent);out<-file(stage,"wb");Sys.chmod(stage,"0600")
  closed<-FALSE;finished<-FALSE;ownsDestination<-FALSE
  on.exit({if(!closed)close(out);unlink(stage);if(!finished&&ownsDestination)unlink(destination)},add=TRUE)
  header<-.term_header(.object(contract_version="1.0.0",kind="concept_snapshot",source_id=sourceId,release_id=releaseId,
    label_source=labelSource,vocabulary_release=vocabularyRelease,
    capture=.object(captured_at=.stamp(),within_capture="single_repeatable_read",with_aggregate_release="not_asserted")))
  writeBin(.v2_bytes(header),out);previous<-NULL;count<-"0"
  .store_transaction(connectionDetails,vocabularySchema,function(tx) {
    tx$stream(paste0("SELECT jsonb_build_object('concept_tag',jsonb_build_object('kind','id','value',concept_id::text),",
      "'label',concept_name,'domain_id',domain_id,'vocabulary_id',vocabulary_id)::text FROM ",tx$schema,".concept ORDER BY concept_id::numeric"),function(text) {
      .term_check(cancel);.nv_need(.string(text)&&nchar(text,type="bytes")<=8192L,"Snapshot row limit")
      row<-.store_decode(text);.v2_keys(row,c("concept_tag","label","domain_id","vocabulary_id"))
      missing<-is.null(row$label)||(.string(row$label)&&!nzchar(.term_normalize(row$label)))
      if(missing)row["label"]<-list(NULL)
      row<-c(row,.object(label_state=if(missing)"unavailable" else "available",label_reason_code=if(missing)"terminology.missing_label" else NULL))
      key<-.term_entry(row,"concept_catalogue","2.1.0")
      .nv_need(is.null(previous)||.v2_less(previous,key),"Duplicate or unordered vocabulary concept ID")
      previous<<-key;writeBin(.v2_bytes(row),out);count<<-.nv_add(count,"1")
    })
  },readOnly=TRUE,queryTimeoutSeconds=queryTimeoutSeconds,sourceRead=TRUE)
  .term_check(cancel);close(out);closed<-TRUE
  sha<-digest::digest(file=stage,algo="sha256");.term_check(cancel)
  .nv_need(!file.exists(destination)&&file.rename(stage,destination),"Cannot finalize snapshot")
  ownsDestination<-TRUE;.term_check(cancel);finished<-TRUE
  invisible(list(path=destination,sha256=sha,rows=count))
}
# Bounded canonical JSONL parser: never read an untrusted unbounded line.
.term_snapshot <- function(snapshot,visit,cancel=function()FALSE) {
  .nv_need(is.list(snapshot)&&!anyDuplicated(names(snapshot))&&all(c("path","sha256")%in%names(snapshot))&&all(names(snapshot)%in%c("path","sha256","rows")))
  .nv_need(.string(snapshot$path)&&!nzchar(Sys.readlink(snapshot$path))&&utils::file_test("-f",snapshot$path)&&
    .string(snapshot$sha256)&&grepl("^[a-f0-9]{64}$",snapshot$sha256))
  # Parse a private immutable copy whose actual bytes match the declared hash.
  # Pre/post hashes of an externally writable source would allow a replace/restore race.
  .term_check(cancel);scratch<-tempfile("achilles-term-input-");.nv_need(dir.create(scratch,mode="0700"))
  on.exit(unlink(scratch,recursive=TRUE),add=TRUE);copy<-file.path(scratch,"snapshot.jsonl")
  .nv_need(file.copy(snapshot$path,copy)&&identical(digest::digest(file=copy,algo="sha256"),snapshot$sha256),"Snapshot hash mismatch")
  Sys.chmod(copy,"0600")
  con<-file(copy,"rb");on.exit(close(con),add=TRUE,after=FALSE);buffer<-raw();header<-NULL;last<-NULL;count<-"0"
  consume<-function(bytes) {
    .term_check(cancel);.nv_need(length(bytes)<=8192L)
    doc<-.nv_json(bytes);.nv_need(identical(bytes,.v2_bytes(doc)),"Noncanonical snapshot row")
    if(is.null(header)){header<<-.term_header(doc);return(invisible(NULL))}
    key<-.term_entry(doc,"concept_catalogue","2.1.0")
    .nv_need(is.null(last)||.v2_less(last,key),"Duplicate or unordered snapshot concept ID")
    last<<-key;visit(doc,key,header);count<<-.nv_add(count,"1")
  }
  repeat {
    .term_check(cancel);chunk<-readBin(con,"raw",n=8192L)
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
  .term_check(cancel)
  header
}
