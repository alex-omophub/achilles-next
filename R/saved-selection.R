# Internal semantic selection model. This performs no source/store reads and is
# not a public provider, cursor, cache permission or job submission API.
.saved_capability <- function(metricId, assets=.v2_assets()) {
  .nv_need(isTRUE(assets$is_core) && .string(metricId) && nchar(metricId,type="bytes")<=128L && metricId %in% names(assets$metrics),"Unknown saved core metric")
  metric <- assets$metrics[[metricId]]; schema <- assets$rows[[metricId]]
  dimensions <- unlist(schema$dimensions,use.names=FALSE)
  kinds <- names(schema$value_keys_by_row_kind)
  byKind <- stats::setNames(lapply(kinds,function(kind)as.list(c(dimensions,unlist(schema$extra_dimensions_by_row_kind[[kind]],use.names=FALSE)))),kinds)
  .object(metric_id=metricId,metric_version=metric$version,population=metric$population,grain=metric$grain,
    row_kinds=as.list(kinds),dimensions_by_row_kind=byKind,
    concept=if("concept_tag"%in%dimensions)"exact_saved_tag" else "not_saved",
    time=if("period_kind"%in%dimensions)"exact_saved_period" else if("month"%in%dimensions)"saved_month" else if("year"%in%dimensions)"saved_year" else "not_saved",
    unit=if("unit_concept_tag"%in%dimensions)"exact_saved_tag" else "not_saved",
    operator=if("raw_operator_tag"%in%dimensions)"exact_saved_tag" else "not_saved",
    summary=if("summary"%in%kinds)"saved_summary_only" else "not_saved",
    transformations="none",availability="requires_approved_catalogue")
}
.saved_capabilities <- function(assets=.v2_assets()) {
  stats::setNames(lapply(sort(names(assets$metrics),method="radix"),.saved_capability,assets=assets),sort(names(assets$metrics),method="radix"))
}
.saved_filter_value <- function(value) {
  scalar <- function(x).string(x) && nchar(x,type="bytes")<=1024L
  .nv_need(scalar(value) || (.nv_object(value) && length(value)<=2L && !anyDuplicated(names(value)) &&
    all(names(value)%in%c("kind","value")) && all(vapply(value,scalar,TRUE))),"Use bounded exact-string or typed-tag selectors")
  if(is.list(value)) .v2_component(value,"concept_tag")
}
.saved_selection <- function(metricId, filters=.object(), rowKind=NULL, population=NULL,
                             maxRows=100L, maxBytes=1048576L, check=function()NULL, assets=.v2_assets()) {
  .nv_need(is.function(check),"A cancellation check is required");check()
  capability <- .saved_capability(metricId,assets)
  .nv_need(.nv_object(filters) && length(filters)<=16L && !anyDuplicated(names(filters)) &&
    all(grepl("^[a-z][a-z0-9_]{0,63}$",names(filters))),"Use at most 16 named semantic selectors")
  for(value in filters).saved_filter_value(value)
  .nv_need(is.null(rowKind)||(.string(rowKind)&&nchar(rowKind,type="bytes")<=48L),"Invalid saved row kind")
  .nv_need(is.null(population)||(.string(population)&&nchar(population,type="bytes")<=128L),"Invalid saved population")
  bounded <- function(x,maximum)is.numeric(x)&&length(x)==1L&&!is.na(x)&&is.finite(x)&&x==floor(x)&&x>=1&&x<=maximum
  .nv_need(bounded(maxRows,1000L)&&bounded(maxBytes,8388608L),"Invalid saved-selection response budget")
  # Reuse installed structural schemas; numerical row/denominator validation
  # remains independent and is not replaced by this request-shape decision.
  for(name in intersect(names(filters),names(assets$dimensions))) {
    .nv_schema(filters[[name]],assets$dimensions[[name]],assets$metadata)
    .v2_component(filters[[name]],name)
  }
  period <- c("period_kind","period_start","period_end")
  if(any(period%in%names(filters))) {
    .nv_need(all(period%in%names(filters)),"Select a complete exact saved period")
  }
  # Validate supplied dimension values/anchors without requiring an entire saved
  # row payload. Actual summary eligibility and denominator checks remain at readback.
  .v2_dimensions(metricId,.object(dimensions=filters[intersect(names(filters),names(assets$dimensions))],row_kind="counts"),assets)
  savedPeriod <- TRUE
  if(all(period%in%names(filters))) {
    kind <- filters$period_kind;start <- filters$period_start;end <- filters$period_end
    if(kind%in%c("full_scope","undated")) savedPeriod <- start=="null"&&end=="null"
    if(kind=="calendar_year") savedPeriod <- substr(start,6,10)=="01-01"&&end==paste0(substr(start,1,4),"-12-31")
    if(kind=="calendar_month") {
      year <- as.integer(substr(start,1,4));month <- as.integer(substr(start,6,7))
      days <- c(31L,28L+as.integer(year%%4L==0L&&(year%%100L!=0L||year%%400L==0L)),31L,30L,31L,30L,31L,31L,30L,31L,30L,31L)[month]
      savedPeriod <- substr(start,9,10)=="01"&&end==paste0(substr(start,1,8),sprintf("%02d",days))
    }
  }
  allowed <- if(is.null(rowKind))unlist(assets$rows[[metricId]]$dimensions,use.names=FALSE) else unlist(capability$dimensions_by_row_kind[[rowKind]],use.names=FALSE)
  reason <- if(!is.null(population)&&population!=capability$population)"selection.population_not_saved" else
    if(!is.null(rowKind)&&!rowKind%in%unlist(capability$row_kinds))"selection.row_kind_not_saved" else
    if(any(!names(filters)%in%allowed))"selection.dimensions_not_saved" else
    if(!savedPeriod)"selection.period_not_saved" else NULL
  payload <- .object(profile_id=assets$profile$profile_id,profile_revision=assets$profile$revision,profile_sha256=assets$hash,
    metric_id=metricId,metric_version=capability$metric_version,population=population %||% capability$population,
    row_kind=rowKind,filters=filters,max_rows=as.character(maxRows),max_bytes=as.character(maxBytes))
  .nv_need(nchar(.json(payload),type="bytes")<=16384L,"Saved-selection request byte limit")
  check()
  .object(state=if(is.null(reason))"selection_shape_supported" else "additional_batch_job_required",reason_code=reason,
    request=payload,request_sha256=.hash(.json(payload)),generation_requested=FALSE,
    availability="requires_approved_catalogue_and_saved_rows",transformations="none")
}
