# Native/Node differential fixture corpus. Run against the installed package.
library(AchillesNext)
ns<-asNamespace('AchillesNext')
validateDocument<-get('.nv_legacy_document',ns);validateDirectory<-get('.nv_legacy_directory',ns)
args<-commandArgs(trailingOnly=TRUE);root<-if(length(args))args[[1]] else '.'
fixture<-file.path(root,'tests/fixtures/contracts')
validateDirectory(file.path(fixture,'complete'))
validateDocument('context',jsonlite::fromJSON(file.path(fixture,'context.json'),simplifyVector=FALSE))
setPath<-function(doc,path,value) {
 if(!length(path))return(value)
 key<-path[[1]];if(is.numeric(key))key<-key+1L
 doc[key]<-list(setPath(doc[[key]],path[-1],value));doc
}
cases<-jsonlite::fromJSON(file.path(fixture,'invalid-cases.json'),simplifyVector=FALSE)
for(case in cases) {
 doc<-jsonlite::fromJSON(file.path(fixture,case$base),simplifyVector=FALSE)
 doc<-setPath(doc,case$path,case$value)
 rejected<-tryCatch({validateDocument(case$document,doc);FALSE},error=function(e){if(case$id=='unknown-context-field')stopifnot(grepl('Unknown fields',conditionMessage(e),fixed=TRUE));TRUE})
 if(!rejected)stop(paste('INVALID ACCEPTED',case$id))
}
for(text in c('{"x":1,"x":2}',paste0(strrep('[',33),'0',strrep(']',33)))) {
 rejected<-tryCatch({get('.nv_json',ns)(charToRaw(text));FALSE},error=function(e)TRUE);stopifnot(rejected)
}
stopifnot(identical(get('.nv_add',ns)('9007199254740993','7'),'9007199254741000'))
stopifnot(get('.nv_compare',ns)('-2.50','-2.5')==0L)
cat('NATIVE_FIXTURES_OK:',length(cases),'invalid vectors rejected\n')

for(version in c('1.0.0','1.1.0')) {
 assets<-get('.nv_legacy_assets',ns)(version)
 for(value in c('2026-10-26T00:00:00+02:00','2026-10-26T00:00:00.123456Z')) {
  rejected<-tryCatch({get('.nv_schema',ns)(value,list(type='string',format='date-time'),assets$schema);FALSE},error=function(e)TRUE)
  stopifnot(rejected)
 }
}
cat('LEGACY_CONTEXT_AND_TIMESTAMP_COMPATIBILITY_OK\n')

# Structural JSON guards must preserve UTF-8 values/keys while ignoring braces
# and brackets inside strings. Exercise real page-sized multibyte input without
# machine-dependent timing assertions.
local({
 parse<-get('.nv_json',ns)
 encode<-function(value)as.character(jsonlite::toJSON(value,auto_unbox=TRUE))
 rejected<-function(bytes,message=NULL) {
  error<-tryCatch({parse(bytes);NULL},error=function(e)e)
  stopifnot(inherits(error,'error'))
  if(!is.null(message))stopifnot(grepl(message,conditionMessage(error),fixed=TRUE))
 }
 values<-c('é','β','漢','💡',paste0('e',intToUtf8(0x0301)),intToUtf8(0x2028))
 for(value in values) {
  content<-paste0(value,' [ { } ] " \\ ',strrep('{}[]',40L),value)
  text<-paste0(strrep('[',32L),encode(content),strrep(']',32L))
  decoded<-parse(charToRaw(enc2utf8(text)))
  for(i in seq_len(32L)){stopifnot(length(decoded)==1L);decoded<-decoded[[1L]]}
  stopifnot(identical(decoded,content))
  rejected(charToRaw(enc2utf8(paste0('[',text,']'))),'JSON nesting limit exceeded')
  key<-encode(value)
  duplicate<-paste0('[{',key,':1,',key,':2}]')
  rejected(charToRaw(enc2utf8(duplicate)),'Duplicate JSON keys')
  rejected(charToRaw(enc2utf8(paste0('{',key,':[}'))))
 }
 # Escaped Unicode is also decoded exactly; the depth guard counts JSON syntax,
 # not the number of bytes or code points in a quoted string.
 escaped<-'"\\u00e9\\u03b2\\u6f22\\ud83d\\udca1"'
 stopifnot(identical(parse(charToRaw(escaped)),'éβ漢💡'))
 for(bytes in list(as.raw(c(0xc0,0xaf)),as.raw(c(0xe2,0x82)),as.raw(c(0xe2,0x28,0xa1)),as.raw(c(0xf4,0x90,0x80,0x80))))
  rejected(c(charToRaw('{"x":"'),bytes,charToRaw('"}')),'Invalid UTF-8')
 expected<-lapply(seq_len(2048L),function(i)list(label=paste0('Café β 漢 💡 label ID',i),id=as.character(i)))
 page<-charToRaw(enc2utf8(encode(expected)))
 stopifnot(length(page)>100000L,identical(parse(page),expected))
 cat('NATIVE_JSON_UTF8_STRUCTURAL_DEPTH_DUPLICATE_MALFORMED_PAGE_VALUES_OK\n')
})
