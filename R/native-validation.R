# Closed shipped-contract validation. No external process or schema downloads.
.nv_need <- function(ok, message = "Result validation failed") {
  if (!isTRUE(ok)) stop(message, call. = FALSE)
}
.nv_object <- function(x) is.list(x) && !is.null(names(x))
.nv_array <- function(x) is.list(x) && is.null(names(x))
.nv_equal <- function(a,b) {
  if (!is.list(a) && !is.list(b)) return(identical(a,b) ||
    (is.numeric(a) && is.numeric(b) && length(a)==1L && length(b)==1L && isTRUE(a==b)))
  identical(.json(a),.json(b))
}
.nv_json <- function(raw) {
  text <- rawToChar(raw)
  .nv_need(!anyNA(iconv(text, from = "UTF-8", to = "UTF-8", sub = NA)), "Invalid UTF-8")
  tokens <- gregexpr('"([^"\\\\]|\\\\.)*"|[{}\\[\\]]', text, perl = TRUE)[[1]]
  if (tokens[[1]] > 0L) {
    first <- substring(text, tokens, tokens)
    depth <- cumsum(ifelse(first %in% c("{", "["), 1L, ifelse(first %in% c("}", "]"), -1L, 0L)))
    .nv_need(max(depth) <= 32L && min(depth) >= 0L, "JSON nesting limit exceeded")
  }
  result <- jsonlite::fromJSON(text, simplifyVector = FALSE)
  walk <- function(x) {
    if (is.list(x)) {
      .nv_need(!anyDuplicated(names(x)), "Duplicate JSON keys")
      invisible(lapply(x, walk))
    }
  }
  walk(result); result
}
.nv_date <- function(x, timestamp = FALSE) {
  if (!is.character(x) || length(x) != 1L || is.na(x)) return(FALSE)
  if (timestamp && !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?Z$", x)) return(FALSE)
  d <- substr(x, 1, 10)
  if (!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", d)) return(FALSE)
  y <- as.integer(substr(d,1,4)); m <- as.integer(substr(d,6,7)); day <- as.integer(substr(d,9,10))
  if (y < 1 || m < 1 || m > 12) return(FALSE)
  days <- c(31L, if(y%%4==0 && (y%%100!=0 || y%%400==0)) 29L else 28L,31L,30L,31L,30L,31L,31L,30L,31L,30L,31L)
  if(day < 1 || day > days[[m]]) return(FALSE)
  if(timestamp) return(as.integer(substr(x,12,13)) < 24L && as.integer(substr(x,15,16)) < 60L && as.integer(substr(x,18,19)) < 60L)
  nchar(x)==10L
}
.nv_schema <- function(x, schema, root) {
  check <- function(x,s) .nv_schema(x,s,root)
  if (!is.null(schema$`$ref`)) {
    ref <- schema$`$ref`; prefix <- "#/$defs/"
    if (!is.null(root$`$id`) && startsWith(ref, root$`$id`)) ref <- substring(ref, nchar(root$`$id`)+1L)
    .nv_need(startsWith(ref,prefix),"Nonlocal schema reference")
    target <- root$`$defs`[[substring(ref,nchar(prefix)+1L)]]
    .nv_need(!is.null(target),"Unknown schema reference"); return(check(x,target))
  }
  for (union in c("oneOf","anyOf")) if (!is.null(schema[[union]])) {
    matches <- vapply(schema[[union]],function(s) tryCatch({check(x,s);TRUE},error=function(e) FALSE),TRUE)
    .nv_need(if(union=="oneOf") sum(matches)==1L else any(matches),"Schema alternatives rejected")
  }
  if ("const" %in% names(schema)) .nv_need(.nv_equal(x,schema$const),"Invalid constant")
  if (!is.null(schema$enum)) .nv_need(any(vapply(schema$enum,function(v) .nv_equal(x,v),TRUE)),"Unknown enum")
  if (!is.null(schema$type)) {
    type <- schema$type
    ok <- switch(type, object=.nv_object(x),array=.nv_array(x),null=is.null(x),
      string=is.character(x)&&length(x)==1L&&!is.na(x),boolean=is.logical(x)&&length(x)==1L&&!is.na(x),
      integer=is.numeric(x)&&length(x)==1L&&is.finite(x)&&x==trunc(x),
      number=is.numeric(x)&&length(x)==1L&&is.finite(x),FALSE)
    .nv_need(ok,"Wrong JSON type")
  }
  if (.nv_object(x)) {
    .nv_need(all(unlist(schema$required) %in% names(x)),"Missing required fields")
    if (identical(schema$additionalProperties,FALSE)) .nv_need(all(names(x)%in%names(schema$properties)),"Unknown fields")
    for (key in intersect(names(x),names(schema$properties))) check(x[[key]],schema$properties[[key]])
  }
  if (.nv_array(x)) {
    if (!is.null(schema$minItems)) .nv_need(length(x)>=schema$minItems)
    if (!is.null(schema$maxItems)) .nv_need(length(x)<=schema$maxItems)
    if (isTRUE(schema$uniqueItems)) .nv_need(!anyDuplicated(vapply(x,.json,"")))
    if (!is.null(schema$items)) invisible(lapply(x,function(v) check(v,schema$items)))
  }
  if (is.character(x) && length(x)==1L) {
    if (!is.null(schema$minLength)) .nv_need(nchar(x,type="chars")>=schema$minLength)
    if (!is.null(schema$maxLength)) .nv_need(nchar(x,type="chars")<=schema$maxLength)
    if (!is.null(schema$pattern)) .nv_need(grepl(schema$pattern,x,perl=TRUE))
    if (!is.null(schema$format)) .nv_need(.nv_date(x,identical(schema$format,"date-time")),"Invalid calendar value")
  }
  if(is.numeric(x) && length(x)==1L) {
    if(!is.null(schema$minimum)) .nv_need(x>=schema$minimum)
    if(!is.null(schema$maximum)) .nv_need(x<=schema$maximum)
  }
  invisible(TRUE)
}
# Decimal integers stay strings. Only individual digits/carries use R integers.
.nv_trim <- function(x) {x<-sub("^0+","",x);if(nzchar(x)) x else "0"}
.nv_unsigned_cmp <- function(a,b) {a<-.nv_trim(a);b<-.nv_trim(b);if(nchar(a)!=nchar(b)) sign(nchar(a)-nchar(b)) else if(a==b) 0L else if(a<b) -1L else 1L}
.nv_add <- function(a,b) {
  a<-rev(utf8ToInt(a)-48L);b<-rev(utf8ToInt(b)-48L);n<-max(length(a),length(b));length(a)<-n;length(b)<-n
  a[is.na(a)]<-0L;b[is.na(b)]<-0L;out<-integer(n+1L);carry<-0L
  for(i in seq_len(n)) {v<-a[[i]]+b[[i]]+carry;out[[i]]<-v%%10L;carry<-v%/%10L}
  out[[n+1L]]<-carry;.nv_trim(paste(rev(out),collapse=""))
}
.nv_mul <- function(a,b) {
  if (nchar(a)*nchar(b)>1000000) {
    # Java is already an R package dependency. BigInteger avoids both binary
    # floating point and quadratic interpreted-R work on large valid operands.
    rJava::.jinit()
    x <- rJava::.jnew("java/math/BigInteger",a)
    y <- rJava::.jnew("java/math/BigInteger",b)
    return(rJava::.jcall(rJava::.jcall(x,"Ljava/math/BigInteger;","multiply",y),"S","toString"))
  }
  a<-rev(utf8ToInt(a)-48L);b<-rev(utf8ToInt(b)-48L);out<-integer(length(a)+length(b)+1L)
  for(i in seq_along(a)) for(j in seq_along(b)) out[[i+j-1L]]<-out[[i+j-1L]]+a[[i]]*b[[j]]
  for(i in seq_len(length(out)-1L)) {out[[i+1L]]<-out[[i+1L]]+out[[i]]%/%10L;out[[i]]<-out[[i]]%%10L}
  .nv_trim(paste(rev(out),collapse=""))
}
.nv_decimal <- function(x) {
  negative<-startsWith(x,"-");x<-sub("^-","",x);bits<-strsplit(x,".",fixed=TRUE)[[1]]
  list(negative=negative,digits=.nv_trim(paste(bits,collapse="")),scale=if(length(bits)==2L)nchar(bits[[2]]) else 0L)
}
.nv_compare <- function(a,b,multiplier="1") {
  a<-.nv_decimal(a);b<-.nv_decimal(b);a$digits<-.nv_mul(a$digits,multiplier)
  a$negative<-a$negative && a$digits!="0";b$negative<-b$negative && b$digits!="0"
  if(a$negative!=b$negative) return(if(a$negative)-1L else 1L)
  scale<-max(a$scale,b$scale)
  result<-.nv_unsigned_cmp(paste0(a$digits,strrep("0",scale-a$scale)),paste0(b$digits,strrep("0",scale-b$scale)))
  if(a$negative) -result else result
}
.nv_sum <- function(xs) Reduce(.nv_add,xs,init="0")
.nv_reason <- function(state,reason) .nv_need(if(state=="computed") is.null(reason) else .string(reason),"State/reason mismatch")
.nv_result <- function(doc) {
  .nv_reason(doc$state,doc$reason);available<-doc$state%in%c("computed","empty_source","empty_population")
  .nv_need(if(available) .nv_array(doc$rows) else is.null(doc$rows),"State/rows mismatch")
  if(is.null(doc$rows)) return(invisible(TRUE))
  keys<-vapply(doc$rows,function(r).json(r$dimensions),"");.nv_need(!anyDuplicated(keys),"Duplicate stratum")
  stats<-c("sum","min","max","mean_numerator","mean_denominator","p10","p25","p50","p75","p90")
  for(row in doc$rows) {
    .nv_reason(row$state,row$reason)
    if(doc$state!="computed") .nv_need(row$state%in%c(doc$state,"suppressed"))
    if(row$state=="suppressed") {.nv_need(is.null(row$values)&&is.null(row$denominator));next}
    v<-row$values;.nv_need(!is.null(v))
    if(row$state!="computed") .nv_need(identical(v$count,"0")||identical(v$n,"0"))
    if(doc$metric_id=="measurement.numeric_summary") {
      .nv_need(row$dimensions$raw_operator_tag%in%c("null","zero"))
      if(v$n=="0") .nv_need(row$state!="computed" && all(vapply(v[stats],is.null,TRUE))) else {
        .nv_need(row$state=="computed" && all(!vapply(v[stats],is.null,TRUE)))
        .nv_need(identical(v$mean_numerator,v$sum)&&identical(v$mean_denominator,v$n))
        .nv_need(.nv_compare(v$min,v$sum,v$n)<=0 && .nv_compare(v$max,v$sum,v$n)>=0,"Summary sum bounds")
        order<-c("min","p10","p25","p50","p75","p90","max")
        for(i in seq_len(length(order)-1L)) .nv_need(.nv_compare(v[[order[[i]]]],v[[order[[i+1L]]]])<=0,"Summary quantile order")
      }
    }
    if(doc$metric_id=="execution.timing") .nv_need(if(v$availability=="measured") !is.null(v$duration_ms)&&is.null(v$reason) else is.null(v$duration_ms)&&!is.null(v$reason))
    if(doc$metric_id=="source.capabilities") {
      .nv_need(if(v$availability=="available") isTRUE(v$table_present)&&isTRUE(v$column_present)&&isTRUE(v$readable)&&is.null(v$reason) else !is.null(v$reason))
      if(v$availability=="absent") .nv_need(identical(v$table_present,FALSE)||identical(v$column_present,FALSE))
    }
    if(doc$metric_id=="execution.output_status") .nv_reason(v$state,v$reason)
  }
  invisible(TRUE)
}
.nv_periods <- function(request) {
  start<-request$window$start;end<-request$window$end
  y<-as.integer(substr(start,1,4));m<-as.integer(substr(start,6,7));ey<-as.integer(substr(end,1,4));em<-as.integer(substr(end,6,7))
  n<-(ey-y)*12L+em-m+1L;.nv_need(start<=end&&n>=1L&&n<=120L)
  out<-list(.object(period_kind="window",period_start=start,period_end=end))
  for(i in seq_len(n)-1L) {
    year<-y+(m-1L+i)%/%12L;month<-(m-1L+i)%%12L+1L
    first<-sprintf("%04d-%02d-01",year,month)
    days<-c(31L,if(year%%4==0&&(year%%100!=0||year%%400==0))29L else 28L,31L,30L,31L,30L,31L,31L,30L,31L,30L,31L)
    last<-sprintf("%04d-%02d-%02d",year,month,days[[month]])
    out[[length(out)+1L]]<-.object(period_kind="month",period_start=max(start,first),period_end=min(end,last))
  }
  out
}
.nv_legacy_assets <- local({
  cache<-new.env(parent=emptyenv())
  function(version) {
    .nv_need(version%in%c('1.0.0','1.1.0'),'Unsupported contract')
    if(exists(version,cache,inherits=FALSE)) return(get(version,cache))
    dir<-system.file(paste0('contracts/',if(version=='1.0.0')'v1' else 'v1.1'),package='AchillesNext',mustWork=TRUE)
    lock<-jsonlite::fromJSON(file.path(dir,'schema-lock.json'),simplifyVector=FALSE)
    for(name in names(lock$sha256)) .nv_need(identical(digest::digest(file=file.path(dir,name),algo='sha256'),lock$sha256[[name]]),'Schema lock mismatch')
    schema<-jsonlite::fromJSON(file.path(dir,'contract.schema.json'),simplifyVector=FALSE)
    profilePath<-system.file('analysis/alpha-measurement-v1.json',package='AchillesNext',mustWork=TRUE)
    result<-list(schema=schema,profile=jsonlite::fromJSON(profilePath,simplifyVector=FALSE),profile_hash=digest::digest(file=profilePath,algo='sha256'))
    assign(version,result,cache);result
  }
})
.nv_legacy_document <- function(kind,doc) {
  assets<-.nv_legacy_assets(doc$contract_version)
  .nv_schema(doc,assets$schema$`$defs`[[kind]],assets$schema)
  if(kind=='result') .nv_result(doc)
  if(kind=='bundle') {
    .nv_need(identical(doc$request_sha256,.hash(.json(doc$request))),'Request hash mismatch')
    .nv_need(identical(doc$profile$sha256,assets$profile_hash),'Profile hash mismatch')
  }
  if(kind=='terminology') {
    ids<-vapply(doc$concepts,function(c).json(c$concept_id),'');.nv_need(!anyDuplicated(ids))
    for(c in doc$concepts) .nv_need(if(c$state=='available') !is.null(c$concept_name)&&!is.null(c$domain_id)&&is.null(c$reason) else is.null(c$concept_name)&&is.null(c$domain_id)&&!is.null(c$reason))
  }
  invisible(TRUE)
}
.nv_legacy_bundle <- function(m,docs,t) {
  assets<-.nv_legacy_assets(m$contract_version);profile<-assets$profile
  .nv_legacy_document('bundle',m);.nv_legacy_document('terminology',t)
  same<-function(a,b) identical(.json(a),.json(b))
  .nv_need(same(m$source$source_id,m$request$source_id))
  .nv_need(m$source$schema_fingerprint$state!='known'||grepl('^[0-9a-f]{64}$',m$source$schema_fingerprint$id))
  .nv_need(m$source$snapshot$state!='unknown'||(!m$reproducibility$consistent_snapshot&&!is.null(m$reproducibility$limitation)))
  .nv_need(m$reproducibility$consistent_snapshot||!is.null(m$reproducibility$limitation))
  .nv_need(m$reproducibility$execution_start<=m$reproducibility$execution_end)
  ids<-vapply(m$outputs,function(x)x$metric_id,'');expected<-unlist(profile$required_outputs)
  .nv_need(length(ids)==length(expected)&&!anyDuplicated(ids)&&setequal(ids,expected)&&setequal(names(docs),expected))
  .nv_need(t$contract_version==m$contract_version&&t$source_id==m$source$source_id&&same(t$vocabulary_release,m$source$vocabulary_release))
  .nv_need(identical(m$eligible_for_current_pointer,m$publication=='complete'))
  .nv_need(m$disclosure$scope==m$request$output_scope&&m$disclosure$policy_id==m$request$disclosure_policy_id)
  if(m$publication=='complete') .nv_need(isTRUE(m$disclosure$applied)&&!is.null(m$disclosure$approval_id)&&all(vapply(m$outputs,function(p)p$state%in%c('computed','empty_source','empty_population','suppressed'),TRUE)))
  if(m$request$output_scope=='distributable') {
    .nv_need(m$contract_version=='1.1.0'&&isTRUE(m$disclosure$applied)&&!is.null(m$disclosure$approval_id)&&m$disclosure$policy_id=='synthetic-aggregates-v1')
    .nv_need(all(vapply(m$outputs,function(p)p$metric_id%in%c('source.passport','person.count','execution.output_status')||p$state=='suppressed',TRUE)))
    .nv_need(!length(t$concepts)&&m$source$source_id=='fixture:synthetic'&&all(vapply(m$source[c('snapshot','data_release','vocabulary_release','schema_fingerprint')],function(x)x$state=='unknown',TRUE)))
  }
  cells<-new.env(hash=TRUE,parent=emptyenv())
  key<-function(mid,dims) paste0(mid,'|',.json(dims))
  lookup<-function(mid,dims) {k<-key(mid,dims);if(exists(k,cells,inherits=FALSE))get(k,cells) else NULL}
  for(p in m$outputs) {
    d<-docs[[p$metric_id]];.nv_legacy_document('result',d)
    for(k in c('contract_version','bundle_id','run_id','request_sha256')) .nv_need(same(d[[k]],m[[k]]))
    .nv_need(d$source_id==m$source$source_id)
    for(k in c('metric_id','metric_version','state','reason')) .nv_need(same(d[[k]],p[[k]]))
    .nv_need(p$rows==as.character(length(d$rows)))
    for(row in d$rows) assign(key(d$metric_id,row$dimensions),row,cells)
  }
  passport<-lookup('source.passport',.object())$values
  if(!is.null(passport)) {
    .nv_need(passport$source_id==m$source$source_id&&same(passport$source_snapshot_id,m$source$snapshot$id)&&same(passport$data_release_id,m$source$data_release$id)&&same(passport$vocabulary_release_id,m$source$vocabulary_release$id)&&passport$declared_cdm_version==m$source$declared_cdm_version&&same(passport$observed_schema_evidence,m$source$schema_fingerprint)&&passport$run_id==m$run_id)
  }
  periods<-.nv_periods(m$request);periodKey<-function(d) paste(d$period_kind,d$period_start,d$period_end,sep='|')
  periodKeys<-vapply(periods,periodKey,'');base<-list()
  for(concept in m$request$measurement_concept_ids) for(period in periods) base[[length(base)+1L]]<-c(.object(measurement_concept_id=concept),period)
  for(doc in docs) for(row in doc$rows) {
    d<-row$dimensions;expectedDen<-NULL
    if(doc$metric_id%in%c('observation.person_count','observation.monthly_person_count')) expectedDen<-list('person.count',.object(),'count')
    if(doc$metric_id=='measurement.person_count') expectedDen<-if(d$period_kind=='window') list('observation.person_count',.object(),'count') else list('observation.monthly_person_count',.object(month=paste0(substr(d$period_start,1,7),'-01')),'count')
    if(doc$metric_id%in%c('measurement.representation_count','measurement.unit_count','measurement.operator_count','measurement.numeric_eligibility_count')) expectedDen<-list('measurement.record_count',d[c('measurement_concept_id','period_kind','period_start','period_end')],'count')
    if(doc$metric_id=='measurement.numeric_summary') expectedDen<-list(doc$metric_id,d,'n')
    den<-row$denominator
    if(row$state!='suppressed') .nv_need(if(is.null(expectedDen)) is.null(den) else !is.null(den)&&den$metric_id==expectedDen[[1]]&&same(den$dimensions,expectedDen[[2]])&&den$field==expectedDen[[3]],'Wrong denominator definition')
    if(!is.null(den)) .nv_need(same(lookup(den$metric_id,den$dimensions)$values[[den$field]],den$value),'Unresolved denominator')
    if('measurement_concept_id'%in%names(d)) .nv_need(d$measurement_concept_id%in%unlist(m$request$measurement_concept_ids))
    if('period_kind'%in%names(d)) .nv_need(periodKey(d)%in%periodKeys)
    if(doc$metric_id=='measurement.numeric_summary') .nv_need(any(vapply(t$concepts,function(c) identical(c$concept_id,d$unit_concept_id)&&c$state=='available'&&c$domain_id=='Unit',TRUE)))
    if(doc$metric_id=='execution.output_status'&&!is.null(row$values)) {
      p<-Filter(function(p)p$metric_id==d$metric_id,m$outputs);.nv_need(length(p)==1L)
      .nv_need(row$values$state==p[[1]]$state&&same(row$values$reason,p[[1]]$reason)&&isTRUE(row$values$requested)&&row$values$source_id==m$source$source_id)
    }
  }
  rowsKeys<-function(rows) vapply(rows,function(r).json(r$dimensions),'')
  dense<-function(mid,dimensions) if(!is.null(docs[[mid]]$rows)) .nv_need(setequal(rowsKeys(docs[[mid]]$rows),vapply(dimensions,.json,'')),'Dense cells missing')
  for(mid in c('measurement.record_count','measurement.person_count')) dense(mid,base)
  flags<-list();reasons<-list()
  for(d in base) {
    for(n in c(FALSE,TRUE)) for(coded in c(FALSE,TRUE)) for(text in c(FALSE,TRUE)) flags[[length(flags)+1L]]<-c(d,.object(numeric_present=n,coded_present=coded,source_text_present=text))
    for(reason in profile$numeric_eligibility) reasons[[length(reasons)+1L]]<-c(d,.object(eligibility_reason=reason$reason))
  }
  dense('measurement.representation_count',flags);dense('measurement.numeric_eligibility_count',reasons)
  for(mid in c('source.passport','person.count','observation.person_count','observation.person_days')) dense(mid,list(.object()))
  dense('source.capabilities',lapply(profile$prerequisite_probes,function(p).object(probe_id=p$id)))
  dense('execution.output_status',lapply(profile$required_outputs,function(id).object(metric_id=id)))
  timing<-list();for(id in profile$required_outputs) for(phase in m$timing_phases) timing[[length(timing)+1L]]<-.object(metric_id=id,phase=phase)
  dense('execution.timing',timing)
  dense('observation.monthly_person_count',lapply(periods[-1],function(p).object(month=paste0(substr(p$period_start,1,7),'-01'))))
  grouped<-new.env(hash=TRUE,parent=emptyenv())
  for(mid in c('measurement.representation_count','measurement.numeric_eligibility_count','measurement.unit_count','measurement.operator_count')) {
    if(is.null(docs[[mid]]$rows)) next
    for(row in docs[[mid]]$rows) {
      k<-key(mid,row$dimensions[c('measurement_concept_id','period_kind','period_start','period_end')])
      old<-if(exists(k,grouped,inherits=FALSE))get(k,grouped) else list();assign(k,c(old,list(row)),grouped)
    }
  }
  for(d in base) {
    records<-lookup('measurement.record_count',d)$values$count
    for(mid in c('measurement.representation_count','measurement.numeric_eligibility_count','measurement.unit_count','measurement.operator_count')) if(!is.null(records)&&!is.null(docs[[mid]]$rows)) {
      k<-key(mid,d);rows<-if(exists(k,grouped,inherits=FALSE))get(k,grouped) else list()
      if(all(vapply(rows,function(r)!is.null(r$values),TRUE))) .nv_need(.nv_sum(vapply(rows,function(r)r$values$count,''))==records,'Counts do not reconcile')
    }
    tested<-lookup('measurement.person_count',d)
    if(!is.null(tested$values)&&!is.null(tested$denominator$value)) .nv_need(.nv_unsigned_cmp(tested$values$count,tested$denominator$value)<=0)
  }
  for(concept in m$request$measurement_concept_ids) {
    window<-c(.object(measurement_concept_id=concept),periods[[1]])
    eligible<-lookup('measurement.numeric_eligibility_count',c(window,.object(eligibility_reason='eligible')))$values$count
    rows<-Filter(function(r)identical(r$dimensions$measurement_concept_id,concept),docs[['measurement.numeric_summary']]$rows)
    if(!is.null(docs[['measurement.numeric_summary']]$rows)&&!is.null(eligible)&&all(vapply(rows,function(r)!is.null(r$values),TRUE))) .nv_need(.nv_sum(vapply(rows,function(r)r$values$n,''))==eligible)
    records<-lookup('measurement.record_count',window)$values$count
    monthly<-lapply(periods[-1],function(p)lookup('measurement.record_count',c(.object(measurement_concept_id=concept),p))$values$count)
    if(!is.null(records)&&all(!vapply(monthly,is.null,TRUE))) .nv_need(.nv_sum(unlist(monthly))==records)
  }
  if(m$publication=='complete') for(row in docs[['source.capabilities']]$rows) {
    p<-Filter(function(p)p$id==row$dimensions$probe_id,profile$prerequisite_probes)[[1]]
    .nv_need(!p$required||identical(row$values$availability,'available'))
  }
  invisible(TRUE)
}
.nv_legacy_directory <- function(directory) {
  root<-normalizePath(directory,mustWork=TRUE);total<-0
  read<-function(path) {
    .nv_need(grepl('^(manifest|terminology)\\.json$|^results/[a-z][a-z0-9._-]*\\.json$',path)&&!grepl('..',path,fixed=TRUE),'Unsafe path')
    .nv_need(utils::file_test("-f",file.path(root,path)),"Artifact must be a regular file")
    bytes<-.viewer_read(root,path);total<<-total+length(bytes);.nv_need(total<=64*1024*1024,'Bundle resource limit');bytes
  }
  m<-.nv_json(read('manifest.json'));.nv_legacy_document('bundle',m);docs<-list()
  paths<-c('manifest.json',m$terminology$path,vapply(m$outputs,function(p)p$path,''));.nv_need(!anyDuplicated(paths))
  for(p in m$outputs) {
    bytes<-read(p$path);.nv_need(identical(digest::digest(bytes,algo='sha256',serialize=FALSE),p$sha256)&&as.character(length(bytes))==p$bytes,'Partition integrity mismatch')
    docs[[p$metric_id]]<-.nv_json(bytes)
  }
  bytes<-read(m$terminology$path);.nv_need(identical(digest::digest(bytes,algo='sha256',serialize=FALSE),m$terminology$sha256)&&as.character(length(bytes))==m$terminology$bytes)
  entries<-list.files(root,all.files=TRUE,no..=TRUE)
  .nv_need(setequal(entries,c('manifest.json','terminology.json','results')))
  .nv_need(!nzchar(Sys.readlink(file.path(root,'results'))))
  files<-paste0('results/',list.files(file.path(root,'results'),all.files=TRUE,no..=TRUE))
  .nv_need(setequal(files,paths[startsWith(paths,'results/')]),'Unexpected files')
  .nv_legacy_bundle(m,docs,.nv_json(bytes));invisible(TRUE)
}
