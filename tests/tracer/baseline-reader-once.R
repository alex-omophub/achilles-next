library(AchillesNext)
ns<-asNamespace('AchillesNext');emit<-get('.baseline_emit_rows',ns);obj<-get('.object',ns)
row<-obj(row_key=strrep('a',64),row_kind='counts',dimensions=obj(),state='computed',reason_code=NULL,values=obj(person_count='9007199254740993'),denominator_refs=list())
ids<-c('first','last');datasets<-stats::setNames(lapply(ids,function(id)list(state='computed',rows='1')),ids)
shim<-new.env(parent=ns);environment(emit)<-shim
reads<-character();bad<-FALSE
shim$.store_rows<-function(tx,releaseId,mid,visit) {
 reads<<-c(reads,mid);r<-row
 if(bad&&mid=='last'){r$state<-'empty_source';r$reason_code<-'fixture.late_invalid';r$values$person_count<-'0'}
 visit(r,'a')
}
spools<-function()Sys.glob(file.path(tempdir(),'achillesnext-read-*'))
before<-spools();seen<-list()
emit(NULL,'unused',ids,datasets,function(mid,value) {
 stopifnot(identical(reads,ids)) # Every dataset validated before first emission.
 stopifnot(file.info(spools())$mode==as.octmode('0700'))
 seen[[mid]]<<-value
},FALSE)
stopifnot(identical(reads,ids),identical(seen$first,row),identical(seen$last,row),identical(spools(),before))
bad<-TRUE;reads<-character();emitted<-0L
error<-tryCatch({emit(NULL,'unused',ids,datasets,function(...){emitted<<-emitted+1L},FALSE);NULL},error=conditionMessage)
stopifnot(grepl('Saved row state is inconsistent',error,fixed=TRUE),emitted==0L,identical(spools(),before))
bad<-FALSE
error<-tryCatch({emit(NULL,'unused',ids,datasets,function(...)stop('visitor stopped'),FALSE);NULL},error=conditionMessage)
stopifnot(error=='visitor stopped',identical(spools(),before))
# Exact aggregate byte budget: fail before emission and clean up on overflow.
size<-length(serialize(list(metric_id='first',row=row),NULL,version=3,xdr=FALSE))
reads<-character();emitted<-0L
error<-tryCatch({emit(NULL,'unused',ids,datasets,function(...){emitted<<-emitted+1L},FALSE,maxSpoolBytes=size);NULL},error=conditionMessage)
stopifnot(grepl('Read spool byte limit exceeded',error,fixed=TRUE),emitted==0L,identical(spools(),before))
reads<-character();emitted<-0L
emit(NULL,'unused',ids,datasets,function(mid,value){stopifnot(mid=='first',identical(value,row));emitted<<-emitted+1L},FALSE,
  maxSpoolBytes=size,select=function(mid,row)mid=='first')
stopifnot(identical(reads,ids),emitted==1L,identical(spools(),before))
# Discarded rows still undergo validation, including a late invalid dataset.
bad<-TRUE;emitted<-0L
error<-tryCatch({emit(NULL,'unused',ids,datasets,function(...){emitted<<-emitted+1L},FALSE,
  maxSpoolBytes=size,select=function(mid,row)mid=='first');NULL},error=conditionMessage)
stopifnot(grepl('Saved row state is inconsistent',error,fixed=TRUE),emitted==0L,identical(spools(),before))
bad<-FALSE
for(limit in list(-1,0.5,NA_real_,Inf,2^54,'100')) {
 stopifnot(inherits(try(emit(NULL,'unused',ids,datasets,function(...){},FALSE,maxSpoolBytes=limit),silent=TRUE),'try-error'),identical(spools(),before))
}
cat('ONE_PASS_EXACT_REPLAY_SELECTION_BUDGET_LATE_FAILURE_NO_EMISSION_AND_CLEANUP_OK\n')
