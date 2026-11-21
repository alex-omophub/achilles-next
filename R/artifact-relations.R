# Buffered append uses the same logical byte/file budget as the validation
# indexes. No file connection survives an append or a failed/cancelled write.
.artifact_append <- function(budget) {
  path <- NULL; pieces <- list(); bytes <- 0L
  sizes <- new.env(hash=TRUE,parent=emptyenv())
  flush <- function() {
    if(!bytes) return(invisible(NULL))
    old <- sizes[[path]]
    created <- is.null(old)
    old <- old %||% 0
    budget$acquire(bytes,as.integer(created))
    .v2_scratch_io(function() {
      .nv_need(file.exists(path)!=created)
      con <- file(path,"ab");on.exit(.v2_scratch_close(con))
      writeBin(do.call(c,pieces),con);base::flush(con)
      .nv_need(file.info(path)$size==old+bytes)
    })
    assign(path,old+bytes,sizes)
    pieces <<- list();bytes <<- 0L
  }
  list(add=function(destination,value) {
    if(!identical(destination,path)||bytes+length(value)>1024L^2L||length(pieces)>=256L) flush()
    path <<- destination;pieces[[length(pieces)+1L]] <<- value;bytes <<- bytes+length(value)
  },flush=flush,stored=function(destination) {
    size <- sizes[[destination]]
    .v2_scratch_io(function() {
      .nv_need(if(is.null(size)) !file.exists(destination) else identical(file.size(destination),size))
    })
    !is.null(size)
  })
}

# Scratch endpoints contain only validated strings. Empty measure fields
# represent NULL; exact decimal zero remains the single byte "0".
.artifact_endpoint <- function(mid,row,dimensions) {
  v <- row$values
  charToRaw(enc2utf8(paste(mid,row$state,v$record_count %||% "",v$person_count %||% "",
    v$person_days %||% "",v$interval_count %||% "",v$n %||% "",dimensions,sep="\n")))
}
.artifact_endpoint_reader <- function(rows) {
  keys <- rep("",128L);entries <- vector("list",128L)
  function(key,dimensions=FALSE) {
    at <- strtoi(substr(key,1L,4L),16L)%%length(keys)+1L
    cached <- identical(keys[[at]],key)
    if(cached) target <- entries[[at]] else {
      bytes <- rows$get(key)
      if(is.null(bytes)) return(NULL)
      .nv_need(length(bytes)>0L,"Invalid projected target")
      fields <- strsplit(rawToChar(bytes),"\n",fixed=TRUE)[[1L]]
      .nv_need(length(fields)==8L,"Invalid validation endpoint")
      v <- as.list(fields[3:7]);names(v) <- c("record_count","person_count","person_days","interval_count","n")
      target <- list(metric_id=fields[[1L]],state=fields[[2L]],values=v[nzchar(fields[3:7])],dimensionText=fields[[8L]])
    }
    if(dimensions && is.null(target$dimensions)) {
      target$dimensions <- .nv_json(charToRaw(target$dimensionText));cached <- FALSE
    }
    if(!cached) {keys[[at]] <<- key;entries[[at]] <<- target}
    target
  }
}

# The catalogue precedes the data graph. A dependency may point forward, so
# the caller queues the original checked row only when its target is absent.
.artifact_links <- function(mid,row,assets,catalogue,lookup,defer,rule,core,dimensionText=NULL) {
  target <- function(id,key,message,dimensions=FALSE) {
    value <- lookup(id,key,dimensions)
    if(is.null(value)&&!defer) .nv_need(FALSE,message)
    value
  }
  if(!is.null(rule)||length(row$denominator_refs)) {
    targets <- list()
    for(ref in row$denominator_refs) {
      value <- target(ref$metric_id,ref$row_key,"Missing projected denominator",TRUE)
      if(is.null(value)) return(FALSE)
      .nv_need(value$metric_id==ref$metric_id && value$state!="suppressed" &&
        identical(value$values[[ref$field]],ref$value),"Invalid projected denominator")
      targets[[paste(ref$metric_id,ref$row_key,sep="|")]] <- value$dimensions
    }
    .v2_denominator_check(mid,row,function(id,key) {
      dims <- targets[[paste(id,key,sep="|")]]
      .nv_need(!is.null(dims),"Missing projected denominator");dims
    },assets,rule=rule)
  }
  if(row$state=="suppressed") return(TRUE)
  if(row$row_kind=="summary") {
    eligible <- row;eligible$row_kind <- "eligibility_counts";eligible$dimensions <- c(row$dimensions,.object(eligibility_reason="eligible"))
    key <- .v2_row_identity(assets$rows[[mid]],eligible)
    value <- target(mid,key,"Missing projected eligibility count")
    if(is.null(value)) return(FALSE)
    .nv_need(value$state!="suppressed" && identical(value$values$record_count %||% value$values$person_count,row$values$n),"Projected summary n does not reconcile")
  }
  if(row$row_kind=="eligibility_counts" && row$dimensions$eligibility_reason=="eligible") {
    expected <- row;expected$row_kind <- "summary";expected$dimensions$eligibility_reason <- NULL
    key <- .v2_row_identity(assets$rows[[mid]],expected)
    value <- target(mid,key,"Missing eligible summary")
    if(is.null(value)) return(FALSE)
    .nv_need(value$state=="suppressed" || identical(value$values$n,row$values$record_count %||% row$values$person_count),"Projected eligible summary does not reconcile")
  }
  if(!is.null(core) && !catalogue[[core]]$state%in%c("suppressed","unsupported")) {
    key <- .v2_row_identity(assets$rows[[core]],row,dimensionText %||% .json(row$dimensions))
    value <- target(core,key,"Missing matching all-recorded cell")
    if(is.null(value)) return(FALSE)
    if(value$state!="suppressed") for(field in c("record_count","person_count"))
      .nv_need(.nv_unsigned_cmp(row$values[[field]],value$values[[field]])<=0L,"Observed counts exceed matching all-recorded counts")
  }
  TRUE
}

