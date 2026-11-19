# Frozen pre-optimization serializer is the byte oracle, including rejected inputs.
library(AchillesNext)
local({
  reference<-function(x) {
    if(is.null(x))return('null')
    if(is.list(x)) {
      if(!is.null(names(x))) {
        if(anyDuplicated(names(x)))stop('Duplicate JSON keys',call.=FALSE)
        keys<-sort(names(x),method='radix')
        return(paste0('{',paste(vapply(keys,function(k)paste0(reference(k),':',reference(x[[k]])),''),collapse=','),'}'))
      }
      return(paste0('[',paste(vapply(x,reference,''),collapse=','),']'))
    }
    if(length(x)!=1L||anyNA(x))stop('JSON values must be explicit scalars or lists',call.=FALSE)
    as.character(jsonlite::toJSON(x,auto_unbox=TRUE,digits=NA))
  }
  actual<-get('.json',asNamespace('AchillesNext'));o<-get('.object',asNamespace('AchillesNext'))
  # All non-NUL ASCII bytes individually and together; multibyte/control escapes
  # and classed scalars must take the unchanged authoritative encoding path.
  strings<-c('',vapply(1:127,intToUtf8,''),intToUtf8(1:127),'a/b','</script>',
    'β blocker','💡','Cafe\u0301','Café','\u2028','\u2029','9007199254740993','-9007199254740993')
  values<-c(as.list(strings),list(NULL,TRUE,FALSE,0L,1,-0,1.25,1e20,Inf,-Inf,NaN,
    I('plain'),setNames('named','key'),as.Date('2020-01-01'),factor('abc'),o(),list()))
  compare<-function(value) {
    a<-tryCatch(actual(value),error=function(e)list(error=conditionMessage(e)))
    b<-tryCatch(reference(value),error=function(e)list(error=conditionMessage(e)))
    if(!identical(a,b)){dput(list(input=value,actual=a,reference=b));stop('Canonical byte mismatch')}
  }
  for(value in values)compare(value)
  for(key in strings)compare(stats::setNames(list('key-value'),key))
  for(i in seq_along(strings))compare(o(z=list(o(value=strings[[i]],null=NULL),list('x',TRUE,1L)),a=strings[[i]]))
  # Preserve byte-oracle behavior for every non-NUL byte, including marked
  # byte strings and Latin-1 input that must retain jsonlite's encoding path.
  byteStrings<-vapply(1:255,function(n) {
    value<-rawToChar(as.raw(n));Encoding(value)<-'bytes';value
  },'')
  for(value in byteStrings)compare(value)
  for(value in list(iconv('Café',from='UTF-8',to='latin1'),
      rawToChar(as.raw(c(0xc0,0xaf))),rawToChar(as.raw(c(0xf4,0x90,0x80,0x80)))))compare(value)
  # Exercise both sides of the bounded fast path, including an escape or UTF-8
  # character at the end of a long otherwise plain string.
  for(n in c(1023L,1024L,1025L,65536L))for(suffix in c('A','"','/','\\','\n','Ω'))
    compare(paste0(strrep('A',n-1L),suffix))
  # Actual call shape: repeated object keys, typed string counts, UTF-8 labels,
  # explicit nulls and empty objects inside bounded arrays.
  compare(o(entries=lapply(seq_len(256L),function(i)o(
    concept_tag=o(kind='id',value=as.character(i)),label=strings[[i%%length(strings)+1L]],
    label_state='available',domain_id=NULL,dimensions=o(),values=o(count=as.character(i))))))
  for(value in list(NA_character_,NA,character(),c('a','b'),o(a=1,a=2)))compare(value)
  # Fixed-field identity and row envelopes must match the independent codec
  # when dimensions are shared, including empty objects, arrays and escapes.
  f<-function(name)get(name,asNamespace('AchillesNext'))
  bytes<-function(x)charToRaw(enc2utf8(paste0(reference(x),"\n")))
  metric<-o(id='example.count',version='1')
  for(dimensions in list(o(),o(concept_tag=o(value='9007199254740993',kind='id')),
                         o(label='quoted"/\\',unicode='Café 日'))) {
    for(refs in list(list(),list(o(measure='person_count',metric_id='core.person.count',row_key=strrep('0',64),field='person_count',value='0')))) {
      row<-o(values=o(person_count='0'),state='computed',row_kind='counts',row_key=strrep('1',64),
             reason_code=NULL,dimensions=dimensions,denominator_refs=refs)
      encoded<-actual(dimensions)
      identity<-o(metric_id=metric$id,metric_version=metric$version,row_kind=row$row_kind,dimensions=dimensions)
      stopifnot(identical(f('.v2_row_identity')(metric,row,encoded),f('.v2_hash')(bytes(identity))),
                identical(f('.v2_row_bytes')(row,encoded),bytes(row)))
    }
  }
  countRow<-o(row_key='',row_kind='counts',dimensions=o(),state='computed',reason_code=NULL,
    values=o(person_count='0'),denominator_refs=list())
  stopifnot(is.list(f('.v2_row')('core.person.count',countRow,capture=TRUE)))
  duplicate<-c(countRow,list(values=o(person_count='1')))
  stopifnot(inherits(try(f('.v2_row')('core.person.count',duplicate,capture=TRUE),silent=TRUE),'try-error'))
  cat('CANONICAL_JSON_FROZEN_ORACLE_ASCII_UTF8_ESCAPES_CLASSES_REJECTIONS_PARITY_OK\n')
})
