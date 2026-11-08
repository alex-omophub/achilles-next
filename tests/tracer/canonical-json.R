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
  for(i in seq_along(strings))compare(o(z=list(o(value=strings[[i]],null=NULL),list('x',TRUE,1L)),a=strings[[i]]))
  for(value in list(NA_character_,NA,character(),c('a','b'),o(a=1,a=2)))compare(value)
  cat('CANONICAL_JSON_FROZEN_ORACLE_ASCII_UTF8_ESCAPES_CLASSES_REJECTIONS_PARITY_OK\n')
})
