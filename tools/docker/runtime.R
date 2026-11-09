# Validate the image's actual R/JNI/JDBC tuple before any fixture work.
args<-commandArgs(TRUE);stopifnot(length(args)==1L)
lock<-jsonlite::fromJSON('/opt/validation/runtime-lock.json',simplifyVector=FALSE)
tuple<-jsonlite::fromJSON('tests/tracer/runtime-lock.json',simplifyVector=FALSE)
stopifnot(identical(as.character(getRversion()),tuple$r))
versions<-list()
for(p in lock$R_packages) {
  actual<-utils::packageDescription(p$name)$Version;stopifnot(identical(actual,p$version));versions[[p$name]]<-actual
}
stopifnot(identical(versions$DatabaseConnector,tuple$DatabaseConnector))
rJava::.jinit();java<-rJava::.jcall('java/lang/System','S','getProperty','java.version')
stopifnot(startsWith(java,paste0(tuple$java,'.')))
jdbc<-file.path(Sys.getenv('DATABASECONNECTOR_JAR_FOLDER'),tuple$jdbc_file)
stopifnot(identical(digest::digest(file=jdbc,algo='sha256'),tuple$jdbc_sha256))
source('tools/benchmark/implementation_identity.R');identity<-implementationIdentity('.')
writeLines(jsonlite::toJSON(list(R=as.character(getRversion()),Java=java,R_packages=versions,jdbc_sha256=tuple$jdbc_sha256,implementation=identity),auto_unbox=TRUE,null='null'),args[1])
