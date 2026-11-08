# Contributor adapters. Shared persistence/codec/metadata are intentionally used;
# numerical SQL comes exclusively from the independent Python compiler.
referenceTransaction <- function(snapshot,witnesses=NULL) {
  real <- get('.store_transaction',asNamespace('AchillesNext'))
  stopifnot(is.character(snapshot),length(snapshot)==1L,grepl('^[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9]+$',snapshot))
  function(details,schema,work,...) real(details,schema,function(tx) {
    # First statement of this new repeatable-read transaction, before any reads.
    tx$execute(paste0("SET TRANSACTION SNAPSHOT '",snapshot,"'"))
    witness<-tx$one('SELECT pg_current_snapshot()::text')
    if(!is.null(witnesses))witnesses$values<-c(witnesses$values,witness)
    tryCatch(work(tx),error=function(e){message("Matched transaction failed: ",conditionMessage(e));stop(e)})
  },...)
}

referenceOptimized <- function(details,source,sourceId,results,version,snapshot,witnesses,maxRows=50000L) {
  ns<-asNamespace('AchillesNext');scope<-new.env(parent=ns)
  # The installed public and internal generator function bodies are unchanged.
  # The sole transaction override imports the coordinator's snapshot; no binding
  # in the namespace, query body or analytical helper is replaced.
  scope$.store_transaction<-referenceTransaction(snapshot,witnesses)
  scope$.baseline_generate<-get('.baseline_generate',ns)
  environment(scope$.baseline_generate)<-scope
  generate<-get('generateCharacterizationCandidate',ns);environment(generate)<-scope
  stopifnot(identical(body(generate),body(get('generateCharacterizationCandidate',ns))),
    identical(body(scope$.baseline_generate),body(get('.baseline_generate',ns))),
    setequal(ls(scope,all.names=TRUE),c('.baseline_generate','.store_transaction')))
  generate(details,source,sourceId,results,version,maxAggregateRows=maxRows)
}

