# Native/Node differential fixture corpus. Run against the installed package.
library(AchillesNext)
ns<-asNamespace('AchillesNext')
validateDocument<-get('.nv_legacy_document',ns);validateDirectory<-get('.nv_legacy_directory',ns)
args<-commandArgs(trailingOnly=TRUE);root<-if(length(args))args[[1]] else '.'
fixture<-file.path(root,'tests/fixtures/contracts')
validateDirectory(file.path(fixture,'complete'))
setPath<-function(doc,path,value) {
 if(!length(path))return(value)
 key<-path[[1]];if(is.numeric(key))key<-key+1L
 doc[key]<-list(setPath(doc[[key]],path[-1],value));doc
}
cases<-jsonlite::fromJSON(file.path(fixture,'invalid-cases.json'),simplifyVector=FALSE)
for(case in cases) {
 doc<-jsonlite::fromJSON(file.path(fixture,case$base),simplifyVector=FALSE)
 doc<-setPath(doc,case$path,case$value)
 rejected<-tryCatch({validateDocument(case$document,doc);FALSE},error=function(e)TRUE)
 if(!rejected)stop(paste('INVALID ACCEPTED',case$id))
}
for(text in c('{"x":1,"x":2}',paste0(strrep('[',33),'0',strrep(']',33)))) {
 rejected<-tryCatch({get('.nv_json',ns)(charToRaw(text));FALSE},error=function(e)TRUE);stopifnot(rejected)
}
stopifnot(identical(get('.nv_add',ns)('9007199254740993','7'),'9007199254741000'))
stopifnot(get('.nv_compare',ns)('-2.50','-2.5')==0L)
cat('NATIVE_FIXTURES_OK:',length(cases),'invalid vectors rejected\n')
