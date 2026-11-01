.domain_prepare <- function(tx,schema,stage,person,intervals,cap) {
  assets<-.v2_assets();source<-paste0('"',schema,'"');tables<-list();counts<-list();unsupported<-list()
  .population_need(tx$one(paste0("SELECT COUNT(*)::text FROM (SELECT concept_id FROM ",source,".concept GROUP BY concept_id HAVING COUNT(DISTINCT domain_id)>1) x"))=="0","Ambiguous local concept domains; generation rolled back")
  vocabulary<-stage("vocab",paste0("SELECT concept_id,MIN(domain_id) AS domain_id FROM ",source,".concept GROUP BY concept_id"),"concept_id")
  col<-function(domain,name,required=TRUE) {
    table<-assets$profile$domains[[domain]]$table;found<-cap$column(paste(table,name,sep="."),required)
    if(!length(found))return(NULL)
    expr<-paste0('e."',found,'"')
    if(length(expr)>1L) {
      .population_need(tx$one(paste0("SELECT count(*)::text FROM ",source,'."',table,'" e WHERE ',expr[1]," IS NOT NULL AND ",expr[2]," IS NOT NULL AND ",expr[1],"<>",expr[2]))=="0","Conflicting populated visit aliases")
      paste0("COALESCE(",paste(expr,collapse=","),")")
    } else expr
  }
  careProbes<-c('care_site.care_site_id','care_site.place_of_service_concept_id')
  careMeta<-cap$metadata[careProbes]
  careReason<-if(any(vapply(careMeta,is.null,TRUE)))"capability.care_site_absent" else if(!all(vapply(careMeta,function(m)isTRUE(m$readable),TRUE)))"capability.care_site_denied" else NULL
  care<-NULL
  if(is.null(careReason)) {
    .population_need(all(vapply(careMeta,function(m)m$type%in%c('int2','int4','int8'),TRUE)),"Unsupported CARE_SITE type")
    .population_need(tx$one(paste0("SELECT (has_table_privilege(current_user,",.store_literal(paste0(source,'.care_site')),",'INSERT,UPDATE,DELETE,TRUNCATE') OR has_any_column_privilege(current_user,",.store_literal(paste0(source,'.care_site')),",'INSERT,UPDATE'))::text"))=="false","Use SELECT-only CARE_SITE source privileges")
    if(tx$one(paste0("SELECT count(*)::text FROM (SELECT care_site_id FROM ",source,".care_site WHERE care_site_id IS NOT NULL GROUP BY care_site_id HAVING COUNT(*)>1) x"))!="0")careReason<-"capability.care_site_ambiguous" else
      care<-stage("care",paste0("SELECT care_site_id,place_of_service_concept_id FROM ",source,".care_site"),"care_site_id")
  }
  for(domain in .domain_names()) {
    d<-assets$profile$domains[[domain]];mid<-paste0("core.",domain,".")
    e<-function(name,default="NULL::bigint",required=TRUE)if(is.null(name))default else col(domain,name,required) %||% default
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
      if(is.null(col(domain,'procedure_end_date',FALSE))||is.null(col(domain,'procedure_end_datetime',FALSE)))unsupported[[paste0(mid,"end_precision_count")]]<-"capability.procedure_end_absent"
    }
    if(domain%in%c("device","specimen")) {
      unit<-e('unit_concept_id','NULL::bigint',domain!="device");fields$quantity<-paste0(e('quantity'),"::numeric")
      fields$unit_tag<-if(domain=="device"&&is.null(col(domain,'unit_concept_id',FALSE)))"jsonb_build_object('kind','schema_absent')" else .domain_tag(unit)
    }
    if(domain=="device") {
      available<-vapply(c('unit_concept_id','unit_source_value','unit_source_concept_id'),function(k)!is.null(col(domain,k,FALSE)),TRUE)
      if(!all(available))unsupported[[paste0(mid,"unit_count")]]<-"capability.device_unit_absent"
      text<-e('unit_source_value','NULL::text',FALSE)
      fields$source_unit_presence<-if(!available[2])"'schema_absent'::text" else paste0("CASE WHEN ",text," IS NULL THEN 'null' WHEN btrim(",text,",' ')='' THEN 'blank' ELSE 'nonblank' END")
    }
    if(domain=="specimen") {
      fields$site_tag<-.domain_tag(e('anatomic_site_concept_id'));fields$disease_tag<-.domain_tag(e('disease_status_concept_id'))
      links<-c('visit_occurrence_id','visit_detail_id')
      if(!all(vapply(links,function(k)!is.null(col(domain,k,FALSE)),TRUE)))unsupported[[paste0(mid,"visit_link_presence_count")]]<-"capability.specimen_links_absent"
      for(k in links)fields[[paste0(k,'_present')]]<-paste0(e(k,'NULL::bigint',FALSE)," IS NOT NULL")
    }
    if(domain=="observation") {
      fields$value_as_number<-paste0(e('value_as_number'),"::numeric");fields$value_concept_tag<-.domain_tag(e('value_as_concept_id'))
      fields$unit_id<-e('unit_concept_id');fields$unit_tag<-.domain_tag(fields$unit_id);fields$qualifier_tag<-.domain_tag(e('qualifier_concept_id'))
      flags<-c(paste0("(",e('value_as_number')," IS NOT NULL)::integer::text"),paste0("(",e('value_as_concept_id')," IS NOT NULL AND ",e('value_as_concept_id'),"<>0)::integer::text"))
      for(k in c('value_source_value','value_as_string','value_as_date')) {
        c<-col(domain,k,k=='value_as_string')
        flags<-c(flags,if(is.null(c))"'X'" else if(k=='value_as_date')paste0("(",c," IS NOT NULL)::integer::text") else paste0("(",c," IS NOT NULL AND btrim(",c,",' ')<>'')::integer::text"))
      }
      fields$representation_flags<-paste(flags,collapse="||")
      fields$known_unit<-paste0("EXISTS(SELECT 1 FROM ",vocabulary," v WHERE v.concept_id=",fields$unit_id," AND v.concept_id>0 AND v.domain_id='Unit')")
    }
    raw<-stage(paste0(domain,"raw"),paste0("SELECT ",paste(paste0(unlist(fields),' AS "',names(fields),'"'),collapse=",")," FROM ",source,'."',d$table,'" e'))
    classification<-paste0("SELECT r.*,",.domain_tag('r.concept_id')," AS concept_tag,p.year_of_birth,p.gender_concept_id,p.person_id IS NOT NULL AS linked,",
      "(r.event_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31') IS TRUE AS valid_date,",
      "EXISTS(SELECT 1 FROM ",intervals," i WHERE i.person_id=r.person_id AND r.event_date BETWEEN i.start_date AND i.end_date) AS observed,",
      "v.concept_id IS NOT NULL AS known_concept,(v.domain_id IN (",paste(vapply(unlist(d$expected_concept_domains),.store_literal,""),collapse=","),")) IS TRUE AS right_domain,",
      "CASE WHEN p.person_id IS NULL THEN 'null_or_orphan_person' WHEN r.event_date IS NULL OR NOT(r.event_date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31') THEN 'undated' WHEN NOT EXISTS(SELECT 1 FROM ",intervals," i WHERE i.person_id=r.person_id) THEN 'no_valid_intervals' WHEN EXISTS(SELECT 1 FROM ",intervals," i WHERE i.person_id=r.person_id AND r.event_date BETWEEN i.start_date AND i.end_date) THEN 'inside_valid_union' ELSE 'outside_valid_union' END AS qualification FROM ",raw," r LEFT JOIN ",person," p USING(person_id) LEFT JOIN ",vocabulary," v ON v.concept_id=r.concept_id")
    tables[[domain]]<-stage(paste0(domain,"class"),classification,"person_id,event_date")
    counts[[domain]]<-.store_decode(tx$one(paste0("SELECT jsonb_build_object('raw',COUNT(*)::text,'linked',COUNT(*) FILTER(WHERE linked)::text,'observed',COUNT(*) FILTER(WHERE observed)::text,'start',MIN(event_date) FILTER(WHERE valid_date)::text,'end',MAX(event_date) FILTER(WHERE valid_date)::text)::text FROM ",tables[[domain]])))
    tx$execute(paste("DROP TABLE",raw))
  }
  measurement<-stage("measurepresence",paste0("SELECT DISTINCT m.person_id FROM ",source,".measurement m JOIN ",person," p USING(person_id)"),"person_id")
  list(tables=tables,counts=counts,unsupported=unsupported,care_reason=careReason,measurement=measurement)
}
