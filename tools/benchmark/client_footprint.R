# Contributor-only offline worker. Run through client_footprint.py from the checkout.
local({
  args <- commandArgs(TRUE)
  stopifnot(length(args)==5L, args[[1]]%in%c('plan','primitives','saved'))
  mode <- args[[1]]; root <- args[[2]]; output <- args[[3]]
  phases <- list(); attempts <- 0L; report <- list(status='failed',mode=mode)
  writeReport <- function() jsonlite::write_json(c(report,list(phases=phases,
    connector_attempts=attempts)),file.path(output,'worker.json'),auto_unbox=TRUE,pretty=TRUE,null='null')
  phase <- function(name,work) {
    if(file.exists(file.path(output,'stop.json')))stop('Observer requested stop')
    invisible(gc(reset=TRUE)); start <- proc.time()
    value <- work(); elapsed <- proc.time()-start; heap <- gc()
    phases[[name]] <<- list(wall_seconds=unname(elapsed[['elapsed']]),
      client_cpu_seconds=unname(sum(elapsed[c('user.self','sys.self')])),
      R_heap_peak_MiB=sum(heap[,6]),retained_R_object_bytes=as.numeric(object.size(value)))
    value
  }
  tryCatch({
    phase('package_load',function()library(AchillesNext))
    # Arm without loading the connector/JVM just for instrumentation.
    connect <- NULL; event <- packageEvent('DatabaseConnector','onLoad'); hooks <- getHook(event)
    arm <- function(...) {
      if(!is.null(connect))return(invisible(NULL))
      connect <<- get('connect',asNamespace('DatabaseConnector'))
      assignInNamespace('connect',function(...) {attempts <<- attempts+1L;stop('Offline worker attempted a database connection')},ns='DatabaseConnector')
    }
    setHook(event,arm,action='append')
    if(isNamespaceLoaded('DatabaseConnector'))arm()
    on.exit({setHook(event,hooks,action='replace');if(!is.null(connect))assignInNamespace('connect',connect,ns='DatabaseConnector')},add=TRUE)
    source(file.path(root,'tools/benchmark/implementation_identity.R'),local=TRUE)
    report$implementation <- implementationIdentity(root)
    f <- function(n)get(n,asNamespace('AchillesNext'))
    report$runtime <- list(R=R.version.string,platform=R.version$platform,
      OS=as.list(Sys.info()[c('sysname','release','machine')]),
      dependencies=as.list(vapply(c('AchillesNext','DatabaseConnector','rJava','digest','jsonlite','httpuv'),
        function(p)as.character(packageVersion(p)),'')))
    window <- list(start='2020-01-01',end='2020-12-31')
    if(mode%in%c('plan','primitives')) {
      products <- list()
      for(version in c('5.3','5.4','5.5')) {
        if(mode=='plan')for(strategy in c('reference','shared')) {
          name <- paste(version,strategy,sep='-')
          products[[name]] <- phase(name,function()planCharacterizationBatch('cdm','offline:client',version,window,strategy))
        } else {
          products[[version]] <- phase(version,function() {
            plan <- planCharacterizationBatch('cdm','offline:client',version,window)
            domains <- names(f('.v2_assets')()$profile$domains)
            c(list(interval=f('.batch_interval_sql')(plan)),
              stats::setNames(lapply(domains,function(d)f('.batch_classification_sql')(plan,d)),domains),
              list(capture=f('.batch_capture_sql')(window),coverage=f('.batch_coverage_sql')(plan),
                numeric_reference=f('.batch_numeric_sql')('reference'),numeric_weighted=f('.batch_numeric_sql')('weighted')))
          })
          stopifnot(!any(grepl('{{',unlist(products[[version]]),fixed=TRUE)))
        }
      }
      jsonlite::write_json(products,file.path(output,'products.json'),auto_unbox=TRUE,pretty=TRUE,null='null')
      report$products <- lapply(products,function(p)list(sha256=digest::digest(p,algo='sha256'),
        serialized_json_bytes=nchar(jsonlite::toJSON(p,auto_unbox=TRUE,null='null'),type='bytes')))
      report$coverage <- if(mode=='plan')'Public PostgreSQL planner; no executable full-profile SQL returned' else
        'Internal PostgreSQL physical primitives only; NOT the 142-output generation SQL or a public render API'
    } else {
      stopifnot(file.info(args[[5]])$size<=65536)
      context <- jsonlite::fromJSON(args[[5]],simplifyVector=FALSE)
      phase('native_artifact_admission',function()validateResultArtifact(args[[4]]))
      p <- phase('provider_open',function()openArtifactResultProvider(args[[4]],context,function(c)identical(c,context)))
      on.exit(p$close(),add=TRUE)
      phase('first_catalogue_page',function()p$listMetrics(limit=25L))
      response <- phase('first_person_count',function()p$selectSavedRows('core.person.count',maxRows=1L))
      stopifnot(response$state=='available',!response$generation_requested)
      reads <- vector('list',100L)
      for(i in seq_along(reads)) {
        response <- phase(paste0('warm_read_',i),function()p$selectSavedRows('core.person.count',maxRows=1L))
        stopifnot(response$state=='available',!response$generation_requested)
        reads[[i]] <- list(budget=response$budget,response_bytes=length(f('.v2_bytes')(response)))
      }
      report$reads <- reads; report$reader <- p$inspect()
      report$context <- context
      report$coverage <- 'Caller-approved saved artifact; admission plus one catalogue page and 101 PERSON-count reads; no UI or DB-provider measurement'
    }
    report$connector_namespace_loaded <- isNamespaceLoaded('DatabaseConnector')
    report$JVM <- if(isNamespaceLoaded('rJava') && get('.jniInitialized',asNamespace('rJava'))) list(initialized=TRUE,
      version=rJava::.jcall('java/lang/System','S','getProperty','java.version'),
      max_heap_bytes=rJava::.jcall(rJava::.jcall('java/lang/Runtime','Ljava/lang/Runtime;','getRuntime'),'J','maxMemory')) else list(initialized=FALSE)
    stopifnot(attempts==0L)
    report$status <- 'completed'
    writeReport()
  },error=function(e) {
    report$error <<- conditionMessage(e);writeReport();stop(e)
  })
})
