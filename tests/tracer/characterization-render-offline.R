# Declared schema compilation only; run in a fresh R process.
library(AchillesNext)
local({
  args<-commandArgs(TRUE);stopifnot(length(args)==1L)
  input<-jsonlite::fromJSON(args[[1]],simplifyVector=FALSE)
  f<-function(n)get(n,asNamespace('AchillesNext'))
  stopifnot(!isNamespaceLoaded('rJava'),!isNamespaceLoaded('DatabaseConnector'))
  columns<-function(case)do.call(rbind,lapply(names(case$columns),function(table) {
    x<-case$columns[[table]]
    data.frame(table=table,column=names(x),type=vapply(x,function(t)switch(t,bigint='int8',integer='int4',t),''),
      readable=!table%in%unlist(case$denied_tables),stringsAsFactors=FALSE)
  }))
  fail<-function(work,message) {
    error<-tryCatch({work();'ACCEPTED'},error=conditionMessage)
    stopifnot(grepl(message,error,fixed=TRUE))
  }
  for(case in input) {
    declaration<-columns(case)
    p<-renderCharacterizationSql('cdm',"fixture:apostrophe'backslash\\question?",case$version,declaration)
    stopifnot(length(p$outputs)==142L,sum(vapply(p$outputs,function(x)x$kind=='aggregate',TRUE))==138L,
      identical(names(p$outputs),names(f('.v2_assets')()$metrics)),p$execution$state=='not_executed',
      !p$execution$source_accessed,!p$transaction$publication_changed)
    again<-renderCharacterizationSql('cdm',"fixture:apostrophe'backslash\\question?",case$version,
      declaration[rev(seq_len(nrow(declaration))),rev(seq_len(ncol(declaration)))])
    stopifnot(identical(p,again))
    changed<-renderCharacterizationSql('cdm','different',case$version,declaration)
    stopifnot(p$program_sha256!=changed$program_sha256)
    for(spec in p$outputs)stopifnot(!grepl('{{',spec$sql,fixed=TRUE),
      identical(spec$parameters,if(spec$kind=='aggregate')list() else list('runtime_facts')))
    stopifnot(!any(vapply(p$steps,function(s)grepl('{{',s$sql,fixed=TRUE),TRUE)),
      all(vapply(p$steps,function(s)s$kind%in%c('execute','assert_scalar'),TRUE)),
      any(vapply(p$steps,function(s)s$id=='source.declaration'&&s$expected=='true',TRUE)))
    stopifnot(p$batch$scope$history=='source_derived_full_history',is.null(p$batch$scope$observed_window))
    drugSteps<-Filter(function(step)startsWith(step$id,'drugreports.'),p$steps)
    drugMetrics<-paste0('core.drug.',c('first_age','days_supply','refills','quantity'),'_summary')
    matches<-vapply(drugMetrics,function(metric)
      vapply(drugSteps,function(step)grepl(metric,step$sql,fixed=TRUE),TRUE),logical(length(drugSteps)))
    stopifnot(all(colSums(matches)==1L),all(rowSums(matches)<=1L))
    audit<-p$source_audit
    stopifnot(setequal(names(audit),c('format_version','kind','sql')),audit$format_version=='1.0.0',
      audit$kind=='staged_source_audit_totals',nchar(audit$sql,type='bytes')<16384L,
      !grepl('{{',audit$sql,fixed=TRUE),!grepl('_reports|_population"|_inventory"|_density"',audit$sql))
    for(table in c('person','raw','union',paste0(f('.domain_names')(TRUE),'class')))
      stopifnot(grepl(paste0('pg_temp."',p$declarations$stage_prefix,'_',table,'"'),audit$sql,fixed=TRUE))
    reference<-renderCharacterizationSql('cdm',"fixture:apostrophe'backslash\\question?",case$version,declaration,numericStrategy='reference')
    stopifnot(identical(audit,reference$source_audit))
    fail(function()renderCharacterizationSql('cdm','source',case$version,declaration,dialect='snowflake'),'Only the PostgreSQL')
    fail(function()renderCharacterizationSql('cdm','source','5.2',declaration),'Invalid batch source')
    fail(function()renderCharacterizationSql('cdm;DROP','source',case$version,declaration),'Invalid batch source')
    fail(function()renderCharacterizationSql('cdm','source',case$version,declaration,stagePrefix='public'),'Invalid private stage prefix')
    duplicate<-rbind(declaration,declaration[1,,drop=FALSE])
    fail(function()renderCharacterizationSql('cdm','source',case$version,duplicate),'Duplicate declared column')
    bad<-declaration;bad$type[bad$table=='measurement'&bad$column=='value_as_number']<-'float8'
    fail(function()renderCharacterizationSql('cdm','source',case$version,bad),'Unsupported exact domain type')
    absent<-declaration[!(declaration$table=='person'&declaration$column=='person_id'),]
    fail(function()renderCharacterizationSql('cdm','source',case$version,absent),'Missing required domain column')
    denied<-declaration;denied$readable[denied$table=='person'&denied$column=='person_id']<-FALSE
    fail(function()renderCharacterizationSql('cdm','source',case$version,denied),'Inaccessible domain column')
  }
  stopifnot(!isNamespaceLoaded('rJava'),!isNamespaceLoaded('DatabaseConnector'))
  cat('PURE_142_OUTPUT_RENDERING_DECLARATIONS_IDENTITIES_AND_REJECTIONS_OK\n')
})
