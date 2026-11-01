# Focused regressions for publication review findings; no database or Node.
library(AchillesNext)
local({
 ns<-asNamespace('AchillesNext');f<-function(n)get(n,ns);o<-f('.object');a<-f('.v2_assets')()
 rejects<-function(work,pattern) {
   message<-tryCatch({work();'ACCEPTED'},error=conditionMessage)
   stopifnot(message!='ACCEPTED',grepl(pattern,message,fixed=TRUE))
 }
 # The profile must match the independent lock, not a hash recomputed from itself.
 root<-tempfile('profile-lock-');dir.create(root);on.exit(unlink(root,recursive=TRUE))
 profile<-file.path(root,'alpha-measurement-v1.json')
 file.copy(system.file('analysis/alpha-measurement-v1.json',package='AchillesNext'),profile)
 lock<-system.file('analysis/manifest-lock.json',package='AchillesNext')
 f('.nv_locked_profile')(profile,lock)
 cat('\n',file=profile,append=TRUE)
 rejects(function()f('.nv_locked_profile')(profile,lock),'Frozen profile integrity mismatch')
 # Only the optional CARE_SITE row may be unavailable, not the entire panel.
 mid<-'core.visit.care_setting_count';m<-a$metrics[[mid]]
 d<-o(metric_id=mid,version=m$version,population=m$population,grain=m$grain,row_schema_id=a$rows[[mid]]$row_schema_id,definition_sha256=f('.v2_hash')(f('.v2_bytes')(m)),state='unsupported',reason_code='fixture.absent',required=TRUE,conditional_support=o(state='schema_absent',reason_code='fixture.absent'),rows='0',completeness=o(scope_kind='schema_conditional',complete=TRUE,excluded_record_count=NULL,reason_code='fixture.absent'))
 rejects(function()f('.v2_dataset')(d),'Required base marginals cannot be unsupported')
 ds<-list('core.source.capabilities'=o(state='suppressed'))
 rejects(function()f('.v2_capability_check')(ds,list()),'Capability inventory is required')
 f('.v2_capability_check')(ds,list(),requireEvidence=FALSE)
 # A streamed denominator includes target dimensions. No tx$one round trip.
 row<-o(row_key='',dimensions=o(gender_concept_id='0'),row_kind='counts',state='computed',reason_code=NULL,values=o(person_count='1'),denominator_refs=list(o(measure='person_count',metric_id='core.person.count',row_key=strrep('a',64),field='person_count',value='10')))
 row$row_key<-f('.v2_row_identity')(a$rows[['core.person.gender_count']],row)
 numeric<-structure(rep(list(NULL),14),names=c('record_count','person_count','person_days','interval_count','n','sum','min','max','p10','p25','p50','p75','p90','unused'))
 numeric$person_count<-'1';numeric$unused<-NULL
 ref<-c(row$denominator_refs[[1]],o(target_dimensions=o()))
 stored<-o(row_key=row$row_key,dimensions=row$dimensions,state='computed',reason_code=NULL,payload_kind='counts',route_key='A',sort_key=f('.v2_sort')(a$rows[['core.person.gender_count']],row),metadata=NULL,numeric=numeric,denominator_refs=list(ref))
 calls<-0L;received<-FALSE
 tx<-list(schema='"fixture"',one=function(...)stop('N+1 query attempted'),stream=function(sql,visit){calls<<-calls+1L;stopifnot(grepl("'target_dimensions',t.dimensions",sql,fixed=TRUE));visit(f('.json')(stored))})
 f('.store_rows')(tx,'00000000-0000-4000-8000-000000000001','core.person.gender_count',function(r,key){received<<-TRUE;stopifnot(identical(f('.json')(r),f('.json')(row)))})
 stopifnot(calls==1L,received)
 policy<-o(id='fixture',revision='1',scope_kind='restricted',allow_metrics=list('core.person.count'))
 path<-file.path(root,'PRIVATE_PATH_SENTINEL','export')
 rejects(function()publishResultRelease(list(dbms='postgresql'),'fixture','00000000-0000-4000-8000-000000000001',path,'fixture','fixture',policy,function(c)TRUE),'Export parent directory is unavailable')
 cat('PR16_OFFLINE_LOCK_CAPABILITY_MARGINAL_STREAM_AND_DIAGNOSTIC_REGRESSIONS_OK\n')
})
