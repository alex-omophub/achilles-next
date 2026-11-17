# Actual installed endpoint verdict against independent graph fixtures and the
# physical store layout. The stale-stat witness has an own finite query timeout;
# it makes no plan-node or machine-dependent wall-time assertion.
testDenominatorEndpointNative <- function(details, ex, q) {
  f<-function(n)get(n,asNamespace('AchillesNext'));lit<-f('.store_literal')
  marker<-q("SELECT current_database() AS db,shobj_description(oid,'pg_database') AS marker FROM pg_database WHERE datname=current_database()")
  stopifnot(marker$DB=='achilles_next_fixtures',marker$MARKER=='AchillesNext synthetic fixture sandbox v1')
  graph<-paste0('endpoint_graph_',Sys.getpid());physical<-paste0('endpoint_physical_',Sys.getpid());owned<-character()
  quoted<-function(s)paste0('"',s,'"')
  cleanup<-function() {
    errors<-list()
    for(s in rev(owned))tryCatch(f('.store_transaction')(details,s,function(tx)tx$execute(paste0('DROP SCHEMA ',quoted(s),' CASCADE')),queryTimeoutSeconds=5L),
      error=function(e)errors[[length(errors)+1L]]<<-class(e))
    if(length(errors))stop('Owned endpoint fixture cleanup failed',call.=FALSE)
  }
  on.exit(cleanup(),add=TRUE)
  create<-function(s){ex(paste0('CREATE SCHEMA ',quoted(s)));owned<<-c(owned,s)}
  verdict<-function(s,r)f('.store_transaction')(details,s,function(tx)tx$one(f('.store_denominator_endpoint_sql')(tx$schema,r)),readOnly=TRUE,queryTimeoutSeconds=8L)
  release<-'10000000-0000-4000-8000-000000000001';other<-'20000000-0000-4000-8000-000000000002'
  create(graph)
  ex(paste0('CREATE TABLE ',quoted(graph),'.achillesnext_aggregate_cell(release_id uuid,metric_id text,row_key text,state text);',
    'CREATE TABLE ',quoted(graph),'.achillesnext_denominator_edge(release_id uuid,metric_id text,row_key text,target_metric_id text,target_row_key text)'))
  cell<-function(state,mid='source',key='s',rid=release)list(rid,mid,key,state)
  edge<-function(mid='source',key='s',target='target',targetKey='t',rid=release)list(rid,mid,key,target,targetKey)
  source<-function(state,...)cell(state,...);target<-function(state,...)cell(state,mid='target',key='t',...)
  cases<-list(
    neither=list(cells=list(source('computed'),target('computed')),edges=list(edge()),expected='0'),
    source=list(cells=list(source('suppressed'),target('computed')),edges=list(edge()),expected='1'),
    target=list(cells=list(source('computed'),target('suppressed')),edges=list(edge()),expected='1'),
    both=list(cells=list(source('suppressed'),target('suppressed')),edges=list(edge()),expected='1'),
    unsupported=list(cells=list(source('unsupported'),target('computed')),edges=list(edge()),expected='0'),
    unavailable=list(cells=list(source('unavailable'),target('unsupported')),edges=list(edge()),expected='0'),
    null_none=list(cells=list(source(NULL),target(NULL)),edges=list(edge()),expected='0'),
    null_source=list(cells=list(source(NULL),target('suppressed')),edges=list(edge()),expected='1'),
    null_target=list(cells=list(source('suppressed'),target(NULL)),edges=list(edge()),expected='1'),
    missing_source=list(cells=list(target('suppressed')),edges=list(edge()),expected='0'),
    missing_target=list(cells=list(source('suppressed')),edges=list(edge()),expected='0'),
    missing_both=list(cells=list(),edges=list(edge()),expected='0'),
    wrong_source_metric=list(cells=list(source('suppressed',mid='different'),target('computed')),edges=list(edge()),expected='0'),
    wrong_target_key=list(cells=list(source('suppressed'),cell('computed','target','different')),edges=list(edge()),expected='0'),
    wrong_endpoint_release=list(cells=list(source('suppressed',rid=other),target('computed')),edges=list(edge()),expected='0'),
    wrong_edge_release=list(cells=list(source('suppressed'),target('suppressed')),edges=list(edge(rid=other)),expected='0'),
    duplicate_edges=list(cells=list(source('suppressed'),target('computed')),edges=list(edge(),edge()),expected='1'),
    duplicate_cells=list(cells=list(source('computed'),source('suppressed'),target('computed')),edges=list(edge()),expected='1'),
    self_edge=list(cells=list(source('suppressed')),edges=list(edge(target='source',targetKey='s')),expected='1'),
    later_forbidden=list(cells=list(source('computed'),target('computed'),cell('suppressed','later','x')),edges=list(edge(),edge(mid='later',key='x')),expected='1'))
  tuple<-function(row)paste0('(',paste(vapply(row,function(x)if(is.null(x))'NULL' else lit(x),''),collapse=','),')')
  for(name in names(cases)) {
    case<-cases[[name]];ex(paste0('TRUNCATE ',quoted(graph),'.achillesnext_denominator_edge,',quoted(graph),'.achillesnext_aggregate_cell'))
    for(table in c('aggregate_cell','denominator_edge')) {
      rows<-if(table=='aggregate_cell')case$cells else case$edges
      if(length(rows))ex(paste0('INSERT INTO ',quoted(graph),'.achillesnext_',table,' VALUES ',paste(vapply(rows,tuple,''),collapse=',')))
    }
    stopifnot(identical(verdict(graph,release),case$expected))
  }
  # Reuse the installed physical DDL, including every payload column, domain,
  # complete primary/unique indexes and eight HASH(metric_id) partitions. Only
  # the unrelated dataset FK is omitted so this remains a focused query fixture.
  create(physical)
  ddl<-paste(readLines(system.file('sql/postgresql/result-store.sql',package='AchillesNext',mustWork=TRUE),warn=FALSE),collapse='\n')
  section<-function(start,end) {
    from<-regexpr(start,ddl,fixed=TRUE)[[1L]];to<-regexpr(end,ddl,fixed=TRUE)[[1L]]
    stopifnot(from>0L,to>from);substring(ddl,from,to-1L)
  }
  domains<-section('CREATE DOMAIN __STORE__.sha256_hex','CREATE TABLE __STORE__.achillesnext_source_release')
  tables<-section('CREATE TABLE __STORE__.achillesnext_aggregate_cell','CREATE TABLE __STORE__.achillesnext_validation_receipt')
  fk<-'  FOREIGN KEY(release_id,metric_id) REFERENCES __STORE__.achillesnext_dataset,\n'
  stopifnot(grepl(fk,tables,fixed=TRUE));tables<-sub(fk,'',tables,fixed=TRUE)
  # Preserve the server's dollar-quoted partition block; the generic fixture
  # executor's SQL splitter does not parse arbitrary DO blocks.
  f('.store_transaction')(details,physical,function(tx)tx$execute(gsub('__STORE__',quoted(physical),paste(domains,tables),fixed=TRUE)),queryTimeoutSeconds=8L)
  for(table in c('achillesnext_denominator_edge',paste0('achillesnext_aggregate_cell_',0:7)))
    ex(paste0('ALTER TABLE ',quoted(physical),'.',table,' SET (autovacuum_enabled=false)'))
  # Fixed synthetic cardinalities span the complete metric-name distribution;
  # payloads are filler, not a generated release or numerical-analysis oracle.
  # Two previous releases supply old leaf statistics. The parent and sparse
  # leaves remain unanalyzed, matching the regression's partial-statistics shape.
  domains<-c('condition','drug','procedure','visit','device','observation','death','specimen','measurement')
  metricIds<-names(f('.v2_assets')()$metrics)
  cardinality<-function(n) {
    rows<-stats::setNames(rep(0L,length(metricIds)),metricIds)
    one<-c('core.source.passport',paste0('core.person.',c('birth_year_count','race_count','ethnicity_count','count','race_ethnicity_count')),
      paste0('core.observation_period.',c('coverage_count','continuous_person_count','person_interval_histogram','total_days_histogram')),
      paste0('core.density.',c('domain_presence_count','domain_count')),paste0('core.',domains,'.distinct_concepts_histogram'),paste0('observed.',domains,'.capture_count'))
    rows[one]<-1L;rows[c('core.source.capabilities','core.execution.output_status','core.execution.timing')]<-c(119L,142L,43L)
    rows['core.observation_period.integrity_count']<-5L;rows[paste0('core.',domains,'.capture_count')]<-2L
    rows[paste0('core.',domains,'.integrity_count')]<-c(rep(22L,5L),rep(18L,4L))
    rows[c('core.person.gender_count','core.person.birth_year_gender_count')]<-n
    stopifnot(identical(names(rows),metricIds),sum(rows)==539L+2L*n);rows
  }
  release<-'d0000000-0000-4000-8000-000000000001'
  oldSmall<-'f0000000-0000-4000-8000-000000000002';oldMedium<-'a0000000-0000-4000-8000-000000000003'
  populate<-function(rid,n) {
    s<-quoted(physical);r<-paste0(lit(rid),'::uuid');rows<-cardinality(n)
    values<-paste(vapply(names(rows),function(mid)paste0('(',r,',',lit(mid),',',rows[[mid]],')'),''),collapse=',')
    ex(paste0('WITH inventory(release_id,metric_id,rows) AS (VALUES ',values,') INSERT INTO ',s,
      '.achillesnext_aggregate_cell(release_id,metric_id,row_key,route_key,sort_key,dimensions,state,payload_kind,record_count) ',
      "SELECT release_id,metric_id,encode(sha256(convert_to(metric_id||':'||i,'UTF8')),'hex'),'A',lpad(i::text,12,'0'),jsonb_build_object('fixture_pad',repeat('x',40)),'computed','counts',1 FROM inventory CROSS JOIN LATERAL generate_series(1,rows)i"))
    ex(paste0('WITH candidates AS (SELECT c.*,row_number() OVER (ORDER BY metric_id,row_key) AS baseline FROM ',s,
      '.achillesnext_aggregate_cell c WHERE release_id=',r," AND metric_id NOT IN ('core.person.gender_count','core.person.birth_year_gender_count')), ",
      'selected AS (SELECT release_id,metric_id,row_key FROM candidates WHERE baseline<=33 UNION ALL SELECT release_id,metric_id,row_key FROM ',s,
      '.achillesnext_aggregate_cell WHERE release_id=',r," AND metric_id IN ('core.person.gender_count','core.person.birth_year_gender_count')) INSERT INTO ",s,
      ".achillesnext_denominator_edge SELECT release_id,metric_id,row_key,'person_count',CASE WHEN metric_id='core.person.birth_year_gender_count' THEN 'core.person.birth_year_count' ELSE 'core.person.count' END,",
      "encode(sha256(convert_to((CASE WHEN metric_id='core.person.birth_year_gender_count' THEN 'core.person.birth_year_count' ELSE 'core.person.count' END)||':1','UTF8')),'hex'),'person_count' FROM selected"))
  }
  populate(oldSmall,2L);populate(oldMedium,1000L)
  oldRouting<-q(paste0('SELECT tableoid::regclass::text AS physical_table,count(*)::text AS n FROM ',quoted(physical),'.achillesnext_aggregate_cell GROUP BY tableoid'))
  for(table in oldRouting$PHYSICAL_TABLE[as.numeric(oldRouting$N)>=50L])ex(paste('ANALYZE',table))
  ex(paste0('ANALYZE ',quoted(physical),'.achillesnext_denominator_edge'))
  stats<-function()q(paste0("SELECT relname,reltuples::text AS estimate FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=",lit(physical)," AND c.relkind IN ('r','p') ORDER BY relname"))
  before<-stats();populate(release,10000L)
  stopifnot(identical(stats(),before),q(paste0('SELECT count(*)::text AS n FROM ',quoted(physical),'.achillesnext_denominator_edge WHERE release_id=',lit(release)))$N=='20033')
  stopifnot(identical(verdict(physical,release),'0'))
  sourceKey<-"encode(sha256(convert_to('core.person.gender_count:10000','UTF8')),'hex')"
  ex(paste0('UPDATE ',quoted(physical),".achillesnext_aggregate_cell SET state='suppressed',reason_code='fixture.suppressed',record_count=NULL WHERE release_id=",lit(release)," AND metric_id='core.person.gender_count' AND row_key=",sourceKey))
  stopifnot(identical(verdict(physical,release),'1'))
  ex(paste0('UPDATE ',quoted(physical),".achillesnext_aggregate_cell SET state='computed',reason_code=NULL,record_count=1 WHERE release_id=",lit(release)," AND metric_id='core.person.gender_count' AND state='suppressed'"))
  ex(paste0('UPDATE ',quoted(physical),".achillesnext_aggregate_cell SET state='suppressed',reason_code='fixture.suppressed',record_count=NULL WHERE release_id=",lit(release)," AND metric_id='core.person.count'"))
  stopifnot(identical(verdict(physical,release),'1'))
  cat('DENOMINATOR_ENDPOINT_NATIVE_GRAPH_20_VERDICTS_BOTH_ENDS_FULL_KEYS_STALE_20033_EDGE_8PARTITION_OWN_TIMEOUT_OK\n')
}
