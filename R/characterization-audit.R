# Fixed-size conservation inputs, independent of every derived report table.
# Match the legacy producer's physical staging totals, not sums of its outputs.
.render_source_audit <- function(person,raw,intervals,domains) {
  population<-paste0("(SELECT jsonb_build_object('person_count',COUNT(*)::text,'nonnull',COUNT(person_id)::text,",
    "'distinct',COUNT(DISTINCT person_id)::text,'raw_observation_count',(SELECT COUNT(*)::text FROM ",raw,"),",
    "'merged_interval_count',(SELECT COUNT(*)::text FROM ",intervals,")) FROM ",person,")")
  counts<-vapply(names(domains),function(domain)paste0(.store_literal(domain),
    ",(SELECT jsonb_build_object('raw',COUNT(*)::text,'linked',COUNT(*) FILTER(WHERE linked)::text,",
    "'observed',COUNT(*) FILTER(WHERE observed)::text,'start',MIN(event_date) FILTER(WHERE valid_date)::text,",
    "'end',MAX(event_date) FILTER(WHERE valid_date)::text) FROM ",domains[[domain]],")"),"")
  .object(format_version="1.0.0",kind="staged_source_audit_totals",
    sql=paste0("SELECT jsonb_build_object('population',",population,",'domains',jsonb_build_object(",paste(counts,collapse=","),"))::text"))
}
.sql_execution_audit_totals <- function(text) {
  totals<-tryCatch(.store_decode(text),error=function(e).sql_execution_error("execution.invalid_metadata"))
  keys<-function(value,expected).sql_execution_need(.nv_object(value)&&setequal(names(value),expected),"execution.invalid_metadata")
  counts<-function(value).sql_execution_need(all(vapply(value,.v2_count,TRUE)),"execution.invalid_metadata")
  less<-function(a,b).sql_execution_need(.nv_unsigned_cmp(a,b)<=0,"execution.invalid_metadata")
  keys(totals,c("population","domains"))
  p<-totals$population
  keys(p,c("person_count","nonnull","distinct","raw_observation_count","merged_interval_count"));counts(p)
  .sql_execution_need(identical(p$person_count,p$nonnull)&&identical(p$person_count,p$distinct),"execution.invalid_metadata")
  less(p$merged_interval_count,p$raw_observation_count)
  keys(totals$domains,.domain_names(TRUE))
  for(d in totals$domains) {
    keys(d,c("raw","linked","observed","start","end"));counts(d[c("raw","linked","observed")])
    less(d$observed,d$linked);less(d$linked,d$raw)
    .sql_execution_need((is.null(d$start)&&is.null(d$end))||
      (.nv_date(d$start)&&.nv_date(d$end)&&d$start<=d$end),"execution.invalid_metadata")
    if(p$person_count=="0").sql_execution_need(d$linked=="0","execution.invalid_metadata")
    if(d$raw=="0").sql_execution_need(is.null(d$start),"execution.invalid_metadata")
  }
  if(p$person_count=="0").sql_execution_need(p$merged_interval_count=="0","execution.invalid_metadata")
  totals
}
