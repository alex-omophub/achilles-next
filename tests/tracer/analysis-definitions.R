# Installed executable-rule checks with independently specified denominator cases.
library(AchillesNext)
local({
  ns <- asNamespace("AchillesNext"); f <- function(n) get(n, ns); o <- f(".object")
  a <- f(".v2_assets")(); doc <- a$analysis$definitions
  stopifnot(length(doc$analyses) == 142L,
    sum(vapply(doc$analyses, function(x) !is.null(x$denominator), TRUE)) == 62L)
  rows <- o(metrics = unname(a$rows))
  validate <- function(x) f(".analysis_validate")(x, a$profile, rows)
  rejects <- function(work) stopifnot(inherits(try(work(), silent = TRUE), "try-error"))
  rejects(function() f(".analysis_load")(a$profile,rows,strrep("a",64)))
  changed <- doc; changed$format_version <- "remote"; rejects(function() validate(changed))
  changed <- doc; changed$analyses[[1]] <- NULL; rejects(function() validate(changed))
  changed <- doc; changed$analyses[[1]]$population <- "other"; rejects(function() validate(changed))
  changed <- doc; changed$rules$all_people$row_kind <- "dynamic"; rejects(function() validate(changed))
  changed <- doc; changed$rules$all_people$remote_schema <- "https://invalid"; rejects(function() validate(changed))
  changed <- doc; changed$rules$full_scope_people$when$period_kind <- "typo"; rejects(function() validate(changed))
  changed <- doc; changed$rules$same_period_people$dimensions$period_kind$source <- "unknown"; rejects(function() validate(changed))
  changed <- doc; changed$rules$all_people$measures[[1]]$target <- "sum"; rejects(function() validate(changed))
  changed <- doc; changed$rules$all_people$measures <- rep(changed$rules$all_people$measures, 2L); rejects(function() validate(changed))
  changed <- doc; changed$rules$concept_full_scope$key_defaults$period_start <- "2020-01-01"; rejects(function() validate(changed))
  changed <- doc; changed$analyses[["core.person.gender_count"]]$denominator$rule <- "unknown"; rejects(function() validate(changed))
  changed <- doc; changed$analyses[["core.person.gender_count"]]$denominator$metric_id <- "unknown"; rejects(function() validate(changed))
  changed <- doc; changed$analyses[["core.person.gender_count"]]$denominator$metric_id <- "core.person.gender_count"; rejects(function() validate(changed))
  changed <- doc
  changed$rules$same_concept_period <- changed$rules$same_period_people
  changed$rules$same_concept_period$dimensions$concept_tag <- o(source="concept_tag")
  changed$analyses[["core.condition.capture_count"]]$denominator <- o(rule="same_concept_period",metric_id="observed.condition.capture_count")
  changed$analyses[["observed.condition.capture_count"]]$denominator <- o(rule="same_concept_period",metric_id="core.condition.capture_count")
  stopifnot(grepl("Cyclic denominator definitions",tryCatch({validate(changed);"ACCEPTED"},error=conditionMessage),fixed=TRUE))
  changed <- c(doc, doc["format_version"]); rejects(function() validate(changed))
  rejects(function() f(".analysis_rule")("unknown"))
  period <- o(period_kind="calendar_month",period_start="2020-01-01",period_end="2020-01-31")
  full <- o(period_kind="full_scope",period_start="null",period_end="null")
  concept <- o(concept_tag=o(kind="id",value="9007199254740993"))
  age <- o(year="2020",gender_concept_id="0",year_age_decile="3")
  row <- function(dims) o(row_kind="counts",state="computed",dimensions=dims,
    values=o(record_count="9007199254740993",person_count="2"),denominator_refs=list())
  # Expected target population, dimension scope and measures are authored here;
  # they are not derived from the registry under test.
  cases <- list(
    list("core.person.gender_count",row(o(gender_concept_id="0")),"core.person.count",o(),"person_count"),
    list("core.condition.capture_count",row(c(concept,full)),"core.person.count",o(),"person_count"),
    list("observed.condition.capture_count",row(c(concept,period)),"core.observation_period.coverage_count",period,"person_count"),
    list("observed.condition.year_gender_age_count",row(c(concept,age)),"core.observation_period.year_gender_age_count",age,"person_count"),
    list("core.condition.observation_qualification_count",row(c(concept,o(reason="inside_valid_union"))),"core.condition.capture_count",c(concept,full),c("record_count","person_count")),
    list("core.condition.frequency_histogram",row(c(concept,o(event_count="0"))),"core.person.count",o(),"person_count"),
    list("core.density.domain_count",row(o(domain_count="0")),"core.person.count",o(),"person_count")
  )
  tx <- list(schema='"restricted"'); release <- "00000000-0000-4000-8000-000000000001"
  signatures <- list()
  for (case in cases) {
    mid <- case[[1]]; r <- case[[2]]; targetId <- case[[3]]; dims <- case[[4]]; measures <- case[[5]]
    spec <- f(".analysis_denominator")(mid, r, forKey=TRUE)
    stopifnot(spec$metric_id==targetId,identical(f(".json")(spec$dimensions),f(".json")(dims)),
      identical(vapply(spec$measures,function(m)m$source,""),measures))
    target <- o(metric_id=targetId,dimensions=dims,
      row_key=f(".v2_row_identity")(a$rows[[targetId]],o(row_kind="counts",dimensions=dims)),
      values=o(record_count="9007199254740994",person_count="9007199254740993"))
    refs <- f(".domain_denominators")(mid,r,target)
    stopifnot(length(refs)==length(measures),all(vapply(refs,function(ref)ref$value==target$values[[ref$field]],TRUE)))
    r$denominator_refs <- refs
    f(".v2_denominator_check")(mid,r,function(id,key)dims)
    bad <- r; bad$denominator_refs[[1]]$field <- "n"; rejects(function() f(".v2_denominator_check")(mid,bad,function(id,key)dims))
    bad <- r; bad$denominator_refs <- list(); rejects(function() f(".v2_denominator_check")(mid,bad,function(id,key)dims))
    rejects(function() f(".v2_denominator_check")(mid,r,function(id,key)o(wrong="scope")))
    sql <- f(".domain_stream_sql")(tx,release,"pg_temp.reports",mid)
    stopifnot(grepl(targetId,sql,fixed=TRUE),grepl("LEFT JOIN",sql,fixed=TRUE))
    signatures[[mid]] <- list(spec=spec,refs=refs,sql=sql)
  }
  for (dims in list(c(concept,period),c(concept,o(period_kind="undated",period_start="null",period_end="null")))) {
    r <- row(dims)
    stopifnot(is.null(f(".analysis_denominator")("core.condition.capture_count",r)),
      !length(f(".domain_denominators")("core.condition.capture_count",r,NULL)))
    f(".v2_denominator_check")("core.condition.capture_count",r,function(...)stop("Unexpected lookup"))
  }
  # Existing artifacts may declare bounded full-scope dates. Qualification
  # validation retains that wire meaning; generation still uses its null-bound key.
  mid <- "core.condition.observation_qualification_count"; r <- cases[[5]][[2]]
  r$denominator_refs <- signatures[[mid]]$refs
  dated <- c(concept,o(period_kind="full_scope",period_start="2020-01-01",period_end="2020-12-31"))
  for (i in seq_along(r$denominator_refs)) r$denominator_refs[[i]]$row_key <- f(".v2_row_identity")(
    a$rows[["core.condition.capture_count"]],o(row_kind="counts",dimensions=dated))
  f(".v2_denominator_check")(mid,r,function(id,key)dated)
  wrong <- dated; wrong$period_kind <- "calendar_year"
  rejects(function() f(".v2_denominator_check")(mid,r,function(id,key)wrong))
  r <- row(c(concept,full)); r$state <- "suppressed"
  stopifnot(is.null(f(".analysis_denominator")("core.condition.capture_count",r)))
  r <- row(concept); r$row_kind <- "summary"
  stopifnot(is.null(f(".analysis_denominator")("core.condition.capture_count",r)))
  policy <- o(id="fixture",revision="1",scope_kind="restricted",allow_metrics=list("core.condition.capture_count","core.condition.observation_qualification_count"))
  stopifnot(!length(f(".v2_policy")(policy))) # Transitive exclusion without all-person target.
  policy$allow_metrics <- c(policy$allow_metrics,list("core.person.count"))
  beforePolicy <- f(".v2_policy")(policy)
  # Change every description, including denominator prose, in the in-memory
  # fixture. Never unlock namespace bindings or change installed frozen files.
  cache <- f(".validation_cache"); on.exit(assign("v2",a,cache),add=TRUE)
  altered <- a
  altered$metrics <- lapply(altered$metrics,function(m){m$denominator <- "nonsense in full scope same period for full-scope";m$calculation <- "unrelated prose";m})
  assign("v2",altered,cache)
  for (case in cases) {
    mid <- case[[1]]; r <- case[[2]]
    stopifnot(identical(f(".analysis_denominator")(mid,r,forKey=TRUE),signatures[[mid]]$spec),
      identical(f(".domain_stream_sql")(tx,release,"pg_temp.reports",mid),signatures[[mid]]$sql))
    r$denominator_refs <- signatures[[mid]]$refs
    f(".v2_denominator_check")(mid,r,function(id,key)case[[4]])
  }
  stopifnot(identical(f(".v2_policy")(policy),beforePolicy))
  assign("v2",a,cache)
  stopifnot(planCharacterizationBatch("cdm","fixture","5.5")$definitions$analysis_definitions_sha256==a$analysis$hash,
    f(".run_definitions")()$analysis_definitions_sha256==a$analysis$hash)
  cat("PASS: 142 typed analyses; 62 denominator bindings; independent scope/measure/precision fixtures; malformed rules and cycles rejected; prose-independent joins, validation and policy; planning identity bound\n")
})
