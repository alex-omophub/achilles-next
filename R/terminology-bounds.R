# Separate finite bounds for terminology input copies and capture output. These
# count logical bytes, not filesystem allocation or client/warehouse memory.
.term_bound_error <- function(code) {
  messages<-c(invalid_limit="Invalid terminology byte limit",input_byte_limit="Terminology input byte limit exceeded",
    output_byte_limit="Terminology output byte limit exceeded",io_failure="Terminology I/O failed",
    cleanup_failed="Terminology cleanup failed",hash_mismatch="Snapshot hash mismatch",
    row_limit="Snapshot row limit",invalid_row="Invalid snapshot row",
    duplicate_id="Duplicate or unordered vocabulary concept ID",capture_failed="Terminology capture failed")
  stop(structure(list(message=unname(messages[[code]]),call=NULL,code=code),
    class=c("achillesnext_terminology_error","error","condition")))
}
.term_bound_limit <- function(value) {
  if(!is.numeric(value)||is.complex(value)||length(value)!=1L||is.na(value)||!is.finite(value)||
    value<0||value>2^53-1||value!=floor(value)).term_bound_error("invalid_limit")
  invisible(NULL)
}
.term_bound_io <- function(work) {
  outcome<-.v2_scratch_capture(function()withCallingHandlers(work(),warning=function(w).term_bound_error("io_failure")))
  if(!outcome$ok) {
    if(inherits(outcome$failure,"interrupt")||inherits(outcome$failure,"achillesnext_terminology_error")||
      inherits(outcome$failure,"achillesnext_read_error"))stop(outcome$failure)
    .term_bound_error("io_failure")
  }
  outcome$value
}
.term_bound_close <- function(connection) {
  if(is.null(connection)||!tryCatch(isOpen(connection),error=function(e)FALSE))return(invisible(NULL))
  closed<-.v2_scratch_capture(function().term_bound_io(function()close(connection)))
  if(!closed$ok) {
    suspendInterrupts(try(close(connection),silent=TRUE));stop(closed$failure)
  }
  invisible(NULL)
}
.term_bound_remove <- function(path,recursive=FALSE) {
  .term_bound_io(function().nv_need(unlink(path,recursive=recursive)==0L&&!file.exists(path)&&!dir.exists(path)))
}
.term_bound_writer <- function(connection,maxBytes,code,check=function()NULL) {
  .term_bound_limit(maxBytes);used<-0;failed<-FALSE
  write<-function(raw) {
    if(failed).term_bound_error("io_failure")
    check();.nv_need(is.raw(raw));n<-length(raw)
    if(n>maxBytes-used).term_bound_error(code)
    # Charge before the write. A warning/short/uncertain write poisons this run.
    used<<-used+n
    outcome<-.v2_scratch_capture(function().term_bound_io(function(){writeBin(raw,connection);flush(connection)}))
    if(!outcome$ok){failed<<-TRUE;stop(outcome$failure)}
    check();invisible(NULL)
  }
  list(write=write,bytes=function()used)
}
# Open the external source once, copy only bounded chunks, close both FDs and
# hash the actual private copy. No external pre/post hash is an integrity proof.
.term_private_copy <- function(path,expectedSha,maxBytes,cancel=function()FALSE) {
  .term_bound_limit(maxBytes);scratch<-NULL;owned<-FALSE;source<-NULL;output<-NULL;ready<-FALSE
  cleanup<-function() {
    .v2_scratch_cleanup(list(function().term_bound_close(source),function().term_bound_close(output),
      function()if(owned){.term_bound_remove(scratch,TRUE);owned<<-FALSE}))
    invisible(NULL)
  }
  on.exit(if(!ready)suspendInterrupts(.v2_scratch_capture(cleanup)))
  check<-function(){allowInterrupts(Sys.sleep(0));.term_check(cancel)}
  outcome<-.v2_scratch_capture(function() {
    check();scratch<<-tempfile("achilles-term-input-")
    suspendInterrupts({
      .term_bound_io(function().nv_need(dir.create(scratch,mode="0700",showWarnings=FALSE)));owned<<-TRUE
      allowInterrupts(Sys.sleep(0))
    })
    copy<-file.path(scratch,"snapshot.jsonl")
    suspendInterrupts({source<<-.term_bound_io(function()file(path,"rb"));allowInterrupts(Sys.sleep(0))})
    suspendInterrupts({output<<-.term_bound_io(function()file(copy,"wb"));allowInterrupts(Sys.sleep(0))})
    .term_bound_io(function().nv_need(isTRUE(Sys.chmod(copy,"0600"))))
    writer<-.term_bound_writer(output,maxBytes,"input_byte_limit",check)
    repeat {
      check();remaining<-maxBytes-writer$bytes()
      # At exact exhaustion read one sentinel byte to distinguish EOF/growth.
      raw<-.term_bound_io(function()readBin(source,"raw",n=as.integer(min(65536,remaining+1))))
      if(!length(raw))break
      check();writer$write(raw)
    }
    .term_bound_close(source);source<<-NULL
    .term_bound_close(output);output<<-NULL
    .term_bound_io(function().nv_need(file.info(copy)$size==writer$bytes()))
    check();sha<-.term_bound_io(function()digest::digest(file=copy,algo="sha256"));check()
    if(!identical(sha,expectedSha)).term_bound_error("hash_mismatch")
    list(path=copy,cleanup=cleanup)
  })
  if(!outcome$ok) {
    cleaned<-suspendInterrupts(.v2_scratch_capture(cleanup))
    if(!cleaned$ok).term_bound_error("cleanup_failed")
    stop(outcome$failure)
  }
  ready<-TRUE;outcome$value
}
