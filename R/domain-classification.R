.domain_prepare <- function(tx,schema,stage,person,intervals,cap,measurementMode=FALSE) {
  assets<-.v2_assets();source<-paste0('"',schema,'"');tables<-list();counts<-list();unsupported<-list()
  .population_need(tx$one(paste0("SELECT COUNT(*)::text FROM (SELECT concept_id FROM ",source,".concept GROUP BY concept_id HAVING COUNT(DISTINCT domain_id)>1 OR (COUNT(domain_id)>0 AND COUNT(domain_id)<COUNT(*))) x"))=="0","Ambiguous local concept domains; generation rolled back")
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
  for(domain in .domain_names(measurementMode)) {
    built<-.domain_source_fields(domain,cap,vocabulary,care,function(name,required=TRUE)col(domain,name,required))
    fields<-built$fields;unsupported<-c(unsupported,built$unsupported);d<-assets$profile$domains[[domain]]
    raw<-stage(paste0(domain,"raw"),paste0("SELECT ",paste(paste0(unlist(fields),' AS "',names(fields),'"'),collapse=",")," FROM ",source,'."',d$table,'" e'))
    classification<-.domain_classification_sql(domain,raw,person,intervals,vocabulary)
    tables[[domain]]<-stage(paste0(domain,"class"),classification,"person_id,event_date")
    counts[[domain]]<-.store_decode(tx$one(paste0("SELECT jsonb_build_object('raw',COUNT(*)::text,'linked',COUNT(*) FILTER(WHERE linked)::text,'observed',COUNT(*) FILTER(WHERE observed)::text,'start',MIN(event_date) FILTER(WHERE valid_date)::text,'end',MAX(event_date) FILTER(WHERE valid_date)::text)::text FROM ",tables[[domain]])))
    tx$execute(paste("DROP TABLE",raw))
  }
  measurement<-if(measurementMode)tables$measurement else stage("measurepresence",paste0("SELECT DISTINCT m.person_id FROM ",source,".measurement m JOIN ",person," p USING(person_id)"),"person_id")
  list(tables=tables,counts=counts,unsupported=unsupported,care_reason=careReason,measurement=measurement)
}
