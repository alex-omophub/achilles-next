# Pure source SQL shared by the offline renderer and existing producers.
.domain_source_fields <- function(domain,cap,vocabulary,care,column) {
  assets<-.v2_assets();unsupported<-list()
  d<-assets$profile$domains[[domain]];mid<-paste0("core.",domain,".")
  e<-function(name,default="NULL::bigint",required=TRUE)if(is.null(name))default else column(name,required) %||% default
  date<-e(d$event_date);end<-e(d$end_date,"NULL::date",domain!="procedure")
  id<-if(domain=="death")"e.person_id" else e(d$record_id)
  fields<-list(person_id="e.person_id",concept_id=e(d$concept),event_date=date,end_date=end,
    source_tag=if(is.null(d$source_concept))"jsonb_build_object('kind','schema_absent')" else .domain_tag(e(d$source_concept)),
    source_state=paste0("CASE WHEN ",e(d$source_text,'NULL::text')," IS NULL THEN 'null' WHEN btrim(",e(d$source_text),",' ')='' THEN 'blank' ELSE 'nonblank' END"),
    type_tag=.domain_tag(e(d$type_concept)),duplicated=paste0("(",id," IS NOT NULL AND COUNT(*) OVER(PARTITION BY ",id,")>1)"))
  if(domain=="condition")fields$status_tag<-.domain_tag(e("condition_status_concept_id"))
  if(domain=="drug")for(k in c("days_supply","refills","quantity"))fields[[k]]<-paste0(e(k),"::numeric")
  if(domain=="visit") {
    fields$admitted_tag<-.domain_tag(e("admitted_from_concept_id"));fields$discharged_tag<-.domain_tag(e("discharged_to_concept_id"))
    fields$care_tag<-if(is.null(care))"jsonb_build_object('kind','schema_absent')" else .domain_tag(paste0("(SELECT place_of_service_concept_id FROM ",care," s WHERE s.care_site_id=",e('care_site_id'),")"))
  }
  if(domain=="procedure") {
    fields$start_datetime<-e('procedure_datetime','NULL::timestamp')
    fields$end_datetime<-e('procedure_end_datetime','NULL::timestamp',FALSE)
    if(is.null(column('procedure_end_date',FALSE))||is.null(column('procedure_end_datetime',FALSE)))unsupported[[paste0(mid,"end_precision_count")]]<-"capability.procedure_end_absent"
  }
  if(domain%in%c("device","specimen")) {
    unit<-e('unit_concept_id','NULL::bigint',domain!="device");fields$quantity<-paste0(e('quantity'),"::numeric")
    fields$unit_tag<-if(domain=="device"&&is.null(column('unit_concept_id',FALSE)))"jsonb_build_object('kind','schema_absent')" else .domain_tag(unit)
  }
  if(domain=="device") {
    available<-vapply(c('unit_concept_id','unit_source_value','unit_source_concept_id'),function(k)!is.null(column(k,FALSE)),TRUE)
    if(!all(available))unsupported[[paste0(mid,"unit_count")]]<-"capability.device_unit_absent"
    text<-e('unit_source_value','NULL::text',FALSE)
    fields$source_unit_presence<-if(!available[2])"'schema_absent'::text" else paste0("CASE WHEN ",text," IS NULL THEN 'null' WHEN btrim(",text,",' ')='' THEN 'blank' ELSE 'nonblank' END")
  }
  if(domain=="specimen") {
    fields$site_tag<-.domain_tag(e('anatomic_site_concept_id'));fields$disease_tag<-.domain_tag(e('disease_status_concept_id'))
    links<-c('visit_occurrence_id','visit_detail_id')
    if(!all(vapply(links,function(k)!is.null(column(k,FALSE)),TRUE)))unsupported[[paste0(mid,"visit_link_presence_count")]]<-"capability.specimen_links_absent"
    for(k in links)fields[[paste0(k,'_present')]]<-paste0(e(k,'NULL::bigint',FALSE)," IS NOT NULL")
  }
  if(domain=="observation") {
    fields$value_as_number<-paste0(e('value_as_number'),"::numeric");fields$value_concept_tag<-.domain_tag(e('value_as_concept_id'))
    fields$unit_id<-e('unit_concept_id');fields$unit_tag<-.domain_tag(fields$unit_id);fields$qualifier_tag<-.domain_tag(e('qualifier_concept_id'))
    flags<-c(paste0("(",e('value_as_number')," IS NOT NULL)::integer::text"),paste0("(",e('value_as_concept_id')," IS NOT NULL AND ",e('value_as_concept_id'),"<>0)::integer::text"))
    for(k in c('value_source_value','value_as_string','value_as_date')) {
      c<-column(k,k=='value_as_string')
      flags<-c(flags,if(is.null(c))"'X'" else if(k=='value_as_date')paste0("(",c," IS NOT NULL)::integer::text") else paste0("(",c," IS NOT NULL AND btrim(",c,",' ')<>'')::integer::text"))
    }
    fields$representation_flags<-paste(flags,collapse="||")
    fields$known_unit<-paste0("EXISTS(SELECT 1 FROM ",vocabulary," v WHERE v.concept_id=",fields$unit_id," AND v.concept_id>0 AND v.domain_id='Unit')")
  }
  if(domain=="measurement") {
    fields$value_as_number<-paste0(e('value_as_number'),"::numeric");fields$value_concept_tag<-.domain_tag(e('value_as_concept_id'))
    fields$unit_id<-e('unit_concept_id');fields$unit_tag<-.domain_tag(fields$unit_id)
    fields$operator_id<-e('operator_concept_id');fields$operator_tag<-.domain_tag(fields$operator_id)
    fields$range_low<-paste0(e('range_low'),"::numeric");fields$range_high<-paste0(e('range_high'),"::numeric")
    fields$representation_flags<-paste(c(paste0("(",e('value_as_number')," IS NOT NULL)::integer::text"),
      paste0("(",e('value_as_concept_id')," IS NOT NULL AND ",e('value_as_concept_id'),"<>0)::integer::text"),
      paste0("(",e('value_source_value')," IS NOT NULL AND btrim(",e('value_source_value'),",' ')<>'')::integer::text")),collapse="||")
    fields$known_unit<-paste0("EXISTS(SELECT 1 FROM ",vocabulary," v WHERE v.concept_id=",fields$unit_id," AND v.concept_id>0 AND v.domain_id='Unit')")
  }
  list(fields=fields,unsupported=unsupported)
}
.domain_classification_sql <- function(domain,raw,person,intervals,vocabulary) {
  d<-.v2_assets()$profile$domains[[domain]]
  paste0("SELECT r.*,",.domain_tag('r.concept_id')," AS concept_tag,p.year_of_birth,p.gender_concept_id,p.person_id IS NOT NULL AS linked,",
    "(r.event_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31') IS TRUE AS valid_date,",
    "EXISTS(SELECT 1 FROM ",intervals," i WHERE i.person_id=r.person_id AND r.event_date BETWEEN i.start_date AND i.end_date) AS observed,",
    "v.concept_id IS NOT NULL AS known_concept,(v.domain_id IN (",paste(vapply(unlist(d$expected_concept_domains),.store_literal,""),collapse=","),")) IS TRUE AS right_domain,",
    "CASE WHEN p.person_id IS NULL THEN 'null_or_orphan_person' WHEN r.event_date IS NULL OR NOT(r.event_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31') THEN 'undated' WHEN NOT EXISTS(SELECT 1 FROM ",intervals," i WHERE i.person_id=r.person_id) THEN 'no_valid_intervals' WHEN EXISTS(SELECT 1 FROM ",intervals," i WHERE i.person_id=r.person_id AND r.event_date BETWEEN i.start_date AND i.end_date) THEN 'inside_valid_union' ELSE 'outside_valid_union' END AS qualification FROM ",raw," r LEFT JOIN ",person," p USING(person_id) LEFT JOIN ",vocabulary," v ON v.concept_id=r.concept_id")
}

.population_source_sql <- function(kind,source,person=NULL) {
  switch(kind,person=paste0("SELECT person_id,year_of_birth,gender_concept_id,race_concept_id,ethnicity_concept_id FROM ",source,".person"),
    raw=paste0("SELECT o.person_id,o.observation_period_start_date AS start_date,o.observation_period_end_date AS end_date,o.period_type_concept_id,CASE WHEN o.person_id IS NULL THEN 'null_person' WHEN NOT EXISTS(SELECT 1 FROM ",person," p WHERE p.person_id=o.person_id) THEN 'orphan_person' WHEN o.observation_period_start_date IS NULL OR o.observation_period_end_date IS NULL THEN 'null_endpoints' WHEN o.observation_period_start_date>o.observation_period_end_date THEN 'reversed_interval' ELSE 'valid' END AS reason FROM ",source,".observation_period o"),stop("Unknown population source SQL",call.=FALSE))
}