# In the registered core profile, concept is the leading sort dimension of
# every reconciled partition. Its subtotal stream can be compared exactly in
# bounded blocks. Other dimension orders keep keyed scratch accumulation.
.artifact_groups <- function(directory,budget,ordered,check) {
  append <- .artifact_append(budget);current <- NULL;tag <- NULL;total <- NULL
  path <- function(mid) file.path(directory,mid,"totals")
  oldTotal <- function(p) .v2_scratch_io(function() readLines(p,warn=FALSE))
  flushGroup <- function() {
    if(!is.null(current)) {
      append$add(path(current),.v2_bytes(list(tag,total)))
      current <<- NULL;tag <<- NULL;total <<- NULL
    }
  }
  add <- function(mid,concept,count) {
    if(ordered) {
      if(!identical(current,mid)||!identical(tag,concept)) {
        flushGroup();current <<- mid;tag <<- concept;total <<- count
      } else total <<- .nv_add(total,count)
    } else {
      p <- file.path(directory,mid,.v2_hash(.v2_bytes(concept)))
      old <- if(file.exists(p))oldTotal(p) else "0"
      .v2_scratch_file(p,charToRaw(paste0(.nv_add(old,count),"\n")),budget)
    }
  }
  finish <- function() {flushGroup();append$flush()}
  equal <- function(left,right) {
    if(!ordered) {
      for(pair in list(c(left,right),c(right,left))) .v2_directory_entries(file.path(directory,pair[[1L]]),function(key) {
        check();p<-file.path(directory,pair[[1L]],key);q<-file.path(directory,pair[[2L]],key)
        .nv_need(file.exists(q)&&identical(oldTotal(p),oldTotal(q)),"Projected record partition does not reconcile")
      })
      return(invisible(TRUE))
    }
    p <- path(left);q <- path(right)
    hasLeft <- append$stored(p);hasRight <- append$stored(q)
    .nv_need(hasLeft==hasRight,"Projected record partition does not reconcile")
    if(!hasLeft)return(invisible(TRUE))
    a <- .v2_scratch_io(function() file(p,"rb"));on.exit(.v2_scratch_close(a))
    b <- .v2_scratch_io(function() file(q,"rb"));on.exit(.v2_scratch_close(b),add=TRUE)
    repeat {
      check();x <- .v2_scratch_io(function() readBin(a,"raw",65536L));y <- .v2_scratch_io(function() readBin(b,"raw",65536L))
      .nv_need(identical(x,y),"Projected record partition does not reconcile")
      if(!length(x)) break
    }
    invisible(TRUE)
  }
  list(add=add,finish=finish,equal=equal)
}

