# Contributor-only native admission/read worker. Synthetic inventory, no CDM.
library(AchillesNext)
protocolDir<-Sys.getenv('ACHILLES_NEXT_INVENTORY_PROTOCOL_DIR')
source(if(nzchar(protocolDir))file.path(protocolDir,'implementation_identity.R') else 'tools/benchmark/implementation_identity.R')
inputsPath<-if(nzchar(protocolDir))file.path(protocolDir,'inventory-inputs.R') else 'tools/benchmark/inventory-inputs.R'
source(inputsPath)
args<-commandArgs(TRUE);stopifnot(length(args)%in%c(3L,4L),args[[1]]%in%c('admit','read','database'))
samples<-if(length(args)==4L)as.integer(args[[4]]) else 3L
stopifnot(!is.na(samples),samples>=1L,samples<=100L)
implementation<-implementationIdentity(getwd());f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');wire<-f('.v2_bytes')
base<-normalizePath(args[[2]],mustWork=TRUE);manifestPath<-file.path(base,'fixture.json')
manifest<-jsonlite::fromJSON(manifestPath,simplifyVector=FALSE);stopifnot(identical(manifest$fixture,'saved-inventory-v1'))
directory<-file.path(base,'artifact');context<-manifest$context;count<-.inventory_count(manifest$count)
if(args[[1]]=='admit') {
  visited<-0L;spools<-list();original<-f('.v2_spool')
  observed<-function(directory,check=function()NULL) {
    value<-original(directory,check);close<-value$close
    value$close<-function(){spools[[basename(directory)]]<<-value$inspect();close()};value
  }
  assignInNamespace('.v2_spool',observed,ns='AchillesNext')
  elapsed<-system.time(f('.v2_directory')(directory,visit=function(d,bytes) {
    visited<<-visited+1L
    if(visited%%128L==0L){cat('ADMISSION verified objects=',visited,'kind=',d$kind,'\n');flush.console()}
  }))
  assignInNamespace('.v2_spool',original,ns='AchillesNext')
  result<-o(status='passed',kind='complete_native_admission',root_sha256=context$root$sha256,
    fixture_sha256=digest::digest(file=manifestPath,algo='sha256'),
    elapsed_seconds=unname(elapsed['elapsed']),cpu_seconds=unname(elapsed['user.self']+elapsed['sys.self']),
    scratch_spools=spools,implementation=implementation)
  writeBin(wire(result),args[[3]])
  cat('SAVED_INVENTORY_COMPLETE_NATIVE_ADMISSION_OK entries=',count,'\n')
} else {
  receipt<-jsonlite::fromJSON(file.path(base,'admission.json'),simplifyVector=FALSE)
  stopifnot(receipt$status=='passed',receipt$root_sha256==context$root$sha256,
    receipt$fixture_sha256==digest::digest(file=manifestPath,algo='sha256'))
  connections<-0L;connect<-DatabaseConnector::connect
  user<-function(details)if(is.function(details$user))details$user() else details$user
  database<-args[[1]]=='database';sql<-character();db<-NULL
  if(database) {
    config<-jsonlite::fromJSON(Sys.getenv('ACHILLES_NEXT_INVENTORY_READER'),simplifyVector=FALSE)
    stopifnot(config$database=='achilles_next_fixtures')
    details<-DatabaseConnector::createConnectionDetails(dbms='postgresql',server=.inventory_reader_server(config$host,config$database),
      port=as.integer(config$port),user=config$user,password=config$password)
    transaction<-f('.store_transaction')
    observed<-function(connectionDetails,schema,work,...) {
      stopifnot(identical(schema,config$serving_schema),identical(user(connectionDetails),config$user))
      transaction(connectionDetails,schema,function(tx) {
        one<-tx$one
        tx$one<-function(statement) {
          stopifnot(startsWith(statement,paste0("SELECT encode(payload,'hex') FROM \"",config$serving_schema,"\".achillesnext_approved_pages WHERE ")))
          sql<<-c(sql,statement);one(statement)
        }
        work(tx)
      },...)
    }
    assignInNamespace('.store_transaction',observed,ns='AchillesNext')
  }
  assignInNamespace('connect',function(connectionDetails,...) {
    if(!database||!identical(user(connectionDetails),config$user)){connections<<-connections+1L;stop('Source connection forbidden')}
    connect(connectionDetails,...)
  },ns='DatabaseConnector')
  # Each worker is a disposable R process; no shared namespace survives.
  # No interactive operation may enumerate or fully admit the saved inventory.
  assignInNamespace('.v2_directory',function(...)stop('Interactive full admission forbidden'),ns='AchillesNext')
  assignInNamespace('.v2_directory_entries',function(...)stop('Interactive inventory enumeration forbidden'),ns='AchillesNext')
  constructor<-if(database)function(ctx,authority,budget)openDatabaseResultProvider(details,config$serving_schema,ctx,authority,budget) else
    function(ctx,authority,budget)openArtifactResultProvider(directory,ctx,authority,budget)
  factory<-if(database)function(ctx,authority)f('.saved_database_transport')(details,config$serving_schema,ctx,authority) else NULL
  invisible(gc());before<-gc(reset=TRUE);openStarted<-proc.time()[['elapsed']]
  active<-TRUE;opened<-system.time(p<-constructor(context,function(ctx)active,list()),gcFirst=FALSE)
  records<-list()
  measure<-function(name,work) {
    elapsed<-system.time(value<-work(),gcFirst=FALSE)
    stopifnot(value$budget$objects<=64L,value$budget$bytes<=8388608L,value$budget$rows<=8192L,
      length(wire(value))<=1048576L,p$inspect()$cache_bytes<=4194304L,p$inspect()$cache_objects<=64L)
    semantic<-value;semantic$budget<-NULL;semantic$cursor<-NULL
    records[[length(records)+1L]]<<-o(operation=name,elapsed_seconds=unname(elapsed['elapsed']),
      response_bytes=length(wire(value)),response_sha256=f('.v2_hash')(wire(semantic)),budget=value$budget)
    value
  }
  summary<-measure('first_summary',function()p$selectSavedRows('core.person.count'))
  firstSummarySeconds<-unname(proc.time()[['elapsed']]-openStarted)
  stopifnot(summary$rows[[1]]$values$person_count==as.character(count))
  for(id in unique(c(1L,as.integer(ceiling(count/2)),as.integer(count),1L+(seq_len(samples)*104729L)%%count))) {
    name<-sprintf('Synthetic concept %07d',id)
    lookup<-measure('exact_id',function()p$lookupConcepts(as.character(id)))
    stopifnot(lookup$concepts[[1]]$label==name)
    search<-measure('exact_name_prefix',function()p$searchConcepts(name))
    stopifnot(length(search$concepts)==1L,search$concepts[[1]]$concept_tag$value==as.character(id))
    selected<-measure('saved_gender_count',function()p$selectSavedRows('core.person.gender_count',list(gender_concept_id=as.character(id))))
    stopifnot(selected$rows[[1]]$values$person_count=='1',length(selected$dependencies)==1L,
      selected$dependencies[[1]]$row$values$person_count==as.character(count))
  }
  after<-gc();source(if(nzchar(protocolDir))file.path(protocolDir,'inventory-proof.R') else 'tests/tracer/inventory-proof.R')
  proof<-proveSavedInventory(directory,context,count,constructor,factory,database)
  if(database) {
    signal<-function(name)stopifnot(file.create(file.path(config$control_dir,name)))
    wait<-function(name) {
      deadline<-Sys.time()+20
      while(!file.exists(file.path(config$control_dir,name))&&Sys.time()<deadline)Sys.sleep(0.05)
      stopifnot(file.exists(file.path(config$control_dir,name)))
    }
    signal('await-revoke');wait('revoked')
    for(work in list(function()p$listMetrics(),function()p$lookupConcepts('1'),function()p$searchConcepts('Synthetic'))) {
      e<-tryCatch({work();NULL},error=identity)
      stopifnot(inherits(e,'achillesnext_read_error'),e$code=='unavailable',p$inspect()$cache_bytes==0L)
    }
    signal('revocation-checked');wait('restored')
    stopifnot(p$lookupConcepts('1')$concepts[[1]]$state=='available',!p$inspect()$cache_allowed)
    proof$database_live_revocation_and_restoration<-TRUE
  }
  stopifnot(connections==0L);p$close()
  stopifnot(!any(grepl('achillesnext_approved_current|achillesnext_aggregate_cell|cdm_|;',sql)))
  result<-o(status='passed',kind=if(database)'selective_database_reads' else 'selective_artifact_reads',count=count,
    root_sha256=context$root$sha256,operations=records,provider_open_seconds=unname(opened['elapsed']),
    first_summary_from_open_seconds=firstSummarySeconds,
    source_connection_attempts=connections,r_managed_heap=o(before_used_mib=sum(before[,2]),after_used_mib=sum(after[,2]),
      sum_region_highwaters_mib=sum(after[,ncol(after)]),scope='GC regions during selected reads; not whole R/JVM RSS or browser heap'),
    inspect=p$inspect(),proof=proof,
    approved_view_statements=length(sql),provider_CDM_statements=0L,implementation=implementation,
    protocol_sha256=stats::setNames(lapply(if(nzchar(protocolDir))file.path(protocolDir,c('inventory.R','inventory-proof.R')) else c('tools/benchmark/inventory.R','tests/tracer/inventory-proof.R'),
      function(path)digest::digest(file=path,algo='sha256')),c('worker','proof')),
    inputs_sha256=digest::digest(file=inputsPath,algo='sha256'))
  writeBin(wire(result),args[[3]]);cat('SAVED_INVENTORY_SELECTIVE_READS_OK entries=',count,'\n')
}
