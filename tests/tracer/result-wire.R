# Native/independent-JS differential row corpus; no database required.
library(AchillesNext)
args <- commandArgs(TRUE);stopifnot(length(args)==1L)
ns <- asNamespace('AchillesNext');f <- function(n)get(n,ns);a <- f('.v2_assets')();obj <- f('.object')
unknown <- obj(state='unknown',value=NULL,basis=NULL,assertion_id=NULL,reason_code='fixture.unknown')
coverage <- obj(scope_kind='standard_full',complete=TRUE,excluded_record_count='0',reason_code=NULL)
metadata <- list(
 'core.source.passport'=obj(source_id='fixture:wire',source_release=unknown,declared_cdm_version='5.5',observed_schema=obj(sha256=strrep('a',64),reason_code=NULL),vocabulary_release=unknown,profile=obj(id='core-characterization-v2',revision='2.0.0',sha256=a$hash),coverage=coverage,generation=obj(started_at='2026-01-01T00:00:00.000Z',ended_at='2026-01-01T00:00:00.000Z'),consistency=obj(within_run='unknown',reusable=FALSE,reason_code='fixture.unknown')),
 'core.source.capabilities'=obj(state='available',reason_code=NULL,observed_type='integer'),
 'core.execution.output_status'=obj(state='computed',reason_code=NULL,required=TRUE,coverage=coverage,integrity=obj(state='not_validated',sha256=NULL,reason_code='fixture.pending')),
 'core.execution.timing'=obj(duration_ms=NULL,telemetry=obj(cpu_ms=NULL,peak_memory_bytes=NULL,source_rows=NULL,temp_bytes=NULL),availability='unavailable',reason_code='fixture.not_measured'))
makeDimension <- function(name,mid) {
 if(grepl('_tag$',name))return(if(name=='unit_concept_tag')obj(kind='id',value='456') else obj(kind='null'))
 if(name%in%c('period_start','period_end'))return('null')
 if(name=='month')return('2020-01-01')
 if(name=='representation_flags')return(if(grepl('measurement',mid,fixed=TRUE))'000' else '00000')
 if(name=='presence_bits')return('000000000')
 if(name=='metric_id')return('core.person.count')
 if(name=='probe_id')return(a$profile$metrics[[5]]$inputs[[1]])
 if(name%in%c('eligibility_reason','reason'))return('eligible')
 if(name%in%c('present','full_calendar_period'))return('true')
 schema <- a$dimensions[[name]]
 if(!is.null(schema$enum))return(schema$enum[[1]])
 if(name%in%c('operation_id'))return('fixture')
 '0'
}
cases <- list();add <- function(mid,row,valid,label) {
 row$row_key <- f('.v2_row_identity')(a$rows[[mid]],row)
 accepted <- tryCatch({f('.v2_row')(mid,row);TRUE},error=function(e){if(valid)message(mid,'/',row$row_kind,': ',conditionMessage(e));FALSE})
 stopifnot(accepted==valid)
 cases[[length(cases)+1L]] <<- obj(metric_id=mid,row=row,valid=valid,label=label)
}
for(mid in names(a$rows)) for(kind in names(a$rows[[mid]]$value_keys_by_row_kind)) {
 registry <- a$rows[[mid]];names <- c(unlist(registry$dimensions),unlist(registry$extra_dimensions_by_row_kind[[kind]]))
 dims <- structure(lapply(names,makeDimension,mid=mid),names=if(is.null(names))character() else names)
 values <- if(kind=='metadata')metadata[[mid]] else if(kind=='summary')obj(n='6',sum='20.5',min='1',max='10',mean_numerator='20.5',mean_denominator='6',p10='1',p25='2',p50='2.5',p75='2.5',p90='10') else structure(rep(list('9007199254740993'),length(registry$value_keys_by_row_kind[[kind]])),names=unlist(registry$value_keys_by_row_kind[[kind]]))
 row <- obj(row_key='',dimensions=dims,row_kind=kind,state='computed',reason_code=NULL,values=values,denominator_refs=list())
 add(mid,row,TRUE,'valid')
 bad <- row;bad$values$unregistered <- 'patient-level-sentinel';add(mid,bad,FALSE,'unknown value')
 bad <- row;bad$dimensions$person_id <- '123';add(mid,bad,FALSE,'patient dimension')
 bad <- row;bad$state <- 'suppressed';bad$reason_code <- 'fixture.policy';add(mid,bad,FALSE,'suppression leak')
 bad["values"] <- list(NULL);add(mid,bad,TRUE,'suppressed')
 if(kind!='metadata') {
   bad <- row;bad$values[[1]] <- 9007199254740992;add(mid,bad,FALSE,'unsafe number')
 }
}
# Optional CARE_SITE support is an explicit null-valued marginal, never zero.
for(state in c('unsupported','unavailable')) {
 mid <- 'core.visit.care_setting_count';row <- obj(row_key='',dimensions=obj(concept_tag=obj(kind='id',value='1'),setting_kind='place_of_service',setting_concept_tag=obj(kind='schema_absent')),row_kind='counts',state=state,reason_code='capability.care_site_absent',values=NULL,denominator_refs=list())
 add(mid,row,TRUE,state)
 bad <- row;bad$values <- obj(record_count='0',person_count='0');add(mid,bad,FALSE,'unavailable is not zero')
}
# Exact arithmetic and codec ordering, including Java BigInteger fallback.
stopifnot(f('.nv_mul')(strrep('9',1100),paste0('1',strrep('0',1000)))==paste0(strrep('9',1100),strrep('0',1000)))
values <- c('-10','-2','0','2','10');keys <- vapply(values,f('.v2_component'),'',name='integer')
stopifnot(identical(order(keys,method='radix'),seq_along(values)))
writeBin(f('.v2_bytes')(cases),args[[1]])
cat('NATIVE_V2_CORPUS_OK:',length(cases),'cases across',length(a$rows),'metrics\n')
# Split a dense page at 2,048 rows; build a second index level at 128 children.
ctx <- obj(contract_version='2.0.0',publication_id='fixture')
objects <- list();emit <- function(doc,kind,rows) {
 raw <- f('.v2_bytes')(doc);stopifnot(length(raw)<=f('.v2_limit')(kind));d <- f('.v2_descriptor')(raw,kind,rows)
 objects[[d$sha256]] <<- doc;d
}
pages <- f('.v2_pages')('concept_catalogue',ctx,emit)
for(i in 1:2049)pages$add(obj(value=as.character(i)),sprintf('%06d',i))
desc <- pages$finish();stopifnot(desc$kind=='index',desc$rows=='2049',length(objects[[desc$sha256]]$children)==2L)
tree <- f('.v2_tree')('data',ctx,emit)
for(i in 1:129)tree$add(obj(sha256=sprintf('%064d',i),bytes='1',kind='data',rows='1'),sprintf('%06d',i),sprintf('%06d',i))
desc <- tree$finish();stopifnot(desc$kind=='index',desc$rows=='129',length(objects[[desc$sha256]]$children)==2L)
cat('BOUNDED_PAGE_AND_INDEX_SPLITTING_OK\n')
