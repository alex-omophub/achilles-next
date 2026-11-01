# Base R only: fingerprint dependency declarations before restoring the library.
a<-commandArgs(TRUE);stopifnot(length(a)==2L)
d<-read.dcf(a[1]);fields<-c('Depends','Imports','LinkingTo','Suggests','SystemRequirements')
lines<-vapply(fields,function(k) {
 value<-if(k%in%colnames(d))gsub('[[:space:]]+',' ',d[1,k]) else ''
 paste0(k,': ',trimws(value))
},'')
writeLines(lines,a[2],useBytes=TRUE)
