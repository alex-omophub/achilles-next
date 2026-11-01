# Internal physical primitives used to qualify the planner. These deliberately
# do not claim to implement all registered domain-specific output fields.
.batch_template <- function(name,tokens) {
  stopifnot(name%in%c("observation-union","classification","capture","numeric","coverage","periods"))
  path<-system.file(paste0("sql/postgresql/batch-",name,".sql"),package="AchillesNext",mustWork=TRUE)
  sql<-paste(readLines(path,warn=FALSE),collapse="\n")
  for(k in names(tokens)) sql<-gsub(paste0("{{",k,"}}"),tokens[[k]],sql,fixed=TRUE)
  if(grepl("{{",sql,fixed=TRUE)) stop("Unbound batch SQL token",call.=FALSE)
  sql
}
.batch_interval_sql <- function(plan) .batch_template("observation-union",list(schema=plan$source$cdm_schema))
.batch_classification_sql <- function(plan,domain) {
  domains<-.v2_assets()$profile$domains
  if(!.string(domain) || !domain%in%names(domains)) stop("Unknown batch domain",call.=FALSE)
  d<-domains[[domain]];numeric<-domain%in%c("measurement","observation")
  .batch_template("classification",list(schema=plan$source$cdm_schema,concept=d$concept,event_date=d$event_date,table=d$table,
    numeric_value=if(numeric)'e.value_as_number' else 'NULL::numeric',unit=if(numeric)'e.unit_concept_id' else 'NULL::integer',
    operator=if(domain=="measurement")'e.operator_concept_id' else 'NULL::integer'))
}
.batch_capture_sql <- function(window) {
  if(is.null(window)) stop("Resolve finite source-derived history before compiling period probes",call.=FALSE)
  .batch_template("capture",c(list(periods=.batch_template("periods",window)),window))
}
.batch_coverage_sql <- function(plan) {
  window<-plan$scope$observed_window
  if(is.null(window)) stop("Resolve finite source-derived history before compiling period probes",call.=FALSE)
  .batch_template("coverage",list(periods=.batch_template("periods",window)))
}
.batch_numeric_sql <- function(strategy="reference") {
  if(!.string(strategy) || !strategy%in%c("reference","weighted")) stop("Invalid exact numeric strategy",call.=FALSE)
  ranks<-if(strategy=="reference") paste(
    "ranked AS (SELECT concept_id,unit_concept_id,operator_concept_id,value_as_number AS value,",
    "COUNT(*) OVER(PARTITION BY concept_id,unit_concept_id,operator_concept_id)::numeric AS n,",
    "ROW_NUMBER() OVER(PARTITION BY concept_id,unit_concept_id,operator_concept_id ORDER BY value_as_number)::numeric AS rank_index",
    "FROM eligible)") else paste(
    "frequencies AS (SELECT concept_id,unit_concept_id,operator_concept_id,value_as_number AS value,COUNT(*)::numeric AS frequency",
    "FROM eligible GROUP BY concept_id,unit_concept_id,operator_concept_id,value_as_number),",
    "ranked AS (SELECT *,SUM(frequency) OVER(PARTITION BY concept_id,unit_concept_id,operator_concept_id) AS n,",
    "SUM(frequency) OVER(PARTITION BY concept_id,unit_concept_id,operator_concept_id ORDER BY value ROWS UNBOUNDED PRECEDING) AS cumulative_n FROM frequencies)")
  .batch_template("numeric",list(ranks=ranks,rank=if(strategy=="reference")"rank_index" else "cumulative_n",
    sum_value=if(strategy=="reference")"value" else "value*frequency"))
}
.batch_reference_sql <- function(plan,domain,query) paste0(
  "WITH intervals AS (",.batch_interval_sql(plan),"), classified AS (",.batch_classification_sql(plan,domain),") SELECT * FROM (",query,") output")
