# An attempt-owned, unpublished, single-use capture. Only fixed-size metric
# metadata stays in memory; rows and denominator targets stay on bounded disk.
.candidate_order <- function(assets=.v2_assets()) {
  pending<-names(assets$metrics);order<-character()
  while(length(pending)) {
    ready<-Filter(function(mid){d<-.analysis_dependency(mid,assets);is.null(d)||d%in%order},pending)
    .nv_need(length(ready)>0L,"Cyclic candidate dependencies")
    order<-c(order,ready);pending<-setdiff(pending,ready)
  }
  order
}
.candidate_capture <- function(directory,assets,budget,tick) {
  ids<-names(assets$metrics);targets<-unique(unlist(lapply(ids,.analysis_dependency,assets=assets)))
  # The attempt-local index binds each denominator to its metric, followed by
  # the exact canonical frame already validated for the sequential row file.
  targetPrefixes<-stats::setNames(lapply(targets,function(mid)charToRaw(paste0(mid,"\n"))),targets)
  index<-NULL;writer<-NULL;active<-NULL;owned<-FALSE;closed<-FALSE;complete<-FALSE
  counts<-stats::setNames(rep(list("0"),length(ids)),ids)
  chains<-stats::setNames(rep(list(strrep("0",64)),length(ids)),ids)
  lengths<-stats::setNames(rep(list(0),length(ids)),ids)
  paths<-stats::setNames(vapply(ids,function(mid)file.path(directory,paste0(.hash(mid),".rows")),""),ids)
  io<-.v2_scratch_io
  frames<-list();frameBytes<-0
  flushFrames<-function() {
    if(!length(frames))return(invisible(NULL))
    io(function() {
      writeBin(do.call(c,frames),writer);flush(writer)
      .nv_need(file.info(paths[[active]])$size==lengths[[active]],"Candidate capture length mismatch")
    })
    frames<<-list();frameBytes<<-0
  }
  closeWriter<-function(){.v2_scratch_close(writer);writer<<-NULL;active<<-NULL}
  cleanup<-function() {
    if(closed)return(invisible(NULL))
    .v2_scratch_cleanup(list(closeWriter,function()if(!is.null(index))index$close(),function() {
      if(owned) {
        io(function().nv_need(unlink(directory,recursive=TRUE)==0L&&!dir.exists(directory)))
        live<-budget$inspect();budget$release(live$bytes,live$files);owned<<-FALSE
      }
    }))
    closed<<-TRUE;invisible(NULL)
  }
  ready<-FALSE;on.exit(if(!ready)cleanup())
  suspendInterrupts({
    io(function(){.nv_need(dir.create(directory,mode="0700"));owned<<-TRUE})
    allowInterrupts(Sys.sleep(0))
  })
  suspendInterrupts({index<-.v2_spool(file.path(directory,"keys"),tick,budget);allowInterrupts(Sys.sleep(0))})
  guard<-function().nv_need(!closed,"Candidate capture is closed")
  chain<-function(previous,raw).v2_hash(c(charToRaw(previous),raw))
  readFile<-function(path,limit) {
    .nv_need(!nzchar(Sys.readlink(path))&&file.exists(path)&&file.info(path)$size<=limit,"Candidate control resource limit")
    connection<-NULL;on.exit(.v2_scratch_close(connection))
    suspendInterrupts({connection<-io(function()file(path,"rb"));allowInterrupts(Sys.sleep(0))})
    io(function()readBin(connection,"raw",n=limit+1L))
  }
  controls<-NULL
  finish<-function(receipt,program,transferred=list()) {
    guard();.nv_need(!complete,"Candidate capture already completed");tick();flushFrames();closeWriter()
    .nv_need(receipt$state=="succeeded"&&identical(receipt$program_sha256,program$program_sha256)&&
      identical(.json(receipt$profile),.json(program$batch$profile))&&identical(.json(receipt$source),.json(program$batch$source))&&
      identical(receipt$cleanup$transaction,"rolled_back")&&identical(receipt$cleanup$connection,"disconnected")&&
      identical(receipt$publication_changed,FALSE)&&identical(receipt$canonical_wire,FALSE),"Incomplete source receipt")
    .nv_need(setequal(names(receipt$inventory),ids)&&setequal(names(receipt$metric_rows),ids),"Incomplete source inventory")
    total<-"0"
    for(mid in ids) {
      captured <- counts[[mid]]
      if (mid %in% names(transferred)) {
        .nv_need(identical(captured,"0"),"Metric captured through two transports")
        captured <- transferred[[mid]]
      }
      .nv_need(identical(captured,receipt$metric_rows[[mid]])&&identical(captured,receipt$inventory[[mid]]$rows),"Capture row count mismatch")
      total<-.nv_add(total,captured)
    }
    .nv_need(identical(total,receipt$rows),"Capture total mismatch")
    .sql_execution_audit_totals(.json(receipt$audit_totals))
    manifest<-.object(program_sha256=program$program_sha256,counts=counts,chains=chains,bytes=lengths,receipt_sha256=.hash(.json(receipt)))
    controls<<-list(receipt=.v2_bytes(receipt),manifest=.v2_bytes(manifest))
    for(name in names(controls)) {
      .nv_need(length(controls[[name]])<=4*1024^2,"Candidate control resource limit")
      .v2_scratch_file(file.path(directory,paste0(name,".json")),controls[[name]],budget);tick()
    }
    complete<<-TRUE;invisible(NULL)
  }
  verify<-function() {
    guard();.nv_need(complete,"Candidate capture is incomplete");tick()
    for(name in names(controls)) {
      raw<-readFile(file.path(directory,paste0(name,".json")),4*1024^2)
      .nv_need(identical(raw,controls[[name]]),"Candidate control integrity failure");tick()
    }
    invisible(NULL)
  }
  visit<-function(mid,item) {
    guard();.nv_need(!complete&&mid%in%ids&&identical(item$metric_id,mid),"Invalid candidate metric");tick()
    .v2_keys(item,c("metric_id","row_kind","dimensions","values","state","reason_code"))
    row<-.object(row_key="",dimensions=item$dimensions,row_kind=item$row_kind,state=item$state,
      reason_code=item$reason_code,values=item$values,denominator_refs=list())
    checked<-.v2_row(mid,row,assets,capture=TRUE)
    row<-checked$row;raw<-checked$bytes
    index$put(row$row_key,if(mid%in%targets)c(targetPrefixes[[mid]],raw) else raw())
    if(!identical(active,mid)) {
      flushFrames();closeWriter()
      # The enclosing capture removes every file even when opening fails.
      if(!file.exists(paths[[mid]]))budget$acquire(0,1)
      suspendInterrupts({writer<<-io(function()file(paths[[mid]],"ab"));active<<-mid;allowInterrupts(Sys.sleep(0))})
    }
    size<-4+length(raw)
    if(length(frames)>=128L||frameBytes+size>1024^2)flushFrames()
    budget$acquire(size);lengths[[mid]]<<-lengths[[mid]]+size
    frames[[length(frames)+1L]]<<-c(writeBin(length(raw),raw(),size=4L,endian="big"),raw)
    frameBytes<<-frameBytes+size
    counts[[mid]]<<-.nv_add(counts[[mid]],"1");chains[[mid]]<<-chain(chains[[mid]],raw);tick();invisible(NULL)
  }
  replay<-function(mid,visitor) {
    guard();.nv_need(complete&&mid%in%ids&&is.function(visitor),"Invalid candidate replay");tick()
    if(counts[[mid]]=="0") {.nv_need(!file.exists(paths[[mid]]),"Unexpected candidate file");return(invisible(NULL))}
    path<-paths[[mid]];.nv_need(!nzchar(Sys.readlink(path))&&file.exists(path)&&file.info(path)$size==lengths[[mid]],"Candidate capture length mismatch")
    reader<-NULL;on.exit(.v2_scratch_close(reader))
    suspendInterrupts({reader<-io(function()file(path,"rb"));allowInterrupts(Sys.sleep(0))})
    seen<-"0";digest<-strrep("0",64)
    repeat {
      tick();head<-io(function()readBin(reader,"raw",n=4L))
      if(!length(head))break
      .nv_need(length(head)==4L,"Truncated candidate frame")
      n<-readBin(head,"integer",n=1L,size=4L,endian="big")
      .nv_need(!is.na(n)&&n>0L&&n<=65536L,"Invalid candidate frame")
      raw<-io(function()readBin(reader,"raw",n=n));.nv_need(length(raw)==n,"Truncated candidate row")
      row<-.nv_json(raw)
      .v2_row(mid,row,assets,expectedBytes=raw)
      if(mid%in%targets) {
        .nv_need(identical(index$get(row$row_key),c(targetPrefixes[[mid]],raw)),"Candidate target integrity failure")
      } else .nv_need(index$has(row$row_key),"Missing capture key")
      visitor(row);seen<-.nv_add(seen,"1");digest<-chain(digest,raw)
      .nv_need(.nv_unsigned_cmp(seen,counts[[mid]])<=0,"Extra candidate rows")
    }
    .nv_need(identical(seen,counts[[mid]])&&identical(digest,chains[[mid]]),"Candidate capture integrity failure");tick()
    invisible(NULL)
  }
  lookup<-function(mid,key) {
    guard();.nv_need(complete&&mid%in%targets,"Invalid candidate target");tick()
    raw<-index$get(key);.nv_need(!is.null(raw)&&length(raw)>0L,"Missing candidate denominator")
    prefix<-targetPrefixes[[mid]];header<-seq_along(prefix)
    .nv_need(length(raw)>length(prefix)&&identical(raw[header],prefix),"Mismatched candidate denominator")
    row<-.nv_json(raw[-header])
    .nv_need(identical(row$row_key,key),"Mismatched candidate denominator")
    c(.object(metric_id=mid),row)
  }
  ready<-TRUE
  list(visit=visit,complete=finish,verify=verify,replay=replay,lookup=lookup,cleanup=cleanup,
    stats=function(){x<-budget$inspect();x$metric_files<-sum(unlist(counts)!="0");x$rows<-Reduce(.nv_add,counts,init="0");x})
}
