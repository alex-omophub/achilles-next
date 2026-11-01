# Denominator binding consumes targets from the row stream, not per-cell SQL.
library(AchillesNext)
f<-function(n)get(n,asNamespace('AchillesNext'));obj<-f('.object')
mid<-'observed.condition.capture_count';rid<-'00000000-0000-4000-8000-000000000001'
queries<-0L
tx<-list(schema='"restricted"',one=function(...) {queries<<-queries+1L;stop('Unexpected per-row lookup')})
sql<-f('.domain_stream_sql')(tx,rid,'pg_temp.reports',mid)
stopifnot(grepl('LEFT JOIN',sql,fixed=TRUE),grepl('core.observation_period.coverage_count',sql,fixed=TRUE))
dims<-obj(period_kind='calendar_month',period_start='2020-01-01',period_end='2020-01-31')
target<-obj(metric_id='core.observation_period.coverage_count',row_key=f('.v2_row_identity')(f('.v2_assets')()$rows[['core.observation_period.coverage_count']],obj(row_kind='counts',dimensions=dims)),dimensions=dims,values=obj(person_count='9007199254740993',record_count=NULL))
for(i in seq_len(1000L)) {
 row<-obj(row_kind='counts',state='computed',dimensions=c(obj(concept_tag=obj(kind='id',value=as.character(i))),dims),values=obj(record_count='2',person_count='1'))
 refs<-f('.domain_denominators')(mid,row,target)
 stopifnot(length(refs)==1L,refs[[1]]$value=='9007199254740993',refs[[1]]$row_key==target$row_key)
}
stopifnot(queries==0L)
for(field in c('metric_id','row_key','dimensions')) {
 bad<-target;bad[[field]]<-switch(field,metric_id='core.person.count',row_key=strrep('0',64),dimensions=obj())
 stopifnot(inherits(try(f('.domain_denominators')(mid,row,bad),silent=TRUE),'try-error'))
}
cat('STREAMED_DENOMINATORS_1000_CELLS_ZERO_LOOKUP_QUERIES_AND_SCOPE_BINDING_OK\n')
