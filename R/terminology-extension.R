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
  present<-tx$one(paste0("SELECT (pg_catalog.to_regclass(",.store_literal(paste0(tx$schema,".achillesnext_storage_extension")),") IS NOT NULL)::text"))
  .nv_need(identical(present,"true"),"Enable the saved terminology extension explicitly")
  versions<-character();tx$stream(paste0("SELECT version FROM ",tx$schema,".achillesnext_storage_extension WHERE extension_id='saved-terminology'"),function(x)versions<<-c(versions,x))
  .nv_need(identical(versions,"1.0.0"),"Enable the saved terminology extension explicitly")
}
#' Explicitly enable physical 2.1.0 publications in an existing PostgreSQL store
#' @export
enableSavedTerminology <- function(connectionDetails,resultsSchema) {
  .store_transaction(connectionDetails,resultsSchema,function(tx) {
    tx$execute(paste0("LOCK TABLE ",tx$schema,".achillesnext_storage_version IN EXCLUSIVE MODE"))
    .store_version(tx);def<-.term_extension_definition(tx$schema)
    # Hold the relation lock while checking and replacing the guard so trigger
    # DDL cannot invalidate this check. Both first/repeated calls must enforce it.
    tx$execute(paste0("LOCK TABLE ",tx$schema,".achillesnext_publication IN SHARE ROW EXCLUSIVE MODE"))
    binding<-tx$one(paste0("SELECT count(*)::text FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid JOIN pg_catalog.pg_namespace f ON f.oid=p.pronamespace WHERE n.nspname=",
      .store_literal(resultsSchema)," AND c.relname='achillesnext_publication' AND t.tgname='publication_transition' AND NOT t.tgisinternal AND t.tgenabled IN ('O','A') AND t.tgtype=23 AND t.tgnargs=0 AND t.tgqual IS NULL AND t.tgattr=''::pg_catalog.int2vector AND f.nspname=",
      .store_literal(resultsSchema)," AND p.proname='guard_publication_transition' AND p.pronargs=0 AND p.prorettype='pg_catalog.trigger'::pg_catalog.regtype"))
    .nv_need(identical(binding,"1"),"Modified publication trigger; no migration or repair attempted")
    # The relation lock above protects trigger DDL, not pg_proc updates. A
    # same-cost owner ALTER takes the catalog tuple write lock until commit;
    # only then read the body. Direct SELECT FOR UPDATE on pg_proc would require
    # catalog UPDATE privileges, which the store owner must not need.
    cost<-tx$one(paste0("SELECT p.procost::text FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=",
      .store_literal(resultsSchema)," AND p.proname='guard_publication_transition' AND p.pronargs=0"))
    .nv_need(grepl("^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$",cost)&&is.finite(as.numeric(cost))&&as.numeric(cost)>0,
      "Invalid publication guard cost; no migration or repair attempted")
    tx$execute(paste0("ALTER FUNCTION ",tx$schema,".guard_publication_transition() COST ",cost))
    body<-tx$one(paste0("SELECT p.prosrc FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=",
      .store_literal(resultsSchema)," AND p.proname='guard_publication_transition' AND p.pronargs=0"))
    exists<-tx$one(paste0("SELECT (pg_catalog.to_regclass(",.store_literal(paste0(tx$schema,".achillesnext_storage_extension")),") IS NOT NULL)::text"))=="true"
    if(exists){.term_require_extension(tx);.nv_need(identical(body,def$new),"Modified publication guard; no repair attempted");return(invisible(FALSE))}
    .nv_need(identical(body,def$old),"Modified publication guard; no migration attempted")
    tx$execute(paste0("CREATE TABLE ",tx$schema,".achillesnext_storage_extension (extension_id text PRIMARY KEY CHECK(extension_id='saved-terminology'),version text NOT NULL CHECK(version='1.0.0')); INSERT INTO ",
      tx$schema,".achillesnext_storage_extension VALUES ('saved-terminology','1.0.0')"))
    tx$execute(def$sql);invisible(TRUE)
  },isolation=2L) # READ COMMITTED: a waiter sees the committed capability/guard.
}
