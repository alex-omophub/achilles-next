.domain_names <- function(measurement=FALSE) c("condition","drug","procedure","visit","device","observation","death","specimen",if(measurement)"measurement" else character())
.domain_ids <- function(measurement=FALSE) {
  ids<-names(.v2_assets()$metrics)
  ids[vapply(strsplit(ids,".",fixed=TRUE),function(p)p[2]%in%c(.domain_names(measurement),"density"),TRUE)]
}
.domain_sql <- function(name,tokens) {
  stopifnot(name%in%c("counts","summary"))
  sql<-paste(readLines(system.file(paste0("sql/postgresql/domain-",name,".sql"),package="AchillesNext",mustWork=TRUE),warn=FALSE),collapse="\n")
  for(k in names(tokens))sql<-gsub(paste0("{{",k,"}}"),tokens[[k]],sql,fixed=TRUE)
  .population_need(!grepl("{{",sql,fixed=TRUE),"Unbound domain SQL token");sql
}
.domain_tag <- function(expr) paste0("CASE WHEN ",expr," IS NULL THEN jsonb_build_object('kind','null') ELSE jsonb_build_object('kind','id','value',",expr,"::text) END")
.domain_preflight <- function(tx,schema,measurement=FALSE) {
  assets<-.v2_assets();metadata<-list();tables<-c(vapply(assets$profile$domains[.domain_names(measurement)],function(d)d$table,""),"concept","measurement","care_site")
  tx$stream(paste0("SELECT jsonb_build_object('table',c.relname,'column',a.attname,'type',t.typname,'readable',has_schema_privilege(n.oid,'USAGE') AND has_column_privilege(c.oid,a.attname,'SELECT'))::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid JOIN pg_type t ON t.oid=a.atttypid WHERE n.nspname=",.store_literal(schema)," AND c.relkind IN ('r','p','v','m','f') AND a.attnum>0 AND NOT a.attisdropped AND c.relname IN (",paste(vapply(tables,.store_literal,""),collapse=","),")"),function(text){m<-.store_decode(text);metadata[[paste(m$table,m$column,sep=".")]]<<-m})
  aliases<-list('visit_occurrence.admitted_from_concept_id'=c('visit_occurrence.admitted_from_concept_id','visit_occurrence.admitting_source_concept_id'),
    'visit_occurrence.discharged_to_concept_id'=c('visit_occurrence.discharged_to_concept_id','visit_occurrence.discharge_to_concept_id'))
  column<-function(probe,required=TRUE) {
    choices<-aliases[[probe]] %||% probe;present<-choices[choices%in%names(metadata)]
    if(!length(present)){.population_need(!required,paste("Missing required domain column:",probe));return(NULL)}
    for(p in present) {
      m<-metadata[[p]];.population_need(isTRUE(m$readable),paste("Inaccessible domain column:",p))
      name<-sub(".*[.]","",p)
      types<-if(grepl("_datetime$",name))c("timestamp","timestamptz") else if(grepl("_date$",name))"date" else if(name%in%c("domain_id","value_as_string","value_source_value")||grepl("source_value$",name))c("text","varchar","bpchar") else if(name%in%c("quantity","value_as_number","range_low","range_high"))c("numeric","int2","int4","int8") else c("int2","int4","int8")
      .population_need(m$type%in%types,paste("Unsupported exact domain type:",p))
    }
    sub(".*[.]","",present)
  }
  needed<-unique(unlist(lapply(assets$metrics[.domain_ids(measurement)],function(m)setdiff(unlist(m$inputs),unlist(m$conditional_inputs)))))
  needed<-setdiff(needed,c("care_site.care_site_id","care_site.place_of_service_concept_id"))
  needed<-needed[!grepl("^(person|observation_period)[.]",needed)]
  for(p in unique(c(needed,"concept.concept_id","concept.domain_id","measurement.person_id")))column(p)
  for(table in setdiff(tables,"care_site")) {
    target<-paste0('"',schema,'"."',table,'"')
    .population_need(tx$one(paste0("SELECT (has_table_privilege(current_user,",.store_literal(target),",'INSERT,UPDATE,DELETE,TRUNCATE') OR has_any_column_privilege(current_user,",.store_literal(target),",'INSERT,UPDATE'))::text"))=="false","Use SELECT-only source privileges for domain generation")
  }
  conditional<-unique(unlist(lapply(assets$metrics[.domain_ids(measurement)],function(m)unlist(m$conditional_inputs))))
  for(p in setdiff(conditional,c("care_site.care_site_id","care_site.place_of_service_concept_id")))column(p,FALSE)
  list(metadata=metadata,column=column,hash=.hash(.json(metadata)))
}
