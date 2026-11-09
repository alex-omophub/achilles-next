# Install a topologically ordered, checksummed source closure without dependency resolution.
lib<-Sys.getenv('R_LIBS');dir.create(lib,recursive=TRUE,showWarnings=FALSE);.libPaths(c(lib,.libPaths()))
install<-function(path) {
  status<-system2(file.path(R.home('bin'),'R'),c('CMD','INSTALL','--no-multiarch',paste0('--library=',shQuote(lib)),shQuote(path)))
  if(status!=0L)stop('Pinned R source installation failed: ',basename(path))
}
bootstrap<-list.files('/opt/validation/downloads',pattern='^jsonlite_.*[.]tar[.]gz$',full.names=TRUE)
stopifnot(length(bootstrap)==1L);install(bootstrap)
lock<-jsonlite::fromJSON('/opt/validation/runtime-lock.json',simplifyVector=FALSE)
pending<-lock$R_packages;done<-character()
while(length(pending)) {
  ready<-vapply(pending,function(p)all(unlist(p$dependencies)%in%done),TRUE)
  stopifnot(any(ready))
  for(p in pending[ready]) {
    if(p$name!='jsonlite')install(file.path('/opt/validation/downloads',paste0(p$name,'_',p$version,'.tar.gz')))
    stopifnot(identical(utils::packageDescription(p$name)$Version,p$version))
    done<-c(done,p$name)
  }
  pending<-pending[!ready]
}
tuple<-jsonlite::fromJSON('/opt/validation/runtime-lock.json',simplifyVector=FALSE)
stopifnot(identical(as.character(getRversion()),'4.2.3'))
rJava::.jinit()
stopifnot(startsWith(rJava::.jcall('java/lang/System','S','getProperty','java.version'),'11.'))
stopifnot(identical(digest::digest(file=file.path(Sys.getenv('DATABASECONNECTOR_JAR_FOLDER'),tuple$jdbc$file),algo='sha256'),tuple$jdbc$sha256))
