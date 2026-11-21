# The standalone validator inserts one leaf at a time. Keep immutable records in
# insertion order so a leaf needs one append instead of random index writes for
# every identity. A positive Bloom result is always confirmed by the full key.
.v2_validation_rows <- function(directory,check,budget,expectedRows) {
  hint <- if(.v2_count(expectedRows)) suppressWarnings(as.numeric(expectedRows)) else 0
  limit <- budget$inspect()
  hint <- min(hint,2^22,(limit$max_bytes-limit$bytes)/88)
  if(hint<16384) {
    spool <- .v2_spool(directory,check,budget)
    put <- spool$put
    spool$putMany <- function(hashes,values,duplicateMessage="Duplicate validation key") {
      .nv_need(is.character(hashes)&&is.list(values)&&length(hashes)==length(values)&&length(hashes)<=2048L)
      for(i in seq_along(hashes)) put(hashes[[i]],values[[i]],duplicateMessage)
      invisible(NULL)
    }
    return(spool)
  }

  .nv_need(is.function(check));check()
  # At most 32 MiB of chain heads and 8 MiB of filters, regardless of the
  # declared or actual number of rows. The hint only sizes these accelerators.
  buckets <- 2^ceiling(log2(hint))
  heads <- numeric(buckets)
  filterA <- filterB <- raw(buckets)
  entryCount <- end <- 0
  width <- 88L # SHA-256 text, preceding offset + 1, payload length
  path <- file.path(directory,"records")
  writer <- reader <- NULL
  closed <- poisoned <- owned <- charged <- ready <- FALSE
  on.exit(if(!ready) .v2_scratch_cleanup(list(
    function().v2_scratch_close(reader),function().v2_scratch_close(writer),
    function()if(owned) {
      .v2_scratch_io(function().nv_need(unlink(directory,recursive=TRUE)==0L&&!dir.exists(directory)))
      if(charged) budget$release(0,1)
    })))
  suspendInterrupts({
    .v2_scratch_io(function().nv_need(dir.create(directory,mode="0700")))
    owned <- TRUE
    budget$acquire(0,1);charged <- TRUE
    writer <- .v2_scratch_io(function()file(path,"wb"))
    reader <- .v2_scratch_io(function()file(path,"rb"))
    allowInterrupts(Sys.sleep(0))
  })
  guard <- function() {
    .nv_need(!closed,"Validation spool is closed")
    if(poisoned) .v2_scratch_error("io_failure")
  }
  io <- function(work) {
    outcome <- .v2_scratch_capture(function().v2_scratch_io(work))
    if(!outcome$ok) {poisoned <<- TRUE;stop(outcome$failure)}
    outcome$value
  }
  slot <- function(hashes,start) strtoi(substr(hashes,start,start+5L),16L)%%buckets+1L
  mask <- function(hashes,at) bitwShiftL(1L,strtoi(substr(hashes,at,at),16L)%%8L)
  # A zero head is an empty bucket. Back links are strictly decreasing and can
  # reach any earlier record even when the input is larger than the estimate.
  locate <- function(hash,position,withValue) {
    probes <- 0
    while(position>0) {
      if(probes%%128==0) check()
      start <- position-1
      header <- io(function() {
        seek(reader,start,origin="start",rw="read")
        bytes <- readBin(reader,"raw",n=width)
        .nv_need(length(bytes)==width)
        rawToChar(bytes)
      })
      .nv_need(grepl("^[a-f0-9]{64}[0-9]{24}\\z",header,perl=TRUE),"Invalid validation spool record")
      previous <- as.numeric(substr(header,65L,80L))
      size <- as.integer(substr(header,81L,88L))
      .nv_need(previous<=start&&size<=131072L&&start+width+size<=end,"Invalid validation spool position")
      if(identical(substr(header,1L,64L),hash)) {
        if(!withValue) return(TRUE)
        return(io(function() {
          bytes <- readBin(reader,"raw",n=size)
          .nv_need(length(bytes)==size)
          bytes
        }))
      }
      position <- previous;probes <- probes+1
    }
    if(withValue) NULL else FALSE
  }
  maybe <- function(atA,atB,bitA,bitB) {
    bitwAnd(as.integer(filterA[atA]),bitA)!=0L & bitwAnd(as.integer(filterB[atB]),bitB)!=0L
  }
  lookup <- function(hash,value) {
    guard()
    .nv_need(.string(hash)&&grepl("^[a-f0-9]{64}\\z",hash,perl=TRUE),"Invalid validation key")
    if(!maybe(slot(hash,7L),slot(hash,13L),mask(hash,19L),mask(hash,20L)))
      return(if(value) NULL else FALSE)
    locate(hash,heads[[slot(hash,1L)]],value)
  }
  putMany <- function(hashes,values,duplicateMessage="Duplicate validation key") {
    guard();check()
    count <- length(hashes)
    .nv_need(is.character(hashes)&&is.list(values)&&count==length(values)&&count<=2048L)
    if(!count) return(invisible(NULL))
    .nv_need(!anyNA(hashes)&&all(grepl("^[a-f0-9]{64}\\z",hashes,perl=TRUE)),"Invalid validation key")
    .nv_need(!anyDuplicated(hashes),duplicateMessage)
    payloadLengths <- lengths(values,use.names=FALSE)
    .nv_need(all(vapply(values,is.raw,TRUE))&&all(payloadLengths<=131072L),"Validation value byte limit")
    slots <- slot(hashes,1L)
    atA <- slot(hashes,7L);atB <- slot(hashes,13L)
    bitA <- mask(hashes,19L);bitB <- mask(hashes,20L)
    for(i in which(maybe(atA,atB,bitA,bitB)))
      .nv_need(!locate(hashes[[i]],heads[[slots[[i]]]],FALSE),duplicateMessage)

    sizes <- payloadLengths+width
    n <- sum(sizes)
    .nv_need(n<=2^53-1-end,"Validation scratch offset limit")
    offsets <- end+1+cumsum(as.numeric(sizes))-sizes
    previous <- heads[slots]
    # Repeated buckets inside this batch link to the prior occurrence in input
    # order, including two distinct keys with the same Bloom fingerprints.
    byBucket <- order(slots,method="radix")
    repeated <- which(duplicated(slots[byBucket]))
    previous[byBucket[repeated]] <- offsets[byBucket[repeated-1L]]
    headers <- sprintf("%s%016.0f%08d",hashes,previous,payloadLengths)
    appendBatch <- function() {
      # Bound the transient joined buffer even when many individual values
      # approach the permitted 128 KiB maximum.
      first <- 1L
      while(first<=count) {
        check()
        last <- findInterval(offsets[[first]]+4*1024^2-1,offsets)
        ids <- seq.int(first,last)
        records <- Map(function(header,value)c(charToRaw(header),value),headers[ids],values[ids])
        io(function()writeBin(do.call(c,unname(records)),writer))
        first <- last+1L
      }
      io(function(){flush(writer);.nv_need(file.info(path)$size==end+n)})
      heads[slots] <<- offsets
      for(bit in bitwShiftL(1L,0:7)) {
        a <- atA[bitA==bit];b <- atB[bitB==bit]
        filterA[a] <<- as.raw(bitwOr(as.integer(filterA[a]),bit))
        filterB[b] <<- as.raw(bitwOr(as.integer(filterB[b]),bit))
      }
      end <<- end+n;entryCount <<- entryCount+count
    }
    # A refused reservation leaves the index usable. Once the append starts,
    # interrupted or partial writes retain their reservation and fail closed.
    suspendInterrupts({
      budget$acquire(n)
      outcome <- .v2_scratch_capture(function()allowInterrupts(appendBatch()))
      if(!outcome$ok) {poisoned <<- TRUE;stop(outcome$failure)}
    })
    invisible(NULL)
  }
  ready <- TRUE
  list(putMany=putMany,put=function(hash,raw,duplicateMessage="Duplicate validation key")
    putMany(hash,list(raw),duplicateMessage),get=function(hash)lookup(hash,TRUE),has=function(hash)lookup(hash,FALSE),
    close=function() {
      if(!closed) {closed <<- TRUE;.v2_scratch_cleanup(list(function().v2_scratch_close(reader),function().v2_scratch_close(writer)))}
      invisible(NULL)
    },
    inspect=function()list(entries=entryCount,buckets=buckets,value_bytes=end,closed=closed,poisoned=poisoned))
}