.artifact_relations <- function(root,context,assets,catalogue,rows,scratch,budget,check) {
  domains <- c("condition","drug","procedure","visit","device","observation","death","specimen","measurement")
  partitions <- c("source_count","type_count","representation_count","unit_count","coded_value_count",
    "operator_count","numeric_eligibility_count","observation_qualification_count","range_status_count","status_type_count")
  pairs <- list()
  for(domain in domains) {
    cap <- paste0("core.",domain,".capture_count")
    for(mid in paste("core",domain,partitions,sep=".")) if(cap%in%names(catalogue)&&mid%in%names(catalogue))
      pairs[[mid]] <- cap
  }
  grouped <- unique(c(names(pairs),unname(unlist(pairs))))
  ordered <- all(vapply(grouped,function(mid) identical(assets$rows[[mid]]$dimensions[1L],list("concept_tag")),TRUE))
  groups <- .artifact_groups(file.path(scratch,"groups"),budget,ordered,check)
  queue <- .artifact_append(budget);queuePath <- file.path(scratch,"pending")
  readTarget <- .artifact_endpoint_reader(rows)
  seen <- new.env(hash=TRUE,parent=emptyenv())
  lookup <- function(id,key,dimensions) {
    if(!exists(id,seen,inherits=FALSE)) return(NULL)
    readTarget(key,dimensions)
  }
  mids <- names(assets$metrics)
  rules <- stats::setNames(lapply(mids,.analysis_rule,assets=assets),mids)
  targetMids <- unique(unlist(lapply(rules,function(rule)rule$metric_id),use.names=FALSE))
  observed <- grep("^observed[.][a-z_]+[.]capture_count$",mids,value=TRUE)
  core <- stats::setNames(as.list(sub("^observed[.]","core.",observed)),observed)
  coreMids <- unname(unlist(core))
  suppressed <- list();captureTotals <- list();capabilities <- list();ledger <- list()
  # Rows in a data leaf have the same metric. Cache metric-wide decisions
  # separately from endpoint lookups and row-specific suppression states.
  metric <- NULL
  isDenominator <- isCoreCapture <- isCapture <- isGrouped <- FALSE
  rule <- coreMid <- dataset <- NULL
  inspect <- function(mid,row,frame,dimensions) {
    if(!identical(metric,mid)) {
      metric <<- mid;assign(mid,TRUE,seen)
      isDenominator <<- mid%in%targetMids;isCoreCapture <<- mid%in%coreMids
      isCapture <<- grepl(".capture_count",mid,fixed=TRUE);isGrouped <<- mid%in%grouped
      rule <<- rules[[mid]];coreMid <<- core[[mid]];dataset <<- catalogue[[mid]]
      .nv_need(!is.null(dataset),"Incomplete catalogue")
    }
    if(row$state=="suppressed") suppressed[[mid]] <<- TRUE
    if(dataset$state=="suppressed") .nv_need(row$state=="suppressed")
    if(dataset$state%in%c("empty_source","empty_population")) .nv_need(row$state%in%c(dataset$state,"suppressed"))
    if(mid=="core.source.capabilities" && row$state!="suppressed") capabilities[[row$dimensions$probe_id]] <<- row$values
    if(mid=="core.execution.output_status" && dataset$state!="suppressed") {
      .nv_need(row$state=="computed" && !is.null(row$values),"Missing ledger entry payload")
      ledger[[row$dimensions$metric_id]] <<- row$values
    }
    if(mid=="core.source.passport"&&row$state!="suppressed") {
      .v2_passport_check(row$values,c(context,.object(observed_schema_sha256=root$source_schema$sha256,
        declared_cdm_version=root$source_schema$declared_cdm_version,consistency_basis=root$source_consistency$within_run)))
      .term_vocab_match(row$values,root$saved_terminology)
    }
    tag <- row$dimensions$concept_tag;count <- row$values$record_count
    if(!is.null(count)&&!is.null(tag)) {
      if(isCapture && identical(row$dimensions$period_kind,"full_scope")) {
        totals <- captureTotals[[mid]] %||% list(all=NULL,parts="0")
        if(tag$kind=="all") {
          .nv_need(is.null(totals$all),"Duplicate full-scope all-concepts capture total");totals$all <- count
        } else {
          totals$parts <- .nv_add(totals$parts,count)
          if(isGrouped) groups$add(mid,tag,count)
        }
        captureTotals[[mid]] <<- totals
      } else if(!isCapture && isGrouped) groups$add(mid,tag,count)
    }
    eligible <- row$row_kind=="eligibility_counts" && identical(row$dimensions$eligibility_reason,"eligible")
    hasLinks <- !is.null(rule)||length(row$denominator_refs)||!is.null(coreMid)||row$row_kind=="summary"||eligible
    if(hasLinks && !.artifact_links(mid,row,assets,catalogue,lookup,TRUE,rule,coreMid,dimensions)) {
      # Metric IDs are registered tokens. Canonical JSON escapes embedded LF
      # and TAB, and frame has exactly one terminal LF.
      queue$add(queuePath,c(charToRaw(paste0(mid,"\t")),frame))
    }
    if(isDenominator||isCoreCapture||row$row_kind=="summary"||eligible)
      .artifact_endpoint(mid,row,if(isDenominator)dimensions else "{}") else raw()
  }
  finish <- function() {
    groups$finish();queue$flush()
    if(queue$stored(queuePath)) {
      con <- .v2_scratch_io(function() file(queuePath,"rb"));on.exit(.v2_scratch_close(con))
      repeat {
        check()
        lines <- .v2_scratch_io(function() readLines(con,n=16L,warn=TRUE,encoding="UTF-8"))
        if(!length(lines)) break
        for(line in lines) {
          check()
          split <- regexpr("\t",line,fixed=TRUE)[1L];.nv_need(split>1L,"Invalid validation queue")
          mid <- substr(line,1L,split-1L);row <- .nv_json(charToRaw(enc2utf8(substring(line,split+1L))))
          .artifact_links(mid,row,assets,catalogue,lookup,FALSE,rules[[mid]],core[[mid]])
        }
      }
    }
    list(suppressed=suppressed,captureTotals=captureTotals,ledger=ledger,capabilities=capabilities)
  }
  reconcile <- function(available) {
    for(mid in names(pairs)) if(available(mid)&&available(pairs[[mid]])) groups$equal(mid,pairs[[mid]])
  }
  list(inspect=inspect,finish=finish,reconcile=reconcile)
}
