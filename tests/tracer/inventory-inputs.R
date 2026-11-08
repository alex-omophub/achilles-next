source('tools/benchmark/inventory-inputs.R')
for(value in list(1L,96,1000000L,jsonlite::fromJSON('1000000'),jsonlite::fromJSON('1e6'))) {
  count<-.inventory_count(value)
  stopifnot(is.integer(count),identical(as.character(count),sprintf('%d',count)))
}
stopifnot(identical(.inventory_count(1e6),1000000L),
  identical(.inventory_reader_server('localhost','achilles_next_fixtures'),'localhost/achilles_next_fixtures'),
  identical(.inventory_reader_server('127.0.0.2','achilles_next_fixtures'),'127.0.0.2/achilles_next_fixtures'))
for(value in list(NULL,NA_real_,Inf,NaN,0,-1,1.5,1000001,TRUE,'1000000',c(1,2))) {
  error<-tryCatch({.inventory_count(value);NULL},error=identity)
  stopifnot(inherits(error,'error'),identical(conditionMessage(error),'Invalid inventory count'))
}
for(host in c('','/tmp','host/path','host\\path','host\nname')) {
  error<-tryCatch({.inventory_reader_server(host,'achilles_next_fixtures');NULL},error=identity)
  stopifnot(inherits(error,'error'),identical(conditionMessage(error),'Invalid inventory reader target'))
}
cat('INVENTORY_INTEGER_COUNTS_SCIENTIFIC_INPUT_AND_SELECTED_READER_HOST_OK\n')
