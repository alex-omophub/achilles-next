# Contributor input boundaries shared by the worker and small offline regressions.
.inventory_count <- function(value) {
  if(!is.numeric(value)||length(value)!=1L||is.na(value)||!is.finite(value)||
     value!=floor(value)||value<1||value>1000000)
    stop('Invalid inventory count',call.=FALSE)
  as.integer(value)
}
.inventory_reader_server <- function(host,database) {
  if(!is.character(host)||length(host)!=1L||is.na(host)||!nzchar(host)||grepl('[/\\\\\r\n]',host)||
     !identical(database,'achilles_next_fixtures'))stop('Invalid inventory reader target',call.=FALSE)
  paste0(host,'/',database)
}
