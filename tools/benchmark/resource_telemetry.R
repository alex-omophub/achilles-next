# Opt-in contributor observations; namespace bindings and analytical bodies stay intact.
resourceTelemetry <- function(out,owner,schemas,source) {
  ns<-asNamespace('AchillesNext');getn<-function(n)get(n,ns);lit<-getn('.store_literal')
  journal<-file.path(out,'phases.jsonl');stopifnot(!file.exists(journal))
  log<-file(journal,'wb');rows<-0L;counter<-0L;stack<-integer();sqlStats<-list();writerStats<-list();tempPeak<-0;tempSamples<-0L;closed<-FALSE;afterStatement<-NULL
  clock<-proc.time()[['elapsed']]
  write<-function(value) {
    rows<<-rows+1L;stopifnot(rows<=10000L)
    raw<-charToRaw(paste0(jsonlite::toJSON(value,auto_unbox=TRUE,null='null',digits=NA),'\n'))
    stopifnot(length(raw)<=1048576L,seek(log)+length(raw)<=64*1024^2)
    writeBin(raw,log);flush(log)
  }
  check<-function()if(file.exists(file.path(out,'stop.json')))stop('Telemetry cooperative stop requested',call.=FALSE)
  observation<-function(value=NULL,reason=NULL,scope=NULL)list(state=if(is.null(reason))'available' else 'unavailable',value=value,reason=reason,scope=scope)
  query<-function(sql,scope)tryCatch(observation(getn('.store_decode')(referenceOne(owner,sql)),scope=scope),error=function(e)observation(reason='counter_unavailable',scope=scope))
  snapshot<-function()list(
    database=query("SELECT jsonb_build_object('track_io_timing',current_setting('track_io_timing'),'stats_reset',stats_reset::text,'temp_files',temp_files::text,'temp_bytes',temp_bytes::text,'blks_read',blks_read::text,'blks_hit',blks_hit::text,'blk_read_time_ms',blk_read_time::text,'blk_write_time_ms',blk_write_time::text)::text FROM pg_stat_database WHERE datname=current_database()",'shared fixture database cumulative counters; asynchronous flush; not exclusive job attribution'),
    wal=query("SELECT jsonb_build_object('stats_reset',stats_reset::text,'wal_records',wal_records::text,'wal_bytes',wal_bytes::text)::text FROM pg_stat_wal",'whole PostgreSQL instance cumulative WAL; not exclusive job attribution'),
    storage=query(paste0("SELECT jsonb_build_object('owned_relation_bytes',COALESCE(sum(pg_total_relation_size(c.oid)),0)::text,'database_bytes',pg_database_size(current_database())::text)::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind IN ('r','p','m') AND n.nspname IN (",paste(vapply(schemas,lit,''),collapse=','),')'),'owned source/results/serving logical relation allocation; database size shared; no WAL/temp volume peak'))
  measure<-function(name,work,scope='inclusive phase; nested observations overlap',database=FALSE) {
    check();counter<<-counter+1L;id<-counter;parent<-if(length(stack))tail(stack,1L) else NULL
    beforeDB<-if(database)snapshot() else NULL;begin<-proc.time();status<-'failed'
    write(list(event='begin',id=id,parent=parent,phase=name,elapsed_seconds=begin[['elapsed']]-clock,scope=scope))
    stack<<-c(stack,id)
    on.exit({
      end<-proc.time();stack<<-head(stack,-1L)
      write(list(event='end',id=id,parent=parent,phase=name,status=status,elapsed_seconds=end[['elapsed']]-clock,
        wall_seconds=end[['elapsed']]-begin[['elapsed']],R_self_CPU_seconds=sum(end[c('user.self','sys.self')]-begin[c('user.self','sys.self')]),
        cpu_scope='R process self CPU including in-process JVM; excludes PostgreSQL and child comparisons',scope=scope,
        before=beforeDB,after=if(database)snapshot() else NULL))
    },add=TRUE)
    result<-work();status<-'completed';result
  }
  aggregate<-function(target,key,work) {
    begin<-proc.time();failed<-TRUE
    on.exit({
      end<-proc.time();v<-target[[key]]
      if(is.null(v))v<-list(calls=0L,failures=0L,wall_seconds=0,R_self_CPU_seconds=0)
      v$calls<-v$calls+1L;v$failures<-v$failures+as.integer(failed);v$wall_seconds<-v$wall_seconds+end[['elapsed']]-begin[['elapsed']]
      v$R_self_CPU_seconds<-v$R_self_CPU_seconds+sum(end[c('user.self','sys.self')]-begin[c('user.self','sys.self')]);target[[key]]<-v
    },add=TRUE)
    value<-work();failed<-FALSE;value
  }
  sqlEnv<-new.env(parent=emptyenv());writerEnv<-new.env(parent=emptyenv())
  family<-function(sql) {
    if(grepl('^INSERT INTO .*achillesnext_(aggregate_cell|denominator_edge)',sql))return('aggregate_persistence_including_revision_triggers')
    if(grepl('achillesnext_page_object',sql,fixed=TRUE)&&grepl('^INSERT',sql))return('page_persistence')
    if(grepl('promote_publication',sql,fixed=TRUE))return('publication_CAS')
    if(grepl('^(INSERT|UPDATE|DELETE)',sql))return('control_persistence')
    if(grepl('^CREATE TEMP',sql))return(if(grepl(source,sql,fixed=TRUE))'source_materialization' else 'derived_materialization')
    if(grepl('^(CREATE INDEX|ANALYZE|DROP TABLE)',sql))return('stage_maintenance')
    'read_or_session_control'
  }
  decorate<-function(tx) {
    execute<-tx$execute;one<-tx$one;stream<-tx$stream
    execute('SET LOCAL statement_timeout=30000; SET LOCAL lock_timeout=2000')
    pid<-one('SELECT pg_backend_pid()::text');write(list(event='backend',pid=pid,scope='SQL session leader only; parallel workers/postmaster/cache not attributed'))
    run<-function(sql,api,work) {
      check();key<-paste(if(length(stack))tail(stack,1L) else 'none',api,family(sql),sep='|')
      stopifnot(length(ls(sqlEnv))<5000L||exists(key,sqlEnv,inherits=FALSE))
      value<-aggregate(sqlEnv,key,work)
      if(!is.null(afterStatement))afterStatement(sql)
      if(grepl('^CREATE (TEMP|INDEX)',sql)) {
        bytes<-tryCatch(as.numeric(one("SELECT COALESCE(sum(pg_total_relation_size(oid)),0)::text FROM pg_class WHERE relnamespace=pg_my_temp_schema() AND relkind IN ('r','m')")),error=function(e)NA_real_)
        if(!is.na(bytes)){tempPeak<<-max(tempPeak,bytes);tempSamples<<-tempSamples+1L}
      }
      check();value
    }
    tx$execute<-function(sql)run(sql,'execute',function()execute(sql))
    tx$one<-function(sql)run(sql,'one',function()one(sql))
    tx$stream<-function(sql,visit)run(sql,'stream_including_callbacks',function()stream(sql,function(text){check();visit(text)}))
    tx
  }
  baseEnv<-new.env(parent=ns)
  baseEnv$.store_commit<-function(jdbc)measure('transaction_commit',function()getn('.store_commit')(jdbc),database=FALSE)
  base<-getn('.store_transaction');environment(base)<-baseEnv
  transaction<-function(snapshot=NULL,witnesses=NULL) {
    if(!is.null(snapshot))stopifnot(grepl('^[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9]+$',snapshot))
    function(details,schema,work,...)base(details,schema,function(tx) {
      if(!is.null(snapshot)) {
        tx$execute(paste0("SET TRANSACTION SNAPSHOT '",snapshot,"'"))
        witness<-tx$one('SELECT pg_current_snapshot()::text')
        if(!is.null(witnesses))witnesses$values<-c(witnesses$values,witness)
      }
      work(decorate(tx))
    },...)
  }
  lookup<-function(original) {
    force(original)
    function(name) {
    value<-original(name)
    if(name=='.core_write_metadata')return(function(...) {args<-list(...);measure('metadata_assembly',function()do.call(value,args))})
    if(name!='.store_writer')return(value)
    function(...) {
      writer<-value(...)
      for(method in c('add','flush','finish'))writer[[method]]<-local({fun<-writer[[method]];kind<-method;function(...) {
        args<-list(...);check();aggregate(writerEnv,kind,function()do.call(fun,args))
      }})
      writer
    }
  }
  }
  public<-function(name) {
    scope<-new.env(parent=ns)
    scope$.store_transaction<-transaction()
    for(helper in c('.store_build_pages','.v2_directory','.store_validate')) {
      original<-getn(helper)
      if(helper=='.store_build_pages') {
        environment(original)<-scope
        scope$writeBin<-function(...) {args<-list(...);measure('filesystem_write',function()do.call(base::writeBin,args),database=FALSE)}
      }
      label<-switch(helper,'.store_build_pages'='projection_serialization_filesystem','.v2_directory'='native_artifact_admission','.store_validate'='stored_release_validation')
      scope[[helper]]<-local({fun<-original;phase<-label;function(...) {args<-list(...);measure(phase,function()do.call(fun,args))}})
    }
    fn<-getn(name);environment(fn)<-scope;fn
  }
  finish<-function(status) {
    if(closed)return(invisible(NULL))
    write(list(event='summary',status=status,sql=as.list(sqlEnv),writer=as.list(writerEnv),
      persistence_scope='inclusive writer methods and SQL; flush/add/finish overlap; SQL includes trigger revision costs, which are not isolated',
      sampled_temp_relation_peak_bytes=if(tempSamples)observation(tempPeak,scope='sampled transaction temp relation allocation') else observation(reason='no_successful_temp_sample'),temp_samples=tempSamples,temp_scope='transaction-local allocated temp relations sampled after CREATE/index; excludes executor spill/short-lived peaks',
      missing=list(database_CPU_memory='not attributed',job_cache_peak='no dedicated verified cgroup',revision_trigger_CPU='included in statements, not isolated',physical_volume_peak='not measured')))
    close(log);closed<<-TRUE
  }
  list(phase=measure,check=check,transaction=transaction,lookup=lookup,public=public,snapshot=snapshot,finish=finish,
    set_after_statement=function(hook){stopifnot(is.null(hook)||is.function(hook));afterStatement<<-hook})
}
