# Logical file lengths, including simultaneous old/new indexes. This configured
# bound does not reserve filesystem blocks, directory metadata or inodes.
.v2_scratch_error <- function(code) {
  message<-switch(code,byte_limit="Validation scratch byte limit exceeded",
    file_limit="Validation scratch file limit exceeded",io_failure="Validation scratch I/O failed")
  stop(structure(list(message=message,call=NULL,code=code),
    class=c("achillesnext_scratch_error","error","condition")))
}
# Tag outcomes so returned condition objects remain ordinary values. Rethrow
# outside the handlers: a sibling handler must not reclassify cancellation.
.v2_scratch_capture <- function(work) {
  tryCatch(list(ok=TRUE,value=work()),error=function(e)list(ok=FALSE,failure=e),
    interrupt=function(e)list(ok=FALSE,failure=e))
}
.v2_scratch_io <- function(work) {
  out<-.v2_scratch_capture(function()withCallingHandlers(work(),warning=function(w).v2_scratch_error("io_failure")))
  if(!out$ok) {
    if(inherits(out$failure,"interrupt")||inherits(out$failure,"achillesnext_scratch_error"))stop(out$failure)
    .v2_scratch_error("io_failure")
  }
  out$value
}
.v2_scratch_limit <- function(value) {
  .nv_need(is.numeric(value)&&length(value)==1L&&!is.na(value)&&is.finite(value)&&
    value>=0&&value<=2^53-1&&value==floor(value),"Invalid validation scratch byte limit")
  invisible(NULL)
}
.v2_scratch_budget <- function(maxBytes=1024^3,maxFiles=1000000L) {
  .v2_scratch_limit(maxBytes)
  .nv_need(is.numeric(maxFiles)&&length(maxFiles)==1L&&!is.na(maxFiles)&&is.finite(maxFiles)&&
    maxFiles>=0&&maxFiles<=1000000L&&maxFiles==floor(maxFiles),"Invalid validation scratch file limit")
  bytes<-0;files<-0;peak<-0;peakFiles<-0
  acquire<-function(n,f=0) {
    .nv_need(is.numeric(n)&&length(n)==1L&&is.finite(n)&&n>=0&&n==floor(n)&&
      is.numeric(f)&&length(f)==1L&&is.finite(f)&&f>=0&&f==floor(f))
    if(n>maxBytes-bytes).v2_scratch_error("byte_limit")
    if(f>maxFiles-files).v2_scratch_error("file_limit")
    bytes<<-bytes+n;files<<-files+f;peak<<-max(peak,bytes);peakFiles<<-max(peakFiles,files)
    invisible(NULL)
  }
  release<-function(n,f=0) {
    .nv_need(n>=0&&n<=bytes&&f>=0&&f<=files)
    bytes<<-bytes-n;files<<-files-f;invisible(NULL)
  }
  list(acquire=acquire,release=release,
    inspect=function()list(bytes=bytes,files=files,peak_bytes=peak,peak_files=peakFiles,max_bytes=maxBytes,max_files=maxFiles))
}
# A close error can occur after a buffered write. Report it safely and still
# attempt release; failed-close cleanup must not strand another open connection.
.v2_scratch_close <- function(connection) {
  if(is.null(connection)||!tryCatch(isOpen(connection),error=function(e)FALSE))return(invisible(NULL))
  out<-.v2_scratch_capture(function().v2_scratch_io(function()close(connection)))
  if(!out$ok) {
    suspendInterrupts(try(close(connection),silent=TRUE))
    stop(out$failure)
  }
  invisible(NULL)
}
# Complete every cleanup under ordinary interrupts; explicitly signalled
# conditions are captured too, then the first failure is propagated unchanged.
.v2_scratch_cleanup <- function(actions) {
  first<-suspendInterrupts({
    failure<-NULL
    for(action in actions) {
      out<-.v2_scratch_capture(action)
      if(!out$ok&&is.null(failure))failure<-out$failure
    }
    list(failure=failure)
  })
  if(!is.null(first$failure))stop(first$failure)
  invisible(NULL)
}
# Group sums and zero-byte reachability marks share the same file/byte budget.
# Rewrites truncate in place, so their logical peak is max(old,new), not old+new.
.v2_scratch_file <- function(path,raw,budget) {
  .nv_need(is.raw(raw))
  exists<-file.exists(path)
  old<-if(exists).v2_scratch_io(function(){n<-file.info(path)$size;.nv_need(length(n)==1L&&!is.na(n));n}) else 0
  n<-length(raw);budget$acquire(max(0,n-old),if(exists)0 else 1)
  connection<-NULL
  on.exit(.v2_scratch_close(connection))
  suspendInterrupts({
    connection<-.v2_scratch_io(function()file(path,"wb"))
    allowInterrupts(Sys.sleep(0))
  })
  .v2_scratch_io(function(){writeBin(raw,connection);flush(connection);.nv_need(file.info(path)$size==n)})
  if(n<old)budget$release(old-n)
  invisible(NULL)
}
# Fixed-width open-addressed slots contain hash, byte offset, length and flags.
# Values stay on disk; rehashing scans the old index in bounded blocks.
.v2_spool <- function(directory,check=function()NULL,budget=.v2_scratch_budget()) {
  .nv_need(is.function(check));check()
  ownsDirectory<-FALSE;data<-NULL;index<-NULL;closed<-FALSE;poisoned<-FALSE;ready<-FALSE
  capacity<-1024;count<-0;end<-0;indexPath<-file.path(directory,"index-1024");width<-89L
  owned<-list()
  io<-function(work) {
    out<-.v2_scratch_capture(function().v2_scratch_io(work))
    if(!out$ok){poisoned<<-TRUE;stop(out$failure)}
    out$value
  }
  closeConnection<-function(connection)io(function().v2_scratch_close(connection))
  remove<-function(path) {
    io(function().nv_need(unlink(path)==0L&&!file.exists(path)))
    n<-owned[[path]];budget$release(n,1);owned[[path]]<<-NULL
  }
  # Ownership and cleanup are registered before opening/extending a file.
  fresh<-function(path,n) {
    connection<-NULL;ok<-FALSE
    on.exit(if(!ok).v2_scratch_cleanup(list(function()closeConnection(connection),
      function()if(!is.null(owned[[path]]))remove(path))))
    # Do not deliver a pending interrupt between opening a handle and assigning
    # it to the owner whose cleanup is already registered.
    suspendInterrupts({
      budget$acquire(n,1);owned[[path]]<<-n
      connection<-io(function()file(path,"w+b"))
      allowInterrupts(Sys.sleep(0))
    })
    if(n>0)io(function(){seek(connection,n-1,origin="start",rw="write");writeBin(as.raw(0),connection);flush(connection);.nv_need(file.info(path)$size==n)})
    ok<-TRUE;connection
  }
  on.exit(if(!ready).v2_scratch_cleanup(list(function()closeConnection(data),function()closeConnection(index),function()if(ownsDirectory){
    io(function().nv_need(unlink(directory,recursive=TRUE)==0L&&!dir.exists(directory)))
    for(n in owned)budget$release(n,1)
  })))
  # A refused existing path is never ours to remove. Protect successful mkdir
  # and its ownership assignment with the same handoff used for open handles.
  suspendInterrupts({
    .v2_scratch_io(function().nv_need(dir.create(directory,mode="0700"),"Cannot create validation spool"))
    ownsDirectory<-TRUE;allowInterrupts(Sys.sleep(0))
  })
  suspendInterrupts({data<-fresh(file.path(directory,"values"),0);allowInterrupts(Sys.sleep(0))})
  suspendInterrupts({index<-fresh(indexPath,capacity*width);allowInterrupts(Sys.sleep(0))})
  guard<-function(){.nv_need(!closed,"Validation spool is closed");if(poisoned).v2_scratch_error("io_failure")}
  slot<-function(hash,n) (strtoi(substr(hash,1,4),16L)*65536+strtoi(substr(hash,5,8),16L))%%n
  readSlot<-function(connection,at) {
    raw<-io(function(){seek(connection,at*width,origin="start",rw="read");readBin(connection,"raw",n=width)})
    .nv_need(length(raw)==width,"Truncated validation index")
    if(raw[[1]]==as.raw(0))NULL else rawToChar(raw)
  }
  writeSlot<-function(connection,at,text) {
    raw<-charToRaw(text);.nv_need(length(raw)==width)
    io(function(){seek(connection,at*width,origin="start",rw="write");writeBin(raw,connection);flush(connection)})
  }
  find<-function(hash,connection=index,n=capacity) {
    at<-slot(hash,n)
    for(step in seq_len(n)) {
      text<-readSlot(connection,at)
      if(is.null(text)||identical(substr(text,1,64),hash))return(list(at=at,text=text))
      at<-(at+1)%%n
    }
    stop("Validation index is full",call.=FALSE)
  }
  grow<-function() {
    n<-capacity*2;nextPath<-file.path(directory,paste0("index-",sprintf("%.0f",n)))
    replacement<-NULL;ok<-FALSE
    on.exit(if(!ok).v2_scratch_cleanup(list(function()closeConnection(replacement),
      function()if(!is.null(owned[[nextPath]]))remove(nextPath))))
    suspendInterrupts({replacement<-fresh(nextPath,n*width);allowInterrupts(Sys.sleep(0))})
    # Reinsert in old physical slot order so collision placement stays
    # deterministic across block boundaries. Keep one old block in memory.
    first<-0
    while(first<capacity) {
      check()
      slots<-min(1024,capacity-first)
      block<-io(function(){seek(index,first*width,origin="start",rw="read");readBin(index,"raw",n=slots*width)})
      .nv_need(length(block)==slots*width,"Truncated validation index")
      starts<-seq.int(1L,length(block),by=width)
      for(start in starts[block[starts]!=as.raw(0)]) {
        text<-rawToChar(block[start:(start+width-1L)])
        writeSlot(replacement,find(substr(text,1,64),replacement,n)$at,text)
      }
      first<-first+slots
    }
    check()
    # Once the old index is removed, defer asynchronous interrupts until the
    # replacement is installed. Explicit I/O failures still poison and unwind.
    suspendInterrupts({
      closeConnection(index);index<<-NULL
      remove(indexPath)
      index<<-replacement;indexPath<<-nextPath;capacity<<-n;ok<-TRUE
    })
  }
  key<-function(hash).nv_need(.string(hash)&&grepl("^[a-f0-9]{64}$",hash),"Invalid validation key")
  get<-function(hash) {
    guard();key(hash);found<-find(hash)$text
    if(is.null(found))return(NULL)
    offset<-as.numeric(substr(found,65,80));n<-as.integer(substr(found,81,88))
    .nv_need(is.finite(offset)&&offset>=0&&offset+n<=end&&!is.na(n)&&n>=0L&&n<=131072L)
    raw<-io(function(){seek(data,offset,origin="start",rw="read");readBin(data,"raw",n=n)})
    .nv_need(length(raw)==n,"Truncated validation value");raw
  }
  put<-function(hash,raw) {
    guard();key(hash);.nv_need(is.raw(raw)&&length(raw)<=131072L,"Validation value byte limit")
    found<-find(hash)
    .nv_need(is.null(found$text),"Duplicate validation key")
    if((count+1)*2>capacity) {
      grow()
      found<-find(hash)
    }
    .nv_need(end+64+length(raw)<=2^53-1,"Validation scratch offset limit")
    n<-64+length(raw);budget$acquire(n)
    # Failed append/index writes poison the spool; reserved bytes stay charged
    # until the enclosing admission removes the entire scratch tree.
    owned[[file.path(directory,"values")]]<<-end+n
    out<-.v2_scratch_capture(function(){
      io(function(){seek(data,end,origin="start",rw="write");writeBin(c(charToRaw(hash),raw),data);flush(data);.nv_need(file.info(file.path(directory,"values"))$size==end+n)})
      text<-paste0(hash,sprintf("%016.0f",end+64),sprintf("%08d",length(raw)),"0")
      writeSlot(index,found$at,text);end<<-end+n;count<<-count+1
    })
    if(!out$ok){poisoned<<-TRUE;stop(out$failure)}
    invisible(NULL)
  }
  flags<-function(hash,bit=NULL) {
    guard();key(hash);found<-find(hash);.nv_need(!is.null(found$text),"Missing validation key")
    old<-as.integer(substr(found$text,89,89));.nv_need(old%in%0:3)
    if(is.null(bit))return(old)
    .nv_need(bit%in%c(1L,2L));present<-bitwAnd(old,bit)!=0L
    if(!present)writeSlot(index,found$at,paste0(substr(found$text,1,88),bitwOr(old,bit)))
    !present
  }
  walk<-function(visit) {
    guard();.nv_need(is.function(visit));at<-0
    while(at<end) {
      raw<-io(function(){seek(data,at,origin="start",rw="read");readBin(data,"raw",n=64L)})
      .nv_need(length(raw)==64L);hash<-rawToChar(raw);found<-find(hash)$text
      .nv_need(!is.null(found)&&as.numeric(substr(found,65,80))==at+64,"Invalid validation spool position")
      n<-as.integer(substr(found,81,88));value<-get(hash);visit(hash,value);at<-at+64+n
    }
    .nv_need(at==end);invisible(NULL)
  }
  ready<-TRUE
  list(get=get,put=put,flags=flags,walk=walk,has=function(hash){guard();key(hash);!is.null(find(hash)$text)},
    close=function(){if(!closed){closed<<-TRUE;.v2_scratch_cleanup(list(function()closeConnection(data),function()closeConnection(index)))};invisible(NULL)},
    inspect=function()list(entries=count,slots=capacity,value_bytes=end,index_bytes=capacity*width,closed=closed,poisoned=poisoned))
}
