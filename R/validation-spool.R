# Private validation scratch: exact hash-key lookup without one file per row.
# Fixed-width open-addressed slots contain hash, byte offset, length and two flags.
# Values stay on disk; rehashing reads one slot at a time, never the whole index.
.v2_spool <- function(directory,check=function()NULL) {
  .nv_need(is.function(check));check()
  .nv_need(dir.create(directory,mode="0700"),"Cannot create validation spool")
  data<-file(file.path(directory,"values"),"w+b")
  index<-NULL;closed<-FALSE;capacity<-1024;count<-0;end<-0;indexPath<-file.path(directory,"index-1024")
  width<-89L
  fresh<-function(path,n) {
    connection<-file(path,"w+b");ok<-FALSE
    on.exit(if(!ok)close(connection))
    seek(connection,n*width-1,origin="start",rw="write");writeBin(as.raw(0),connection)
    ok<-TRUE;connection
  }
  tryCatch(index<-fresh(indexPath,capacity),error=function(e){close(data);stop(e)})
  guard<-function().nv_need(!closed,"Validation spool is closed")
  slot<-function(hash,n) (strtoi(substr(hash,1,4),16L)*65536+strtoi(substr(hash,5,8),16L))%%n
  readSlot<-function(connection,at) {
    seek(connection,at*width,origin="start",rw="read");raw<-readBin(connection,"raw",n=width)
    .nv_need(length(raw)==width,"Truncated validation index")
    if(raw[[1]]==as.raw(0))NULL else rawToChar(raw)
  }
  writeSlot<-function(connection,at,text) {
    raw<-charToRaw(text);.nv_need(length(raw)==width)
    seek(connection,at*width,origin="start",rw="write");writeBin(raw,connection)
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
    replacement<-fresh(nextPath,n);ok<-FALSE
    on.exit(if(!ok){close(replacement);unlink(nextPath)})
    for(at in seq.int(0,capacity-1)) {
      if(at%%1024==0)check()
      text<-readSlot(index,at)
      if(!is.null(text))writeSlot(replacement,find(substr(text,1,64),replacement,n)$at,text)
    }
    close(index);index<<-replacement;capacity<<-n;ok<-TRUE
    .nv_need(unlink(indexPath)==0L);indexPath<<-nextPath
  }
  key<-function(hash).nv_need(.string(hash)&&grepl("^[a-f0-9]{64}$",hash),"Invalid validation key")
  get<-function(hash) {
    guard();key(hash);found<-find(hash)$text
    if(is.null(found))return(NULL)
    offset<-as.numeric(substr(found,65,80));n<-as.integer(substr(found,81,88))
    .nv_need(is.finite(offset)&&offset>=0&&offset+n<=end&&!is.na(n)&&n>=0L&&n<=131072L)
    seek(data,offset,origin="start",rw="read");raw<-readBin(data,"raw",n=n)
    .nv_need(length(raw)==n,"Truncated validation value");raw
  }
  put<-function(hash,raw) {
    guard();key(hash);.nv_need(is.raw(raw)&&length(raw)<=131072L,"Validation value byte limit")
    .nv_need(is.null(find(hash)$text),"Duplicate validation key")
    if((count+1)*2>capacity)grow()
    .nv_need(end+64+length(raw)<=2^53-1,"Validation scratch offset limit")
    # The key precedes each value so a bounded sequential walk needs no key map.
    seek(data,end,origin="start",rw="write");writeBin(c(charToRaw(hash),raw),data)
    text<-paste0(hash,sprintf("%016.0f",end+64),sprintf("%08d",length(raw)),"0")
    writeSlot(index,find(hash)$at,text);end<<-end+64+length(raw);count<<-count+1
    invisible(NULL)
  }
  flags<-function(hash,bit=NULL) {
    guard();key(hash);found<-find(hash);.nv_need(!is.null(found$text),"Missing validation key")
    old<-as.integer(substr(found$text,89,89))
    .nv_need(old%in%0:3)
    if(is.null(bit))return(old)
    .nv_need(bit%in%c(1L,2L));present<-bitwAnd(old,bit)!=0L
    if(!present)writeSlot(index,found$at,paste0(substr(found$text,1,88),bitwOr(old,bit)))
    !present
  }
  walk<-function(visit) {
    guard();.nv_need(is.function(visit));at<-0
    while(at<end) {
      seek(data,at,origin="start",rw="read");raw<-readBin(data,"raw",n=64L)
      .nv_need(length(raw)==64L);hash<-rawToChar(raw);found<-find(hash)$text
      .nv_need(!is.null(found)&&as.numeric(substr(found,65,80))==at+64,"Invalid validation spool position")
      n<-as.integer(substr(found,81,88));value<-get(hash);visit(hash,value)
      at<-at+64+n
    }
    .nv_need(at==end);invisible(NULL)
  }
  list(get=get,put=put,flags=flags,walk=walk,has=function(hash){guard();key(hash);!is.null(find(hash)$text)},
    close=function(){if(!closed){closed<<-TRUE;close(data);close(index)};invisible(NULL)},
    inspect=function()list(entries=count,slots=capacity,value_bytes=end,index_bytes=capacity*width,closed=closed))
}
