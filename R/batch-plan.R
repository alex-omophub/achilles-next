# Pure planning for the complete core profile; no connection or source SQL.
.batch_identifier <- function(x) .string(x) && grepl("^[a-z][a-z0-9_]{0,62}$", x) &&
  !grepl("^pg_|^information_schema$", x)
.batch_date <- function(x) .nv_date(x)
.batch_assets <- function() {
  path <- system.file("analysis/core-batch-plan-v1.json", package="AchillesNext", mustWork=TRUE)
  lock <- jsonlite::fromJSON(system.file("analysis/batch-plan-lock.json",package="AchillesNext",mustWork=TRUE),simplifyVector=FALSE)
  if (!identical(digest::digest(file=path,algo="sha256"),lock$sha256[[basename(path)]])) stop("Batch plan integrity failure",call.=FALSE)
  registry <- jsonlite::fromJSON(path,simplifyVector=FALSE)
  assets <- .v2_assets()
  if (!identical(registry$profile_sha256,assets$hash)) stop("Batch/profile identity mismatch",call.=FALSE)
  ids <- vapply(registry$modules,function(m)m$id,"")
  outputs <- unlist(lapply(registry$modules,function(m)unlist(m$metric_ids)),use.names=FALSE)
  if (anyDuplicated(ids) || anyDuplicated(outputs) || !setequal(outputs,names(assets$metrics))) stop("Incomplete batch inventory",call.=FALSE)
  ordered <- list(); pending <- registry$modules; done <- character()
  while(length(pending)) {
    ready <- vapply(pending,function(m)all(unlist(m$depends_on)%in%done),TRUE)
    if(!any(ready)) stop("Invalid batch dependency graph",call.=FALSE)
    ordered <- c(ordered,pending[ready]);done<-c(done,vapply(pending[ready],function(m)m$id,""))
    pending<-pending[!ready]
  }
  registry$modules<-ordered
  list(registry=registry,profile=assets$profile,hash=digest::digest(file=path,algo="sha256"))
}

#' Plan set-based batches for the complete core characterization profile
#'
#' Returns dependencies, exact output grains and explicit materialization choices.
#' This pure planner does not execute domain reports, connect to a CDM, or publish.
#' @param cdmSchema Source schema identifier.
#' @param sourceId Institution-controlled source identifier.
#' @param declaredCdmVersion Declared CDM version: 5.3, 5.4 or 5.5.
#' @param window Optional inclusive observed date window with start/end strings;
#'   NULL means source-derived full history. All-recorded metrics retain all rows.
#' @param strategy Reference recomputation or shared intermediate evaluation.
#' @return A deterministic plan with profile/definition identity and module DAG.
#' @export
planCharacterizationBatch <- function(cdmSchema,sourceId,declaredCdmVersion,window=NULL,strategy="reference") {
  if(!.batch_identifier(cdmSchema) || !.string(sourceId) || nchar(sourceId,type="bytes")>512L ||
     !.string(declaredCdmVersion) || !declaredCdmVersion%in%c("5.3","5.4","5.5")) stop("Invalid batch source configuration",call.=FALSE)
  if(!.string(strategy) || !strategy%in%c("reference","shared")) stop("Batch strategy must be reference or shared",call.=FALSE)
  if(!is.null(window) && (!.nv_object(window) || anyDuplicated(names(window)) || !setequal(names(window),c("start","end")) ||
    !.batch_date(window$start) || !.batch_date(window$end) || window$start>window$end)) stop("Invalid observed date window",call.=FALSE)
  assets<-.batch_assets()
  modules<-lapply(assets$registry$modules,function(m) {
    m$materialization <- if(m$materialization_candidate && strategy=="shared") "evaluate_run_owned_temp" else "reference_recompute"
    m$decision_reason <- if(m$materialization_candidate) "Explicit evaluation candidate; retain only after measured benefit, not an automatic optimizer decision" else "No shared-input materialization selected for this module"
    m
  })
  sql<-system.file("sql/postgresql",package="AchillesNext",mustWork=TRUE)
  files<-sort(list.files(sql,pattern="^batch-.*[.]sql$",full.names=TRUE))
  definitions<-.object(registry_sha256=assets$hash,analysis_definitions_sha256=.v2_assets()$analysis$hash,runtime=.run_definitions(),
    sql_sha256=stats::setNames(lapply(files,function(f)digest::digest(file=f,algo="sha256")),basename(files)))
  plan<-.object(format_version="1.0.0",engine="postgresql",source=.object(source_id=sourceId,cdm_schema=cdmSchema,declared_cdm_version=declaredCdmVersion),
    profile=.object(id=assets$profile$profile_id,revision=assets$profile$revision,sha256=assets$registry$profile_sha256),definitions=definitions,
    scope=.object(recorded="all_physical_rows_including_undated_and_unlinked",concepts="all_observed",observed_window=window,history=if(is.null(window))"source_derived_full_history" else "explicit_observed_window"),
    strategy=strategy,modules=modules,rules=assets$registry$rules,
    execution=.object(state="planning_only",report_generation_implemented=FALSE,source_statements_measured=NULL),
    reuse=.object(within_transaction="verified_dependency_key",across_transactions="recompute",reason="No durable verified snapshot identity; operator assertions alone do not enable reuse"))
  plan$plan_sha256<-.hash(.json(plan));plan
}

.batch_check_plan <- function(plan) {
  if(!is.list(plan) || !.string(plan$plan_sha256)) stop("Invalid batch plan",call.=FALSE)
  expected<-planCharacterizationBatch(plan$source$cdm_schema,plan$source$source_id,plan$source$declared_cdm_version,plan$scope$observed_window,plan$strategy)
  if(!identical(.json(plan),.json(expected))) stop("Changed batch definitions or request; create a new plan",call.=FALSE)
  invisible(TRUE)
}
