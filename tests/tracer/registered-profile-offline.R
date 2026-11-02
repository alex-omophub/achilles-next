library(AchillesNext)
local({
  f <- function(n)get(n,asNamespace("AchillesNext"));o <- f(".object")
  a <- f(".profile_assets")("reference-person-v1");core <- f(".v2_assets")()
  stopifnot(length(a$metrics)==2L,length(core$metrics)==142L,!a$is_core,core$is_core)
  rejects <- function(work)stopifnot(inherits(try(work(),silent=TRUE),"try-error"))
  for(id in c("unknown","https://invalid/profile","../reference-person-v1"))rejects(function()planAnalysisProfile(id,"cdm","fixture","5.5"))
  rejects(function()f(".profile_assets")("reference-person-v1","unsupported"))
  rejects(function()f(".profile_assets")("reference-person-v1",hash=strrep("a",64)))
  rejects(function()f(".profile_assets")("core-characterization-v2",hash=a$hash))
  for(key in c("profile_id","profile_revision","profile_sha256")) {
    context <- o(profile_id=a$profile$profile_id,profile_revision=a$profile$revision,profile_sha256=a$hash)
    context[key] <- list(NULL);rejects(function()f(".profile_context")(context))
  }
  p <- planAnalysisProfile(a$profile$profile_id,"cdm","fixture","5.5")
  stopifnot(identical(p,planAnalysisProfile(a$profile$profile_id,"cdm","fixture","5.5")),
    identical(unlist(p$metric_order),c("example.person.count","example.person.gender_count")),
    p$reuse=="recompute_no_durable_source_identity")
  row <- o(row_key="",dimensions=o(),row_kind="counts",state="computed",reason_code=NULL,values=o(person_count="9007199254740993"),denominator_refs=list())
  row$row_key <- f(".v2_row_identity")(a$rows[["example.person.count"]],row)
  f(".v2_row")("example.person.count",row,a)
  rejects(function()f(".v2_row")("example.person.count",row))
  rejects(function()f(".v2_row")("core.person.count",row,a))
  policy <- o(id="fixture",revision="1",scope_kind="restricted",allow_metrics=list("example.person.gender_count"))
  stopifnot(!length(f(".v2_policy")(policy,a)))
  rejects(function()f(".v2_policy")(policy))
  # Per-call profile context never changes the process-wide core default.
  stopifnot(identical(core,f(".v2_assets")()),length(planCharacterizationBatch("cdm","fixture","5.5")$modules)==51L)
  cat("REGISTERED_PROFILE_LOCKED_CONTEXT_PLAN_EXACT_COUNTS_AND_CORE_ISOLATION_OK\n")
})
