# Total logical bytes of the staged immutable export, separate from validation
# scratch and terminology input copying. Never expose paths or payloads in errors.
.export_error <- function(code) {
  stop(structure(list(message=switch(code,byte_limit="Result export byte limit exceeded",
    io_failure="Result export I/O failed"),call=NULL,code=code),
    class=c("achillesnext_export_error","error","condition")))
}
.export_limit <- function(value) {
  .nv_need(is.numeric(value)&&!is.complex(value)&&length(value)==1L&&!is.na(value)&&is.finite(value)&&
    value>=0&&value<=2^53-1&&value==floor(value),"Invalid export byte limit")
  invisible(NULL)
}
.export_io <- function(work) {
  out<-.v2_scratch_capture(function()withCallingHandlers(work(),warning=function(w).export_error("io_failure")))
  if(!out$ok) {
    if(inherits(out$failure,"interrupt")||inherits(out$failure,"achillesnext_export_error"))stop(out$failure)
    .export_error("io_failure")
  }
  out$value
}
.export_writer <- function(maxBytes=1024^3,check=function()NULL) {
  .export_limit(maxBytes);.nv_need(is.function(check))
  bytes<-0;files<-0;failed<-FALSE
  io<-function(work) {
    out<-.v2_scratch_capture(function().export_io(work))
    if(!out$ok){failed<<-TRUE;stop(out$failure)}
    out$value
  }
  write<-function(path,raw) {
    if(failed).export_error("io_failure")
    check();.nv_need(is.raw(raw));n<-length(raw)
    # Reserve the serialized bytes before opening or extending this file. Any
    # uncertain I/O aborts the export; this reservation stays conservative.
    if(n>maxBytes-bytes).export_error("byte_limit")
    .nv_need(!file.exists(path),"Duplicate export file")
    bytes<<-bytes+n;connection<-NULL
    on.exit(io(function(){suspendInterrupts(.v2_scratch_close(connection));allowInterrupts(Sys.sleep(0))}))
    suspendInterrupts({
      connection<-io(function()file(path,"wb"))
      allowInterrupts(Sys.sleep(0))
    })
    io(function(){writeBin(raw,connection);flush(connection);.nv_need(file.info(path)$size==n)})
    io(function().nv_need(isTRUE(Sys.chmod(path,"0600"))))
    files<<-files+1;check();invisible(NULL)
  }
  list(write=write,inspect=function()list(bytes=bytes,files=files,max_bytes=maxBytes,failed=failed))
}
