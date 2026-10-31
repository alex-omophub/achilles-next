# Small deliberately synthetic full-inventory store fixture. This tests storage
# and publication, not domain generation or a claim about full-source coverage.
library(AchillesNext)
local({
  args <- commandArgs(TRUE);stopifnot(length(args)==2L)
  config <- new.env();sys.source(args[[1]],config);details <- config$fixtureConnection('owner')
  ns <- asNamespace('AchillesNext');f <- function(name)get(name,ns)
  obj <- f('.object');json <- f('.json');wire <- f('.v2_bytes');hash <- f('.v2_hash')
  schema <- paste0('export_test_',Sys.getpid());serve <- paste0('export_serve_',Sys.getpid())
  conn <- DatabaseConnector::connect(details);on.exit(DatabaseConnector::disconnect(conn),add=TRUE)
  q <- function(sql)DatabaseConnector::querySql(conn,sql)
  ex <- function(sql)DatabaseConnector::executeSql(conn,sql,progressBar=FALSE,reportOverallTime=FALSE)
  guard <- q("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(guard$DB=='achilles_next_fixtures',guard$MARKER=='AchillesNext synthetic fixture sandbox v1')
  initializeResultStore(details,schema,serve,'cdm_tiny_a_55')
  on.exit(ex(paste0('DROP SCHEMA ',serve,' CASCADE; DROP SCHEMA ',schema,' CASCADE')),add=TRUE,after=FALSE)
  lit <- f('.store_literal');sqlJson <- function(x)paste0(lit(json(x)),'::jsonb')
  ids <- sprintf('10000000-0000-4000-8000-%012d',1:5);release <- ids[[3]]
  assets <- f('.v2_assets')()
  ex(paste0("INSERT INTO ",schema,".source_release VALUES (",lit(ids[[1]]),",'fixture:export','{}','{}',repeat('a',64),'5.5',now());",
    "INSERT INTO ",schema,".analysis_run(run_id,source_release_id,request_sha256,profile_id,profile_revision,profile_sha256,state,consistency_basis) VALUES (",lit(ids[[2]]),",",lit(ids[[1]]),",repeat('b',64),'core-characterization-v2','2.0.0',",lit(assets$hash),",'succeeded','single_repeatable_read');",
    "INSERT INTO ",schema,".result_release VALUES (",lit(release),",",lit(ids[[2]]),",'building',142,0,null)"))
  active <- c('core.person.count','core.person.gender_count','core.measurement.numeric_summary','core.visit.care_setting_count','core.source.passport','core.source.capabilities','core.execution.output_status','core.execution.timing')
  makeRow <- function(mid,kind,dims,values,state='computed',reason=NULL) {
    r <- obj(row_key='',dimensions=dims,row_kind=kind,state=state,reason_code=reason,values=values,denominator_refs=list())
    r$row_key <- f('.v2_row_identity')(assets$rows[[mid]],r);r
  }
  huge <- '9007199254740993'
  person <- makeRow('core.person.count','counts',obj(),obj(person_count=huge))
  gender <- makeRow('core.person.gender_count','counts',obj(gender_concept_id='0'),obj(person_count=huge))
  gender$denominator_refs <- list(obj(measure='person_count',metric_id='core.person.count',row_key=person$row_key,field='person_count',value=huge))
  dims <- obj(concept_tag=obj(kind='id',value='123'),unit_concept_tag=obj(kind='id',value='456'),raw_operator_tag=obj(kind='null'))
  summary <- makeRow('core.measurement.numeric_summary','summary',dims,obj(n='6',sum='20.5',min='1',max='10',mean_numerator='20.5',mean_denominator='6',p10='1',p25='2',p50='2.5',p75='2.5',p90='10'))
  eligible <- makeRow('core.measurement.numeric_summary','eligibility_counts',c(dims,obj(eligibility_reason='eligible')),obj(record_count='6'))
  emptyDims <- dims;emptyDims$unit_concept_tag <- obj(kind='id',value='777')
  emptySummary <- makeRow('core.measurement.numeric_summary','summary',emptyDims,obj(n='0',sum=NULL,min=NULL,max=NULL,mean_numerator=NULL,mean_denominator=NULL,p10=NULL,p25=NULL,p50=NULL,p75=NULL,p90=NULL),'empty_population','fixture.no_eligible')
  emptyEligible <- makeRow('core.measurement.numeric_summary','eligibility_counts',c(emptyDims,obj(eligibility_reason='eligible')),obj(record_count='0'),'empty_population','fixture.no_eligible')
  marginal <- makeRow('core.visit.care_setting_count','counts',obj(concept_tag=obj(kind='id',value='1'),setting_kind='place_of_service',setting_concept_tag=obj(kind='schema_absent')),NULL,'unavailable','capability.care_site_absent')
  rows <- list('core.person.count'=list(person),'core.person.gender_count'=list(gender),'core.measurement.numeric_summary'=list(summary,eligible,emptySummary,emptyEligible),'core.visit.care_setting_count'=list(marginal))
  unknown <- obj(state='unknown',value=NULL,basis=NULL,assertion_id=NULL,reason_code='fixture.unknown')
  coverage <- obj(scope_kind='standard_full',complete=TRUE,excluded_record_count='0',reason_code=NULL)
  rows[['core.source.passport']] <- list(makeRow('core.source.passport','metadata',obj(),obj(source_id='fixture:export',source_release=unknown,declared_cdm_version='5.5',observed_schema=obj(sha256=strrep('a',64),reason_code=NULL),vocabulary_release=unknown,profile=obj(id='core-characterization-v2',revision='2.0.0',sha256=assets$hash),coverage=coverage,generation=obj(started_at='2026-01-01T00:00:00.000Z',ended_at='2026-01-01T00:00:00.000Z'),consistency=obj(within_run='single_repeatable_read',reusable=FALSE,reason_code='fixture.unknown'))))
  probes <- unique(unlist(lapply(assets$metrics,function(m)c(unlist(m$inputs),unlist(m$conditional_inputs),unlist(m$input_aliases)))))
  rows[['core.source.capabilities']] <- lapply(probes,function(probe)makeRow('core.source.capabilities','metadata',obj(probe_id=probe),if(startsWith(probe,'care_site.'))obj(state='absent',reason_code='capability.synthetic_absent',observed_type=NULL) else obj(state='available',reason_code=NULL,observed_type='synthetic')))
  rows[['core.execution.timing']] <- list(makeRow('core.execution.timing','metadata',obj(operation_id='fixture',phase='aggregation'),obj(duration_ms=NULL,telemetry=obj(cpu_ms=NULL,peak_memory_bytes=NULL,source_rows=NULL,temp_bytes=NULL),availability='unavailable',reason_code='fixture.not_measured')))
  rows[['core.execution.output_status']] <- lapply(names(assets$metrics),function(mid)makeRow('core.execution.output_status','metadata',obj(metric_id=mid),obj(state=if(mid%in%active)'computed' else 'suppressed',reason_code=if(mid%in%active)NULL else 'fixture.policy_suppressed',required=TRUE,coverage=coverage,integrity=obj(state='not_validated',sha256=NULL,reason_code='fixture.pending'))))
  expectedCells <- as.character(sum(vapply(rows,length,1L)))
  for(mid in names(assets$metrics)) {
    m <- assets$metrics[[mid]];r <- assets$rows[[mid]];n <- length(rows[[mid]])
    ex(paste0('INSERT INTO ',schema,'.dataset VALUES (',lit(release),',',lit(mid),',',lit(m$version),',',lit(m$population),',',lit(m$grain),',',lit(r$row_schema_id),',',lit(hash(wire(m))),',',lit(if(n)'computed' else 'suppressed'),',',if(n)'NULL' else "'fixture.policy_suppressed'",",true,'{\"state\":\"supported\",\"reason_code\":null}',",n,",'{\"scope_kind\":\"standard_full\",\"complete\":true,\"excluded_record_count\":\"0\",\"reason_code\":null}')"))
    for(row in rows[[mid]]) {
      values <- row$values;key <- f('.v2_sort')(r,row);f('.v2_row')(mid,row)
      cols <- c(record_count='record_count',person_count='person_count',person_days='person_days',interval_count='interval_count',n='n',sum='sum_value',min='minimum',max='maximum',p10='p10',p25='p25',p50='p50',p75='p75',p90='p90')
      cols <- if(row$row_kind=='metadata')c(metadata='metadata_value') else cols[names(cols)%in%names(values)]
      ex(paste0('INSERT INTO ',schema,'.aggregate_cell(release_id,metric_id,row_key,route_key,sort_key,dimensions,state,reason_code,payload_kind',if(length(cols))paste0(',',paste(cols,collapse=',')) else '',') VALUES (',paste(c(lit(release),lit(mid),lit(row$row_key),"'A'",lit(key),sqlJson(row$dimensions),lit(row$state),if(is.null(row$reason_code))'NULL' else lit(row$reason_code),lit(if(row$row_kind=='eligibility_counts')'counts' else row$row_kind),vapply(names(cols),function(k)if(k=='metadata')sqlJson(values) else if(is.null(values[[k]]))'NULL' else values[[k]],'')),collapse=','),')'))
    }
  }
  ex(paste0('INSERT INTO ',schema,'.denominator_edge VALUES (',paste(vapply(c(release,'core.person.gender_count',gender$row_key,'person_count','core.person.count',person$row_key,'person_count'),lit,''),collapse=','),')'))
  sealResultRelease(details,schema,release)
  # Internal exception details only in tests, to locate a broken invariant.
  f('.store_transaction')(details,schema,function(tx)f('.store_validate')(tx,release))
  validateResultRelease(details,schema,release)
  stopifnot(dir.create(args[[2]],mode='0700'));root <- normalizePath(args[[2]])
  allow <- obj(id='fixture-review',revision='1',scope_kind='restricted',allow_metrics=as.list(active))
  approved <- publishResultRelease(details,schema,release,file.path(root,'restricted'),'fixture-restricted','review-1',allow,function(candidate)TRUE,'0')
  validateResultArtifact(approved$export_dir)
  stopifnot(approved$revision=='1')
  # Exact stored bytes equal exported bytes for every approved object.
  f('.v2_directory')(approved$export_dir,function(d,bytes) {
    stored <- q(paste0("SELECT encode(payload,'hex') AS value FROM ",schema,".page_object WHERE publication_id=",lit(approved$publication_id),' AND sha256=',lit(d$sha256)))$VALUE
    stopifnot(stored==paste(sprintf('%02x',as.integer(bytes)),collapse=''))
  })
  # A dedicated principal has only serving-view access; it cannot read the CDM
  # or restricted aggregate store. Credentials remain in an ephemeral local file.
  readerFile <- Sys.getenv('ACHILLES_NEXT_SERVING_FIXTURE')
  if(nzchar(readerFile)) {
    reader <- jsonlite::fromJSON(readerFile,simplifyVector=FALSE)
    role <- reader$user;stopifnot(grepl('^achilles_test_reader_[0-9a-f]+$',role))
    ex(paste0('GRANT USAGE ON SCHEMA ',serve,' TO ',role,'; GRANT SELECT ON ',serve,'.approved_pages,',serve,'.approved_current TO ',role,
      '; INSERT INTO ',schema,".audience_grant VALUES ('fixture-restricted','",role,"',true)"))
    readDetails <- DatabaseConnector::createConnectionDetails(dbms='postgresql',server='127.0.0.1/achilles_next_fixtures',port=as.integer(reader$port),user=role,password=reader$password)
    raw <- readResultObject(readDetails,serve,'fixture:export',approved$publication_id,'fixture-restricted',approved$root$sha256)
    stopifnot(identical(raw,readBin(file.path(approved$export_dir,'objects',paste0(approved$root$sha256,'.json')),'raw',n=262145L)))
    f('.v2_directory')(approved$export_dir,function(d,bytes) {
      returned <- readResultObject(readDetails,serve,'fixture:export',approved$publication_id,'fixture-restricted',approved$root$sha256,if(d$kind=='root')NULL else d)
      stopifnot(identical(returned,bytes))
    })
    rconn <- DatabaseConnector::connect(readDetails)
    denied <- function(sql)stopifnot(tryCatch({DatabaseConnector::querySql(rconn,sql);FALSE},error=function(e)TRUE))
    denied('SELECT * FROM cdm_tiny_a_55.person LIMIT 1')
    denied(paste0('SELECT * FROM ',schema,'.aggregate_cell LIMIT 1'))
    DatabaseConnector::disconnect(rconn)
    ex(paste0("UPDATE ",schema,".audience_grant SET enabled=false WHERE database_role='",role,"'"))
    stopifnot(tryCatch({readResultObject(readDetails,serve,'fixture:export',approved$publication_id,'fixture-restricted',approved$root$sha256);FALSE},error=function(e)TRUE))
    cat('SERVING_PRINCIPAL_READ_DENIAL_AND_REVOCATION_OK\n')
  }
  before <- q(paste0('SELECT publication_id::text AS id FROM ',schema,'.current_publication'))$ID
  fail <- function(work)stopifnot(tryCatch({work();FALSE},error=function(e)TRUE))
  fail(function()publishResultRelease(details,schema,release,file.path(root,'denied'),'fixture-restricted','denied',allow,function(candidate)FALSE,'1'))
  fail(function()publishResultRelease(details,schema,release,file.path(root,'stale'),'fixture-restricted','stale',allow,function(candidate)TRUE,'0'))
  stopifnot(!dir.exists(file.path(root,'denied')),!dir.exists(file.path(root,'stale')),q(paste0('SELECT publication_id::text AS id FROM ',schema,'.current_publication'))$ID==before)
  # Fail immediately before COMMIT, after pages, export and tentative CAS.
  # Error and cancellation must roll back the pointer and remove our export.
  originalCommit <- f('.store_commit')
  for(mode in c('error','interrupt')) {
    assignInNamespace('.store_commit',function(jdbc) {
      if(mode=='interrupt')stop(structure(list(message='fixture cancellation',call=NULL),class=c('interrupt','condition')))
      stop('fixture commit failure')
    },ns='AchillesNext')
    rejected <- tryCatch({publishResultRelease(details,schema,release,file.path(root,paste0('commit-',mode)),'fixture-restricted','commit-fault',allow,function(candidate)TRUE,'1');FALSE},error=function(e)TRUE,interrupt=function(e)TRUE)
    assignInNamespace('.store_commit',originalCommit,ns='AchillesNext')
    stopifnot(rejected,!dir.exists(file.path(root,paste0('commit-',mode))),q(paste0('SELECT publication_id::text AS id FROM ',schema,'.current_publication'))$ID==before)
  }
  cat('PRECOMMIT_FAILURE_AND_CANCELLATION_PRESERVE_CURRENT_OK\n')
  # Independent runs/releases can hold identical row identities without
  # overwriting one another. Race their complete publishers at one revision.
  secondRun <- ids[[4]];secondRelease <- ids[[5]]
  ex(paste0('INSERT INTO ',schema,'.analysis_run SELECT (jsonb_populate_record(NULL::',schema,'.analysis_run,to_jsonb(a)||jsonb_build_object(\'run_id\',',lit(secondRun),'))).* FROM ',schema,'.analysis_run a WHERE run_id=',lit(ids[[2]])))
  ex(paste0('INSERT INTO ',schema,'.result_release VALUES (',lit(secondRelease),',',lit(secondRun),",'building',142,0,null)"))
  for(table in c('dataset','aggregate_cell','denominator_edge')) ex(paste0('INSERT INTO ',schema,'.',table,' SELECT (jsonb_populate_record(NULL::',schema,'.',table,',to_jsonb(a)||jsonb_build_object(\'release_id\',',lit(secondRelease),'))).* FROM ',schema,'.',table,' a WHERE release_id=',lit(release)))
  stopifnot(q(paste0('SELECT count(*)::text AS n FROM ',schema,'.aggregate_cell WHERE release_id=',lit(release)))$N==expectedCells)
  sealResultRelease(details,schema,secondRelease);validateResultRelease(details,schema,secondRelease)
  cluster <- parallel::makePSOCKcluster(2L)
  outcomes <- tryCatch(parallel::parLapply(cluster,1:2,function(i,lib,config,schema,releases,root,policy) {
    library(AchillesNext,lib.loc=lib);e <- new.env();sys.source(config,e)
    tryCatch(list(ok=TRUE,result=publishResultRelease(e$fixtureConnection('owner'),schema,releases[[i]],file.path(root,paste0('race-',i)),'fixture-restricted','race-review',policy,function(candidate)TRUE,'1')),
      error=function(e)list(ok=FALSE,conflict=identical(conditionMessage(e),'Current publication conflict')))
  },lib=normalizePath(Sys.getenv('R_LIBS')),config=normalizePath(args[[1]]),schema=schema,releases=c(release,secondRelease),root=root,policy=allow),finally=parallel::stopCluster(cluster))
  stopifnot(sum(vapply(outcomes,function(o)o$ok,TRUE))==1L,all(vapply(outcomes,function(o)if(o$ok)o$result$revision=='2' else o$conflict,TRUE)))
  stopifnot(q(paste0('SELECT revision::text AS n FROM ',schema,'.current_publication'))$N=='2')
  validateResultArtifact(approved$export_dir)
  cat('TWO_RUN_COMPLETE_PUBLICATION_RACE_OK\n')
  dist <- allow;dist$scope_kind <- 'distributable';dist$allow_metrics <- list('core.person.count')
  shared <- publishResultRelease(details,schema,release,file.path(root,'distributable'),'fixture-distributable','review-dist',dist,function(candidate)TRUE)
  validateResultArtifact(shared$export_dir)
  objects <- list.files(file.path(shared$export_dir,'objects'),full.names=TRUE)
  payload <- paste(vapply(objects,function(p)paste(readLines(p,warn=FALSE),collapse=''),''),collapse='')
  stopifnot(!grepl('20.5',payload,fixed=TRUE),!grepl('"value":"123"',payload,fixed=TRUE))
  # Rehash all ancestors after mutation: integrity alone must not admit unsafe
  # numbers or inconsistent partitions. The original approved export stays pinned.
  for(kind in c('unsafe-number','bad-partition')) {
    path <- file.path(root,kind);dir.create(path);file.copy(list.files(approved$export_dir,full.names=TRUE),path,recursive=TRUE)
    pointer <- jsonlite::fromJSON(file.path(path,'publication.json'),simplifyVector=FALSE)
    rewrite <- function(d) {
      old <- file.path(path,'objects',paste0(d$sha256,'.json'));doc <- jsonlite::fromJSON(old,simplifyVector=FALSE)
      if(doc$kind=='root')for(k in c('catalogue','concepts','data','terminology'))doc[[k]] <- rewrite(doc[[k]])
      if(doc$kind=='index')for(i in seq_along(doc$children))doc$children[[i]]$object <- rewrite(doc$children[[i]]$object)
      if(doc$kind=='data' && doc$metric_id==if(kind=='unsafe-number')'core.person.count' else 'core.person.gender_count')doc$rows[[1]]$values$person_count <- if(kind=='unsafe-number')9007199254740992 else '1'
      bytes <- wire(doc);nextDescriptor <- f('.v2_descriptor')(bytes,d$kind,d$rows)
      if(nextDescriptor$sha256!=d$sha256){writeBin(bytes,file.path(path,'objects',paste0(nextDescriptor$sha256,'.json')));unlink(old)}
      nextDescriptor
    }
    pointer$root <- rewrite(pointer$root);writeBin(wire(pointer),file.path(path,'publication.json'))
    fail(function()validateResultArtifact(path))
  }
  cat('REHASHED_SCHEMA_AND_SEMANTIC_MUTATIONS_REJECTED_OK\n')
  writeLines('undeclared',file.path(shared$export_dir,'objects','extra.json'))
  fail(function()validateResultArtifact(shared$export_dir));unlink(file.path(shared$export_dir,'objects','extra.json'))
  validateResultArtifact(shared$export_dir)
  cat('STORE_NATIVE_VALIDATE_PROJECT_EXPORT_READBACK_OK\n')
})
