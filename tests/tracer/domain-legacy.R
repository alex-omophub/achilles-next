# Comparable distinct-person subset only. Legacy record counts can multiply
# overlapping observation intervals and are deliberately not parity targets.
library(AchillesNext)
a<-commandArgs(TRUE);stopifnot(length(a)==3L)
lock<-jsonlite::fromJSON('tests/fixtures/domain-legacy-lock.json',simplifyVector=FALSE)
stopifnot(as.character(packageVersion('Achilles'))==lock$Achilles,as.character(packageVersion('SqlRender'))==lock$SqlRender)
e<-new.env();sys.source(a[1],e)
input<-jsonlite::fromJSON(a[2],simplifyVector=FALSE)[[3]]
out<-normalizePath(a[3],mustWork=TRUE)
c<-DatabaseConnector::connect(e$fixtureConnection('owner'))
main<-function() {
  on.exit(DatabaseConnector::disconnect(c),add=TRUE)
  ex<-function(sql)DatabaseConnector::executeSql(c,sql,progressBar=FALSE,reportOverallTime=FALSE,errorReportFile=file.path(out,'legacy-error.txt'))
  q<-function(sql)DatabaseConnector::querySql(c,sql,integer64AsNumeric=FALSE)
  guard<-q("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB=='achilles_next_fixtures',guard$MARKER=='AchillesNext synthetic fixture sandbox v1')
  lit<-get('.store_literal',asNamespace('AchillesNext'));wire<-get('.json',asNamespace('AchillesNext'))
  for(n in names(input$columns)) {
    defs<-paste(paste0('"',names(input$columns[[n]]),'" ',unlist(input$columns[[n]])),collapse=',')
    ex(paste0('CREATE TEMP TABLE "',n,'" (',defs,')'))
    if(length(input$tables[[n]]))ex(paste0('INSERT INTO "',n,'" SELECT * FROM jsonb_to_recordset(',lit(wire(input$tables[[n]])),'::jsonb) x(',defs,')'))
  }
  result<-list()
  for(id in names(lock$analyses)) {
    spec<-lock$analyses[[id]];path<-system.file(paste0('sql/sql_server/analyses/',id,'.sql'),package='Achilles',mustWork=TRUE)
    stopifnot(digest::digest(file=path,algo='sha256')==spec$sha256)
    sql<-SqlRender::translate(SqlRender::render(paste(readLines(path,warn=FALSE),collapse='\n'),cdmDatabaseSchema='pg_temp',scratchDatabaseSchema='#',schemaDelim='',tempAchillesPrefix='domain_legacy'),targetDialect='postgresql')
    for(statement in SqlRender::splitSql(sql))ex(statement)
    rows<-q(paste0('SELECT stratum_1, count_value::text AS n FROM domain_legacy_',id))
    result[[spec$domain]]<-lapply(seq_len(nrow(rows)),function(i)list(concept=if(is.na(rows$STRATUM_1[i]))NULL else rows$STRATUM_1[i],person_count=rows$N[i]))
  }
  jsonlite::write_json(list(lock=lock,counts=result),file.path(out,'legacy.json'),auto_unbox=TRUE,null='null',pretty=TRUE)
  cat('PASS: pinned legacy distinct-person subset executed for seven domains\n')
}
main()
