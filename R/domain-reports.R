# Domain reports operate only on narrow, transaction-private stages. They never
# issue a source query per concept, export source strings, or expand PERSON by
# every concept. All counts and quantiles remain PostgreSQL exact NUMERIC.
.domain_reports <- function(domain,table,person,periods,cap) {
  core<-paste0('core.',domain);observed<-paste0('observed.',domain)
  parts<-list(.domain_sql('counts',list(classified=table,person=person,periods=periods,core=core,observed=observed)))
  add<-function(sql)parts[[length(parts)+1L]]<<-sql
  counts<-function(suffix,dims,from=table,people=TRUE)paste0("SELECT '",core,'.',suffix,"'::text AS metric_id,'counts'::text AS row_kind,dimensions,",
    "jsonb_build_object('record_count',COUNT(*)::text",if(people)", 'person_count',COUNT(DISTINCT person_id) FILTER(WHERE linked)::text" else '',") AS values FROM (SELECT *,",dims," AS dimensions FROM ",from,") x GROUP BY dimensions")
  dims<-function(...)paste0('jsonb_build_object(',paste(c(...),collapse=','),')')
  concept<-"'concept_tag',concept_tag"
  flags<-c(null_person='person_id IS NULL',orphan_person='person_id IS NOT NULL AND NOT linked',missing_date='event_date IS NULL',invalid_date='event_date IS NOT NULL AND NOT valid_date',
    null_concept='concept_id IS NULL',zero_concept='concept_id=0',unknown_concept='concept_id IS NOT NULL AND concept_id<>0 AND NOT known_concept',wrong_domain_concept='concept_id<>0 AND known_concept AND NOT right_domain')
  if(!is.null(.v2_assets()$profile$domains[[domain]]$end_date) && (domain!='procedure'||!is.null(cap$column('procedure_occurrence.procedure_end_date',FALSE))))
    flags<-c(flags,missing_end='end_date IS NULL',reversed_end='valid_date AND end_date BETWEEN DATE \'0001-01-01\' AND DATE \'9999-12-31\' AND end_date<event_date')
  flags<-c(flags,stats::setNames('duplicated',if(domain=='death')'repeated_person_rows' else 'duplicate_record_id'))
  add(paste0("SELECT '",core,".integrity_count','counts',jsonb_build_object('flag',f.flag,'present',b.present::text),jsonb_build_object('record_count',COUNT(c.present)::text) FROM (VALUES ",
    paste(vapply(names(flags),function(k)paste0('(', .store_literal(k),')'),''),collapse=','),") f(flag) CROSS JOIN (VALUES(true),(false)) b(present) LEFT JOIN (SELECT v.flag,v.present FROM ",table,
    " CROSS JOIN LATERAL (VALUES ",paste(vapply(names(flags),function(k)paste0('(',.store_literal(k),',(',flags[[k]],') IS TRUE)'),''),collapse=','),") v(flag,present)) c ON c.flag=f.flag AND c.present=b.present GROUP BY f.flag,b.present"))
  # One earliest finite dated event per linked person/concept, including a NULL
  # date group for people whose records are all undated/invalid.
  first<-paste0('(SELECT concept_tag,person_id,gender_concept_id,year_of_birth,MIN(event_date) FILTER(WHERE valid_date) AS first_date FROM ',table,' WHERE linked GROUP BY concept_tag,person_id,gender_concept_id,year_of_birth) f')
  age<-"EXTRACT(YEAR FROM first_date)::numeric-year_of_birth::numeric"
  samples<-list(paste0("SELECT '",core,".first_age_summary'::text AS metric_id,",dims(concept,"'gender_concept_id',COALESCE(gender_concept_id::text,'null')")," AS dimensions,CASE WHEN first_date IS NOT NULL AND year_of_birth BETWEEN 1 AND 9999 AND ",age," BETWEEN 0 AND 130 THEN ",age," END AS value,CASE WHEN first_date IS NULL THEN 'event_date_missing_or_invalid' WHEN year_of_birth IS NULL OR year_of_birth NOT BETWEEN 1 AND 9999 THEN 'birth_year_missing_or_invalid' WHEN ",age," NOT BETWEEN 0 AND 130 THEN 'year_age_outside_0_130' ELSE 'eligible' END AS reason FROM ",first))
  categories<-list();reasons<-.v2_assets()$profile$contracts$`eligibility-reasons`
  category<-function(suffix,order,measure='record_count')for(reason in unlist(order))categories[[length(categories)+1L]]<<-paste0('(', .store_literal(paste0(core,'.',suffix)),',',.store_literal(reason),',',.store_literal(measure),')')
  category('first_age_summary',reasons$age_order,'person_count')
  sample<-function(suffix,dimensions,value,reason,from=table,order=reasons$nonnegative_scalar_order) {
    samples[[length(samples)+1L]]<<-paste0('SELECT ',.store_literal(paste0(core,'.',suffix)),',',dimensions,',',value,',',reason,' FROM ',from)
    category(suffix,order)
  }
  scalar<-function(name,dimensions=dims(concept))sample(paste0(name,'_summary'),dimensions,name,paste0("CASE WHEN ",name," IS NULL THEN 'value_missing' WHEN ",name,"::text IN ('NaN','Infinity','-Infinity') THEN 'value_non_finite' WHEN ",name,"<0 THEN 'value_negative' ELSE 'eligible' END"))
  if(domain=='condition')add(counts('status_type_count',dims(concept,"'status_concept_tag',status_tag","'type_concept_tag',type_tag")))
  if(domain=='drug')for(k in c('days_supply','refills','quantity'))scalar(k)
  if(domain=='visit') {
    sample('duration_summary',dims(concept),"CASE WHEN valid_date AND end_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31' AND end_date>=event_date THEN (end_date-event_date)::numeric END",
      "CASE WHEN NOT valid_date THEN 'start_missing_or_invalid' WHEN end_date IS NULL OR NOT(end_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31') THEN 'end_missing_or_invalid' WHEN end_date<event_date THEN 'end_before_start' ELSE 'eligible' END",order=reasons$elapsed_duration_order)
    from<-paste0(table," CROSS JOIN LATERAL (VALUES('visit',concept_tag),('admitted_from',admitted_tag),('discharged_to',discharged_tag),('place_of_service',care_tag)) setting(setting_kind,setting_tag)")
    add(counts('care_setting_count',dims(concept,"'setting_kind',setting_kind","'setting_concept_tag',setting_tag"),from))
  }
  if(domain=='procedure'&&!is.null(cap$column('procedure_occurrence.procedure_end_date',FALSE))&&!is.null(cap$column('procedure_occurrence.procedure_end_datetime',FALSE))) {
    pairs<-c("(CASE WHEN event_date IS NULL AND start_datetime IS NULL THEN 'start_absent' WHEN event_date IS NULL THEN 'start_datetime_only' WHEN start_datetime IS NULL THEN 'start_date_only' ELSE 'start_date_and_datetime' END,true)",
      "(CASE WHEN end_date IS NULL AND end_datetime IS NULL THEN 'end_absent' WHEN end_date IS NULL THEN 'end_datetime_only' WHEN end_datetime IS NULL THEN 'end_date_only' ELSE 'end_date_and_datetime' END,true)",
      "('missing_duration',event_date IS NULL OR end_date IS NULL)","('negative_duration',end_date<event_date)","('start_disagreement',event_date<>start_datetime::date)","('end_disagreement',end_date<>end_datetime::date)")
    add(counts('end_precision_count',dims(concept,"'reason',reason"),paste0('(SELECT c.*,v.reason FROM ',table,' c CROSS JOIN LATERAL (VALUES ',paste(pairs,collapse=','),') v(reason,present) WHERE v.present IS TRUE) precision')))
  }
  if(domain%in%c('device','specimen'))scalar('quantity',dims(concept,"'unit_concept_tag',unit_tag"))
  if(domain=='device'&&all(vapply(c('unit_concept_id','unit_source_value','unit_source_concept_id'),function(k)!is.null(cap$column(paste0('device_exposure.',k),FALSE)),TRUE)))
    add(counts('unit_count',dims(concept,"'unit_concept_tag',unit_tag","'source_unit_presence',source_unit_presence")))
  if(domain=='specimen') {
    add(counts('site_status_count',dims(concept,"'dimension_kind',dimension_kind","'dimension_concept_tag',dimension_tag"),paste0(table," CROSS JOIN LATERAL (VALUES('anatomic_site',site_tag),('disease_status',disease_tag)) v(dimension_kind,dimension_tag)")))
    if(all(vapply(c('visit_occurrence_id','visit_detail_id'),function(k)!is.null(cap$column(paste0('specimen.',k),FALSE)),TRUE)))
      add(counts('visit_link_presence_count',dims(concept,"'link_kind',link_kind","'present',present::text"),paste0(table," CROSS JOIN LATERAL (VALUES('visit_occurrence',visit_occurrence_id_present),('visit_detail',visit_detail_id_present)) v(link_kind,present)")))
  }
  if(domain=='observation') {
    for(pair in list(c('unit_count','unit_concept_tag','unit_tag'),c('coded_value_count','value_concept_tag','value_concept_tag'),c('qualifier_count','qualifier_concept_tag','qualifier_tag')))
      add(counts(pair[1],dims(concept,paste0("'",pair[2],"',",pair[3]))))
    reason<-"CASE WHEN value_as_number IS NULL THEN 'numeric_missing' WHEN value_as_number::text IN ('NaN','Infinity','-Infinity') THEN 'numeric_non_finite' WHEN unit_id IS NULL THEN 'unit_null' WHEN unit_id=0 THEN 'unit_zero' WHEN NOT known_unit THEN 'unit_unrecognized' ELSE 'eligible' END"
    add(counts('numeric_eligibility_count',dims(concept,paste0("'reason',",reason)),people=FALSE))
    sample('numeric_summary',dims(concept,"'unit_concept_tag',unit_tag"),'value_as_number',reason,paste0('(SELECT * FROM ',table,' WHERE known_unit) known'),order=setdiff(unlist(reasons$numeric_summary_order),'operator_explicit_measurement_only'))
    supported<-lapply(c('value_source_value','value_as_date'),function(k)if(is.null(cap$column(paste0('observation.',k),FALSE)))"(VALUES('X'))" else "(VALUES('0'),('1'))")
    add(paste0("SELECT '",core,".representation_count','counts',jsonb_build_object('concept_tag',g.concept_tag,'representation_flags',flags),jsonb_build_object('record_count',COUNT(c.representation_flags)::text,'person_count',COUNT(DISTINCT c.person_id) FILTER(WHERE c.linked)::text) FROM (SELECT DISTINCT concept_tag FROM ",table,") g CROSS JOIN (SELECT a.v||b.v||c.v||d.v||e.v AS flags FROM (VALUES('0'),('1')) a(v) CROSS JOIN (VALUES('0'),('1')) b(v) CROSS JOIN ",supported[[1]]," c(v) CROSS JOIN (VALUES('0'),('1')) d(v) CROSS JOIN ",supported[[2]]," e(v)) f LEFT JOIN ",table," c ON c.concept_tag=g.concept_tag AND c.representation_flags=f.flags GROUP BY g.concept_tag,flags"))
  }
  add(.domain_sql('summary',list(samples=paste(samples,collapse=' UNION ALL '),categories=paste0('SELECT * FROM (VALUES ',paste(categories,collapse=','),') v(metric_id,reason,measure)'))))
  paste(vapply(parts,function(p)paste0('SELECT * FROM (',p,') report'),''),collapse=' UNION ALL ')
}
.domain_density <- function(person,domains,measurement) {
  expressions<-vapply(c(unlist(domains),measurement),function(t)paste0('(EXISTS(SELECT 1 FROM ',t,' d WHERE d.person_id=p.person_id))::integer::text'),'')
  paste0("WITH patterns AS (SELECT ",paste(expressions,collapse='||')," AS bits FROM ",person," p), histogram AS (SELECT bits,COUNT(*)::numeric AS n FROM patterns GROUP BY bits) SELECT 'core.density.domain_presence_count'::text AS metric_id,'counts'::text AS row_kind,jsonb_build_object('presence_bits',bits) AS dimensions,jsonb_build_object('person_count',n::text) AS values FROM histogram UNION ALL SELECT 'core.density.domain_count','counts',jsonb_build_object('domain_count',length(replace(bits,'0',''))::text),jsonb_build_object('person_count',SUM(n)::text) FROM histogram GROUP BY length(replace(bits,'0',''))")
}
.domain_periods <- function(bounds) {
  start<-if(is.null(bounds$start))'NULL' else paste0('DATE ',.store_literal(bounds$start));end<-if(is.null(bounds$end))'NULL' else paste0('DATE ',.store_literal(bounds$end))
  paste0("WITH bounds AS (SELECT ",start,"::date AS lo,",end,"::date AS hi) SELECT 'full_scope'::text AS period_kind,NULL::date AS period_start,NULL::date AS period_end,FALSE AS full_calendar_period UNION ALL SELECT 'calendar_month',d::date,(d+INTERVAL '1 month - 1 day')::date,TRUE FROM bounds CROSS JOIN LATERAL generate_series(date_trunc('month',lo),date_trunc('month',hi),INTERVAL '1 month') d UNION ALL SELECT 'calendar_year',d::date,(d+INTERVAL '1 year - 1 day')::date,TRUE FROM bounds CROSS JOIN LATERAL generate_series(date_trunc('year',lo),date_trunc('year',hi),INTERVAL '1 year') d")
}
