# Fresh serving-only process; no owner/runner credentials or source configuration.
library(AchillesNext)
args <- commandArgs(TRUE);stopifnot(length(args)==1L)
out <- normalizePath(args[[1]],mustWork=TRUE)
binding <- jsonlite::fromJSON(file.path(out,"binding.json"),simplifyVector=FALSE)
reader <- jsonlite::fromJSON(Sys.getenv("ACHILLES_NEXT_SERVING_FIXTURE"))
details <- DatabaseConnector::createConnectionDetails(dbms="postgresql",server="127.0.0.1/achilles_next_fixtures",port=as.integer(reader$port),user=reader$user,password=reader$password)
page <- function(d=NULL) readResultObject(details,binding$serving_schema,binding$source_id,binding$publication_id,binding$scope_id,binding$root_sha256,d)
root <- AchillesNext:::.nv_json(page());rows <- list()
walk <- function(d) {
  doc <- AchillesNext:::.nv_json(page(d))
  if(doc$kind=="index")for(child in doc$children)walk(child$object) else {
    stopifnot(doc$kind=="data");rows[[doc$metric_id]] <<- c(rows[[doc$metric_id]],doc$rows)
  }
}
walk(root$data)
jsonlite::write_json(rows,file.path(out,"saved-readback.json"),auto_unbox=TRUE,null="null",pretty=TRUE)
cat("REGISTERED_FRESH_SERVING_ONLY_READBACK_OK\n")
