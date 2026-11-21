# Real serving-only principal, approved bytes, and observed SQL boundary.
testSavedTransportIntegration <- function(directory,descriptor,details,serving,results,role,execute) {
  ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns)
  # An ordinary close error still propagates, and cleanup never replays the close.
  checkClose <- function(closeConnection, message=NULL) {
    con <- DatabaseConnector::connect(details)
    on.exit(if(!rJava::.jcall(con@jConnection, "Z", "isClosed")) DatabaseConnector::disconnect(con))
    attempts <- 0L
    close <- function(connection) {
      attempts <<- attempts + 1L
      if (closeConnection) DatabaseConnector::disconnect(connection)
      if (!is.null(message)) stop(message, call.=FALSE)
    }
    outcome <- tryCatch(f('.disconnect_approved_page_reader')(con, close), error=conditionMessage)
    stopifnot(attempts==1L)
    outcome
  }
  stopifnot(identical(checkClose(TRUE), TRUE),
            identical(checkClose(FALSE), "Approved page connection remained open"),
            identical(checkClose(TRUE, "Other disconnect error"), "Other disconnect error"),
            identical(checkClose(FALSE, "ignoring SIGPIPE signal"), "ignoring SIGPIPE signal"))
  root<-f('.nv_json')(readBin(file.path(directory,'objects',paste0(descriptor$sha256,'.json')),'raw',n=262145L))
  context<-c(root[f('.saved_common')()],f('.object')(root=descriptor,authorization_epoch='1',instance_id='fixture-adapter'))
  # The standalone reader still checks the host descriptor against the bytes from the view.
  wrongSize <- root$catalogue
  wrongSize$bytes <- "0"
  rejected <- tryCatch(readResultObject(details, serving, context$source_id, context$publication_id,
                                        context$access_scope_id, descriptor$sha256, wrongSize), error=identity)
  stopifnot(inherits(rejected, "error"), identical(conditionMessage(rejected), "Approved result page unavailable or invalid"))
  allowed<-function(c)identical(c,context)
  artifact<-f('.saved_reader')(f('.saved_artifact_transport')(directory,context,allowed))
  database<-f('.saved_reader')(f('.saved_database_transport')(details,serving,context,allowed))
  on.exit({artifact$close();database$close()},add=TRUE)
  # Observe actual SQL submitted by these real transactions without changing it.
  original<-f('.store_transaction');statements<-character();probe<-NULL
  observed<-function(details,schema,work,...)original(details,schema,function(tx) {
    one<-tx$one;tx$one<-function(sql) {
      statements<<-c(statements,sql)
      if(is.null(probe))one(sql) else probe(one,sql)
    }
    work(tx)
  },...)
  environment(observed)<-environment()
  unlockBinding('.store_transaction',ns);assign('.store_transaction',observed,ns);lockBinding('.store_transaction',ns)
  on.exit({unlockBinding('.store_transaction',ns);assign('.store_transaction',original,ns);lockBinding('.store_transaction',ns)},add=TRUE)
  same<-function(left,right)stopifnot(identical(left$descriptor,right$descriptor),identical(left$bytes,right$bytes))
  # PostgreSQL wraps encoded output at 76 columns. Exercise those actual bytes.
  probe <- function(one,sql) {
    value <- one(sql)
    stopifnot(grepl("\n",value,fixed=TRUE))
    value
  }
  same(artifact$root()$page,database$root()$page)
  probe <- NULL
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
  fileProvider<-openArtifactResultProvider(directory,context,allowed)
  dbProvider<-openDatabaseResultProvider(details,serving,context,allowed)
  on.exit({fileProvider$close();dbProvider$close()},add=TRUE)
  semanticSame<-function(a,b) {
    a$cursor<-NULL;b$cursor<-NULL;a$budget<-NULL;b$budget<-NULL
    stopifnot(identical(f('.json')(a),f('.json')(b)))
  }
  left<-NULL;right<-NULL;discovered<-character()
  repeat {
    a<-fileProvider$listMetrics(limit=17L,cursor=left);b<-dbProvider$listMetrics(limit=17L,cursor=right)
    semanticSame(a,b);discovered<-c(discovered,vapply(a$metrics,function(m)m$metric_id,''))
    if(a$complete)break
    left<-a$cursor;right<-b$cursor
  }
  stopifnot(length(discovered)==142L,!anyDuplicated(discovered))
  for(request in list(list(metricId='core.person.count'),list(metricId='core.person.gender_count'),
      list(metricId='core.measurement.numeric_summary'),list(metricId='observed.condition.capture_count'),
      list(metricId='core.visit.care_setting_count'),list(metricId='core.drug.capture_count'),
      list(metricId='core.person.gender_count',filters=list(gender_concept_id='8507')),
      list(metricId='core.condition.capture_count',rowKind='summary'))) {
    semanticSame(do.call(fileProvider$selectSavedRows,request),do.call(dbProvider$selectSavedRows,request))
  }
  left<-NULL;right<-NULL;summaryKeys<-character()
  repeat {
    a<-fileProvider$selectSavedRows('core.measurement.numeric_summary',maxRows=1L,cursor=left)
    b<-dbProvider$selectSavedRows('core.measurement.numeric_summary',maxRows=1L,cursor=right)
    semanticSame(a,b);summaryKeys<-c(summaryKeys,vapply(a$rows,function(r)r$row_key,''))
    if(a$complete)break
    left<-a$cursor;right<-b$cursor
  }
  measured<-fileProvider$selectSavedRows('core.measurement.numeric_summary',maxRows=1L)
  byteLimit<-length(f('.v2_bytes')(measured))+16L
  left<-NULL;right<-NULL;byteKeys<-character();bytePages<-0L
  repeat {
    a<-fileProvider$selectSavedRows('core.measurement.numeric_summary',maxBytes=byteLimit,cursor=left)
    b<-dbProvider$selectSavedRows('core.measurement.numeric_summary',maxBytes=byteLimit,cursor=right)
    semanticSame(a,b)
    stopifnot(length(f('.v2_bytes')(a))<=byteLimit,length(f('.v2_bytes')(b))<=byteLimit)
    byteKeys<-c(byteKeys,vapply(a$rows,function(r)r$row_key,''));bytePages<-bytePages+1L
    if(a$complete)break
    left<-a$cursor;right<-b$cursor
  }
  stopifnot(bytePages>1L,identical(byteKeys,summaryKeys))
  savedConcepts<-artifact$scan('concept_catalogue',limit=1L)$pages[[1]]$document$entries
  knownId<-savedConcepts[[1]]$concept_tag$value
  lookupIds<-unique(c(knownId,'0','-1','9007199254740993'))
  left<-NULL;right<-NULL;lookupCount<-0L
  repeat {
    a<-fileProvider$lookupConcepts(lookupIds,limit=1L,cursor=left)
    b<-dbProvider$lookupConcepts(lookupIds,limit=1L,cursor=right)
    semanticSame(a,b);lookupCount<-lookupCount+length(a$concepts)
    if(a$complete)break
    left<-a$cursor;right<-b$cursor
  }
  stopifnot(lookupCount==length(lookupIds),fileProvider$lookupConcepts(knownId)$concepts[[1]]$state=='available')
  for(query in c('Diabetes','β blocker',"x%_'; SELECT * FROM person; --")) {
    a<-fileProvider$searchConcepts(query);b<-dbProvider$searchConcepts(query);semanticSame(a,b)
    stopifnot(a$state=='unavailable',!a$searched,b$budget$objects==1L)
  }
  stopifnot(length(summaryKeys)==2L,!anyDuplicated(summaryKeys),dbProvider$inspect()$cache_bytes==0L,
    length(statements)==database$inspect()$fetched_objects+dbProvider$inspect()$fetched_objects)
  cat('SAVED_SEMANTIC_PROVIDER_REAL_142_METRICS_ROWS_DEPENDENCIES_PAGINATION_PARITY_OK\n')
  expected<-paste0(' FROM "',serving,'".achillesnext_approved_pages WHERE ')
  stopifnot(all(startsWith(statements,'SELECT encode(payload,\'base64\') FROM ')),all(grepl(expected,statements,fixed=TRUE)),
    !any(grepl('achillesnext_approved_current|achillesnext_aggregate_cell|cdm_',statements)))
  # No host callback change: the DB view itself must enforce revocation.
  revoke<-paste0('UPDATE "',results,'".achillesnext_audience_grant SET enabled=')
  where<-paste0(' WHERE scope_id=',f('.store_literal')(context$access_scope_id),' AND database_role=',f('.store_literal')(role))
  on.exit(execute(paste0(revoke,'true',where)),add=TRUE)
  execute(paste0(revoke,'false',where))
  denied<-tryCatch({database$root();NULL},error=identity)
  stopifnot(inherits(denied,'achillesnext_read_error'),denied$code=='unavailable',database$inspect()$cache_bytes==0L)
  denied<-tryCatch({dbProvider$listMetrics();NULL},error=identity)
  stopifnot(inherits(denied,'achillesnext_read_error'),denied$code=='unavailable',dbProvider$inspect()$cache_bytes==0L)
  for(work in list(function()dbProvider$lookupConcepts(knownId),function()dbProvider$searchConcepts('x'))) {
    denied<-tryCatch({work();NULL},error=identity)
    stopifnot(inherits(denied,'achillesnext_read_error'),denied$code=='unavailable',dbProvider$inspect()$cache_bytes==0L)
  }
  stopifnot(fileProvider$listMetrics(limit=1L)$state=='available')
  stopifnot(length(artifact$root()$page$bytes)>0L)
  execute(paste0(revoke,'true',where));same(artifact$root()$page,database$root()$page)
  # JDBC close can return just before the backend disappears from pg_stat_activity.
  waitClosed <- function(pids) {
    deadline <- Sys.time()+5
    repeat {
      active <- original(details,serving,function(tx)tx$one(paste0(
        "SELECT count(*)::text FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND pid IN (",
        paste(unique(pids),collapse=","),")")),readOnly=TRUE)
      if(identical(active,"0")) return(invisible(TRUE))
      if(Sys.time()>=deadline) stop("Serving backend remained active after the request")
      Sys.sleep(0.025)
    }
  }
  # Observe committed grants through the live view on each page, even when the
  # host callback keeps approving and the reader reuses the same connection.
  pids <- character()
  probe <- function(one,sql) {
    pids <<- c(pids,one("SELECT pg_backend_pid()::text"))
    stopifnot(one("SELECT current_setting('transaction_read_only')")=="on")
    value <- one(sql)
    if(length(pids)==1L) execute(paste0(revoke,'false',where))
    value
  }
  denied <- tryCatch(database$scan('data'),error=identity)
  stopifnot(inherits(denied,'achillesnext_read_error'),denied$code=='unavailable',
    length(pids)==2L,pids[[1L]]==pids[[2L]],database$inspect()$cache_bytes==0L)
  execute(paste0(revoke,'true',where))
  waitClosed(pids)
  # A reentrant operation gets its own session, then the outer read resumes
  # on its original connection. Neither connection survives the operation.
  pids <- character()
  probe <- function(one,sql) {
    pids <<- c(pids,one("SELECT pg_backend_pid()::text"))
    value <- one(sql)
    if(length(pids)==1L) database$root()
    value
  }
  database$scan('data')
  probe <- NULL
  stopifnot(length(pids)>=3L,pids[[1L]]!=pids[[2L]],all(pids[-2L]==pids[[1L]]))
  waitClosed(pids)
  # An authorized query can succeed and its final disconnect still fail.
  # The response must be discarded and the driver error kept private.
  realClose <- f('.disconnect_approved_page_reader')
  closes <- 0L
  failingClose <- function(con) {
    realClose(con)
    closes <<- closes+1L
    stop("private fixture error after disconnect",call.=FALSE)
  }
  generation <- database$inspect()$generation
  assignInNamespace('.disconnect_approved_page_reader',failingClose,ns='AchillesNext')
  on.exit(assignInNamespace('.disconnect_approved_page_reader',realClose,ns='AchillesNext'),add=TRUE)
  failed <- tryCatch(database$root(),error=identity)
  cancelled <- FALSE
  probe <- function(one,sql) {
    value <- one(sql)
    cancelled <<- TRUE
    value
  }
  aborted <- tryCatch(database$root(function()cancelled),error=identity)
  stopifnot(closes==2L,inherits(aborted,'achillesnext_read_error'),aborted$code=='aborted',
    inherits(failed,'achillesnext_read_error'),failed$code=='unavailable',
    !grepl("private fixture error",conditionMessage(failed),fixed=TRUE),
    database$inspect()$generation==generation+2L)
  cat('SAVED_CONCEPT_REAL_LOOKUP_PAGINATION_UNAVAILABLE_SEARCH_PARITY_REVOCATION_OK\n')
  cat('SAVED_TRANSPORT_REAL_ARTIFACT_DATABASE_BYTES_SQL_ONLY_APPROVED_VIEW_REVOCATION_OK pages=',total,'statements=',length(statements),'\n')
}