referenceGenerate <- function(details,source,sourceId,results,version,compiled,snapshot,witnesses,maxRows=50000L) {
  f<-function(n)get(n,asNamespace('AchillesNext'));lit<-f('.store_literal');uuid<-f('.store_uuid');o<-f('.object')
  assets<-f('.v2_assets')();metadata<-c('core.source.passport','core.source.capabilities','core.execution.output_status','core.execution.timing')
  stopifnot(identical(compiled$profile_sha256,assets$hash),setequal(names(compiled$queries),setdiff(names(assets$metrics),metadata)))
  started<-f('.stamp')();clock<-proc.time()[['elapsed']]
  referenceTransaction(snapshot,witnesses)(details,results,function(tx) {
    tx$execute("SET LOCAL statement_timeout=30000; SET LOCAL lock_timeout=2000; SET LOCAL timezone='UTC'; SET LOCAL datestyle='ISO,YMD'")
    f('.store_version')(tx)
    f('.population_preflight')(tx,source);f('.domain_preflight')(tx,source,TRUE)
    capabilities<-f('.core_capabilities')(tx,source);schemaHash<-capabilities$schema_sha256
    totals<-f('.store_decode')(tx$one(compiled$stats_sql))
    stopifnot(as.numeric(totals$person_count)<=1000,as.numeric(totals$raw_observation_count)<=2000,
      sum(vapply(totals[paste0(c('condition','drug','procedure','visit','device','observation','death','specimen','measurement'),'_raw')],as.numeric,0))<=10000)
    run<-f('.store_new_uuid')();release<-f('.store_new_uuid')();sourceRelease<-f('.store_new_uuid')()
    stages<-list();counts<-list();timings<-list();rowsSoFar<-0L
    for(mid in names(compiled$queries)) {
      spec<-compiled$queries[[mid]];name<-paste0('ref_',gsub('-','',run),'_',length(stages)+1L);relation<-paste0('pg_temp."',name,'"')
      begin<-proc.time()[['elapsed']]
      tx$execute(paste0('CREATE TEMP TABLE "',name,'" ON COMMIT DROP AS ',spec$sql))
      n<-tx$one(paste('SELECT count(*)::text FROM',relation));rowsSoFar<-rowsSoFar+as.numeric(n)
      stopifnot(rowsSoFar<=maxRows)
      stages[[mid]]<-relation;counts[[mid]]<-n
      timings[[paste0('reference.',mid)]]<-list(duration_ms=f('.run_ms')(begin))
      bytes<-tx$one(paste0('SELECT sum(pg_total_relation_size(to_regclass(x)))::text FROM unnest(ARRAY[',paste(vapply(stages,lit,''),collapse=','),']) x'))
      stopifnot(as.numeric(bytes)<=64*1024^2)
    }
    unknown<-o(state='unknown',value=NULL,basis=NULL,assertion_id=NULL,reason_code='source.no_verified_release');s<-tx$schema
    tx$execute(paste0('INSERT INTO ',s,'.achillesnext_source_release VALUES (',uuid(sourceRelease),',',lit(sourceId),',',lit(f('.json')(unknown)),'::jsonb,',lit(f('.json')(unknown)),'::jsonb,',lit(schemaHash),',',lit(version),',now())'))
    tx$execute(paste0('INSERT INTO ',s,'.achillesnext_analysis_run(run_id,source_release_id,request_sha256,profile_id,profile_revision,profile_sha256,state,consistency_basis,started_at) VALUES (',
      uuid(run),',',uuid(sourceRelease),',',lit(f('.hash')(f('.json')(compiled))),',',lit(assets$profile$profile_id),',',lit(assets$profile$revision),',',lit(assets$hash),",'running','single_repeatable_read',",lit(started),'::timestamptz)'))
    tx$execute(paste0('INSERT INTO ',s,'.achillesnext_result_release VALUES (',uuid(release),',',uuid(run),",'building',142,0,NULL)"))
    counts[[metadata[1]]]<-'1';counts[[metadata[2]]]<-as.character(length(capabilities$values));counts[[metadata[3]]]<-'142';counts[[metadata[4]]]<-as.character(length(timings)+5L)
    stopifnot(sum(vapply(counts,as.numeric,0))<=maxRows)
    datasets<-list()
    for(mid in names(assets$metrics)) {
      parts<-strsplit(mid,'.',fixed=TRUE)[[1]];domain<-parts[2];unsupported<-compiled$queries[[mid]]$unsupported_reason
      if(mid%in%metadata)state<-'computed' else if(domain%in%c('person','observation_period')) {
        base<-if(domain=='person'||endsWith(mid,'person_interval_histogram')||endsWith(mid,'total_days_histogram'))totals$person_count else if(mid%in%c('core.observation_period.type_count','core.observation_period.integrity_count'))totals$raw_observation_count else totals$merged_interval_count
        state<-if(base!='0')'computed' else if(totals$person_count=='0'||mid%in%c('core.observation_period.type_count','core.observation_period.integrity_count'))'empty_source' else 'empty_population'
      } else if(domain=='density')state<-if(totals$person_count=='0')'empty_source' else 'computed' else {
        state<-if(!is.null(unsupported))'unsupported' else if(totals[[paste0(domain,'_raw')]]=='0')'empty_source' else if(parts[1]=='observed'&&totals[[paste0(domain,'_observed')]]=='0')'empty_population' else 'computed'
        if(endsWith(mid,'.distinct_concepts_histogram')&&totals$person_count!='0')state<-'computed'
      }
      reason<-if(state=='computed')NULL else if(state=='unsupported')unsupported else if(state=='empty_source')'source.empty' else if(domain%in%c('person','observation_period'))'observation.no_valid_intervals' else 'population.no_qualifying_events'
      m<-assets$metrics[[mid]]
      d<-o(metric_id=mid,version=m$version,population=m$population,grain=m$grain,row_schema_id=assets$rows[[mid]]$row_schema_id,
        definition_sha256=f('.v2_hash')(f('.v2_bytes')(m)),state=state,reason_code=reason,required=TRUE,
        conditional_support=o(state=if(state=='unsupported')'schema_absent' else 'supported',reason_code=unsupported),rows=counts[[mid]],
        completeness=o(scope_kind=if(state=='unsupported')'schema_conditional' else 'standard_full',complete=TRUE,excluded_record_count=if(state=='unsupported')NULL else '0',reason_code=unsupported))
      f('.v2_dataset')(d);datasets[[mid]]<-d
      tx$execute(paste0('INSERT INTO ',s,'.achillesnext_dataset VALUES (',paste(c(uuid(release),vapply(c(mid,m$version,m$population,m$grain,d$row_schema_id,d$definition_sha256,state),lit,''),if(is.null(reason))'NULL' else lit(reason),'true',paste0(lit(f('.json')(d$conditional_support)),'::jsonb'),d$rows,paste0(lit(f('.json')(d$completeness)),'::jsonb')),collapse=','),')'))
    }
    writer<-f('.store_writer')(tx,release)
    for(mid in c('core.person.count',setdiff(names(assets$metrics),c(metadata,'core.person.count')))) {
      output<-paste0('(SELECT ',lit(mid),'::text AS metric_id,* FROM ',stages[[mid]],') reference')
      tx$stream(f('.domain_stream_sql')(tx,release,output,mid),function(raw) {
        v<-f('.store_decode')(raw);d<-datasets[[mid]]
        row<-o(row_key='',dimensions=v$dimensions,row_kind=v$row_kind,state=d$state,reason_code=d$reason_code,values=lapply(v$values,f('.baseline_normalize')),denominator_refs=list())
        if(row$row_kind=='summary'&&row$values$n=='0'){row$state<-'empty_population';row$reason_code<-'summary.no_eligible'}
        if(mid=='core.visit.care_setting_count'&&row$dimensions$setting_kind=='place_of_service'&&!is.null(compiled$care_reason)) {
          row$state<-if(compiled$care_reason=='capability.care_site_absent')'unsupported' else 'unavailable';row$reason_code<-compiled$care_reason;row['values']<-list(NULL)
        }
        row$denominator_refs<-f('.domain_denominators')(mid,row,v$denominator)
        row$row_key<-f('.v2_row_identity')(assets$rows[[mid]],row);writer$add(mid,row)
      });writer$flush()
    }
    persistence<-writer$finish();ended<-f('.stamp')()
    f('.core_write_metadata')(tx,release,sourceId,version,schemaHash,capabilities$values,datasets,started,ended,
      f('.core_timing')(timings,f('.run_ms')(clock)),maxRows,rowsSoFar,function(){})
    telemetry<-o(source_schema=source,compiler_sha256=compiled$compiler_sha256,per_output=timings,totals=totals,persistence=persistence,
      started_at=started,ended_at=ended,reusable=FALSE)
    tx$execute(paste0('INSERT INTO ',s,'.achillesnext_operation VALUES (',uuid(run),",'reference.generate',",lit(compiled$compiler_sha256),",'succeeded','[]',",lit(f('.json')(telemetry)),'::jsonb)'))
    tx$execute(paste0('UPDATE ',s,".achillesnext_analysis_run SET state='succeeded',finished_at=",lit(ended),'::timestamptz WHERE run_id=',uuid(run)))
    list(release_id=release,run_id=run,profile_complete=TRUE,publishable=FALSE,generated_metric_count='142',persistence=persistence)
  })
}

# DatabaseConnector query helpers may manage transaction state. Keep the export
# coordinator on the raw JDBC path, just like the installed store transaction.
referenceOne <- function(connection,sql,column=1L) {
  st<-rJava::.jcall(connection@jConnection,'Ljava/sql/Statement;','createStatement')
  on.exit(rJava::.jcall(st,'V','close'))
  rJava::.jcall(st,'V','setQueryTimeout',30L)
  rs<-rJava::.jcall(st,'Ljava/sql/ResultSet;','executeQuery',sql)
  on.exit(rJava::.jcall(rs,'V','close'),add=TRUE,after=FALSE)
  stopifnot(rJava::.jcall(rs,'Z','next'))
  value<-rJava::.jcall(rs,'S','getString',as.integer(column))
  stopifnot(!rJava::.jcall(rs,'Z','next'));value
}
