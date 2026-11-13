# Small-fixture proof guards; no installed package or large-run authority.
streamCheckSource<-function(streamDir) {
  paths<-file.path(streamDir,c('STOP','dropped.json','active','active.json'))
  links<-Sys.readlink(paths)
  stopifnot(dir.exists(streamDir),!any(file.exists(paths)|(!is.na(links)&nzchar(links))))
}

streamVerifySource<-function(handoff,query) {
  # Schema names come from the inspected handoff; table names are compiled CDM
  # names. The bounded proof checks counts/grants, not a hash of every row value.
  schema<-handoff$source_schema
  stopifnot(grepl('^cdm_stream_[0-9a-f]{16}$',schema))
  grants<-query(paste0("SELECT has_schema_privilege('achilles_next_runner','",schema,
    "','USAGE')::text AS can_read, has_schema_privilege('achilles_next_runner','",schema,"','CREATE')::text AS can_create"))
  stopifnot(identical(grants$CAN_READ,'true'),identical(grants$CAN_CREATE,'false'))
  counts<-list()
  for(table in names(handoff$table_rows)) {
    stopifnot(grepl('^[a-z][a-z0-9_]*$',table))
    relation<-paste0('"',schema,'"."',table,'"')
    facts<-query(paste0("SELECT count(*)::text AS n, has_table_privilege('achilles_next_runner','",
      relation,"','SELECT')::text AS can_read FROM ",relation))
    stopifnot(identical(facts$N,as.character(handoff$table_rows[[table]])),identical(facts$CAN_READ,'true'))
    counts[[table]]<-facts$N
  }
  list(table_rows=counts,reader_usage=TRUE,reader_create=FALSE,reader_select=TRUE)
}

streamCleanup<-function(actions,completed) {
  failures<-character()
  for(action in actions)tryCatch(action(),error=function(e){failures<<-c(failures,conditionMessage(e))})
  if(length(failures)) {
    msg<-paste0('Stream analysis fixture cleanup failed: ',paste(failures,collapse='; '))
    # A message cannot become an error through options(warn=2). Preserve the
    # original analysis condition while retaining all cleanup failures in logs.
    if(completed)stop(msg) else message(msg)
  }
}
