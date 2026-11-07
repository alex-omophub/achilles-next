# Real serving-only principal, approved bytes, and observed SQL boundary.
testSavedTransportIntegration <- function(directory,descriptor,details,serving,results,role,execute) {
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns)
  root<-f('.nv_json')(readBin(file.path(directory,'objects',paste0(descriptor$sha256,'.json')),'raw',n=262145L))
  context<-c(root[f('.saved_common')()],f('.object')(root=descriptor,authorization_epoch='1',instance_id='fixture-adapter'))
  allowed<-function(c)identical(c,context)
  artifact<-f('.saved_reader')(f('.saved_artifact_transport')(directory,context,allowed))
  database<-f('.saved_reader')(f('.saved_database_transport')(details,serving,context,allowed))
  on.exit({artifact$close();database$close()},add=TRUE)
  # Observe actual SQL submitted by these real transactions without changing it.
  original<-f('.store_transaction');statements<-character()
  observed<-function(details,schema,work,...)original(details,schema,function(tx) {
    one<-tx$one;tx$one<-function(sql){statements<<-c(statements,sql);one(sql)};work(tx)
  },...)
  environment(observed)<-environment()
  unlockBinding('.store_transaction',ns);assign('.store_transaction',observed,ns);lockBinding('.store_transaction',ns)
  on.exit({unlockBinding('.store_transaction',ns);assign('.store_transaction',original,ns);lockBinding('.store_transaction',ns)},add=TRUE)
  same<-function(left,right)stopifnot(identical(left$descriptor,right$descriptor),identical(left$bytes,right$bytes))
  same(artifact$root()$page,database$root()$page)
  total<-0L
  for(branch in c('data','metric_catalogue','concept_catalogue','terminology')) {
    left<-NULL;right<-NULL
    repeat {
      a<-artifact$scan(branch,limit=1L,cursor=left);b<-database$scan(branch,limit=1L,cursor=right)
      stopifnot(length(a$pages)==length(b$pages),identical(a$complete,b$complete))
      for(i in seq_along(a$pages)){same(a$pages[[i]],b$pages[[i]]);total<-total+1L}
      if(a$complete)break
      left<-a$cursor;right<-b$cursor
    }
  }
  stopifnot(total>0L,length(statements)==database$inspect()$fetched_objects,!database$inspect()$cache_allowed,database$inspect()$cache_bytes==0L)
  expected<-paste0(' FROM "',serving,'".achillesnext_approved_pages WHERE ')
  stopifnot(all(startsWith(statements,'SELECT encode(payload,\'hex\') FROM ')),all(grepl(expected,statements,fixed=TRUE)),
    !any(grepl('achillesnext_approved_current|achillesnext_aggregate_cell|cdm_',statements)))
  # No host callback change: the DB view itself must enforce revocation.
  revoke<-paste0('UPDATE "',results,'".achillesnext_audience_grant SET enabled=')
  where<-paste0(' WHERE scope_id=',f('.store_literal')(context$access_scope_id),' AND database_role=',f('.store_literal')(role))
  on.exit(execute(paste0(revoke,'true',where)),add=TRUE)
  execute(paste0(revoke,'false',where))
  denied<-tryCatch({database$root();NULL},error=identity)
  stopifnot(inherits(denied,'achillesnext_read_error'),denied$code=='unavailable',database$inspect()$cache_bytes==0L)
  stopifnot(length(artifact$root()$page$bytes)>0L)
  execute(paste0(revoke,'true',where));same(artifact$root()$page,database$root()$page)
  cat('SAVED_TRANSPORT_REAL_ARTIFACT_DATABASE_BYTES_SQL_ONLY_APPROVED_VIEW_REVOCATION_OK pages=',total,'statements=',length(statements),'\n')
}
