.term_extension_definition <- function(schema) {
  sql<-paste(readLines(system.file("sql/postgresql/result-store.sql",package="AchillesNext",mustWork=TRUE),warn=FALSE),collapse="\n")
  found<-regmatches(sql,regexpr("(?s)CREATE FUNCTION __STORE__[.]guard_publication_transition\\(\\).*?\\$publication\\$;",sql,perl=TRUE))
  .nv_need(length(found)==1L&&nzchar(found),"Missing installed publication guard")
  found<-gsub("__STORE__",schema,found,fixed=TRUE)
  old<-"IF root_doc->>'contract_version' IS DISTINCT FROM '2.0.0' OR"
  new<-"IF NOT COALESCE(root_doc->>'contract_version' IN ('2.0.0','2.1.0'),false) OR"
  .nv_need(lengths(regmatches(found,gregexpr(old,found,fixed=TRUE)))==1L)
  changed<-sub(old,new,found,fixed=TRUE)
  body<-function(x)strsplit(x,"$publication$",fixed=TRUE)[[1]][[2]]
  list(sql=sub("CREATE FUNCTION","CREATE OR REPLACE FUNCTION",changed,fixed=TRUE),old=body(found),new=body(changed))
}
.term_require_extension <- function(tx) {
  versions<-character();tx$stream(paste0("SELECT version FROM ",tx$schema,".achillesnext_storage_extension WHERE extension_id='saved-terminology'"),function(x)versions<<-c(versions,x))
  .nv_need(identical(versions,"1.0.0"),"Enable the saved terminology extension explicitly")
}
#' Explicitly enable physical 2.1.0 publications in an existing PostgreSQL store
#' @export
enableSavedTerminology <- function(connectionDetails,resultsSchema) {
  .store_transaction(connectionDetails,resultsSchema,function(tx) {
    .store_version(tx);def<-.term_extension_definition(tx$schema)
    tx$execute(paste0("LOCK TABLE ",tx$schema,".achillesnext_storage_version IN EXCLUSIVE MODE"))
    body<-tx$one(paste0("SELECT p.prosrc FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=",
      .store_literal(resultsSchema)," AND p.proname='guard_publication_transition' AND p.pronargs=0"))
    exists<-tx$one(paste0("SELECT (pg_catalog.to_regclass(",.store_literal(paste0(tx$schema,".achillesnext_storage_extension")),") IS NOT NULL)::text"))=="true"
    if(exists){.term_require_extension(tx);.nv_need(identical(body,def$new),"Modified publication guard; no repair attempted");return(invisible(FALSE))}
    .nv_need(identical(body,def$old),"Modified publication guard; no migration attempted")
    tx$execute(paste0("CREATE TABLE ",tx$schema,".achillesnext_storage_extension (extension_id text PRIMARY KEY CHECK(extension_id='saved-terminology'),version text NOT NULL CHECK(version='1.0.0')); INSERT INTO ",
      tx$schema,".achillesnext_storage_extension VALUES ('saved-terminology','1.0.0')"))
    tx$execute(def$sql);invisible(TRUE)
  })
}
