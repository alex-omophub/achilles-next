# Contract 2 pages use canonical UTF-8 JSON with exactly one trailing LF.
.v2_bytes <- function(x) charToRaw(enc2utf8(paste0(.json(x), "\n")))
.v2_hash <- function(bytes) digest::digest(bytes, algo = "sha256", serialize = FALSE)
.v2_keys <- function(x, keys) .nv_need(.nv_object(x) && setequal(names(x), keys), "Unknown or missing fields")
.v2_count <- function(x) .string(x) && grepl("^(0|[1-9][0-9]*)$", x)
.v2_decimal <- function(x) .string(x) && grepl("^-?(0|[1-9][0-9]*)(\\.[0-9]*[1-9])?$", x) && x != "-0"
.v2_assets <- local({
  cache <- NULL
  function() {
    if (!is.null(cache)) return(cache)
    file <- function(p) system.file(p, package = "AchillesNext", mustWork = TRUE)
    lock <- jsonlite::fromJSON(file("contracts/v2/schema-lock.json"),simplifyVector=FALSE)
    for(name in names(lock$sha256)) .nv_need(identical(digest::digest(file=file(paste0("contracts/v2/",name)),algo="sha256"),lock$sha256[[name]]),"Row schema integrity failure")
    profilePath <- file("analysis/core-characterization-v2.json")
    profile <- jsonlite::fromJSON(profilePath, simplifyVector = FALSE)
    rows <- jsonlite::fromJSON(file("contracts/v2/rows.json"), simplifyVector = FALSE)
    .nv_need(identical(digest::digest(file = profilePath, algo = "sha256"), rows$profile_sha256), "Profile integrity failure")
    ids <- vapply(profile$metrics, function(m) m$id, "")
    .nv_need(identical(ids, vapply(rows$metrics, function(m) m$id, "")))
    cache <<- list(profile = profile, hash = rows$profile_sha256,
      metrics = stats::setNames(profile$metrics, ids), rows = stats::setNames(rows$metrics, ids),
      metadata = jsonlite::fromJSON(file("contracts/v2/metadata.schema.json"), simplifyVector = FALSE),
      dimensions = jsonlite::fromJSON(file("contracts/v2/dimensions.json"), simplifyVector = FALSE))
    cache
  }
})
.v2_component <- function(x, name) {
  if (grepl("_tag$", name)) {
    .nv_need(.nv_object(x) && .string(x$kind))
    if (x$kind %in% c("all", "null", "schema_absent")) {
      .v2_keys(x, "kind"); return(c(all = "A", null = "N", schema_absent = "S")[[x$kind]])
    }
    .v2_keys(x, c("kind", "value")); .nv_need(x$kind == "id")
    return(.v2_component(x$value, "integer"))
  }
  .nv_need(.string(x), "Dimension must be a typed string")
  if (name %in% c("period_start", "period_end", "month")) {
    if (x %in% c("null", "undated")) return(if (x == "null") "N" else "E:undated")
    .nv_need(.nv_date(x)); return(paste0("D", x))
  }
  integer <- name %in% c("integer", "year", "year_of_birth", "event_count", "concept_count", "interval_count", "domain_count", "floor_days_div_30") || grepl("_concept_id$", name)
  if (integer) {
    .nv_need(grepl("^(0|[1-9][0-9]*|-[1-9][0-9]*)$", x), "Invalid integer dimension")
    neg <- startsWith(x, "-"); digits <- sub("^-", "", x); n <- nchar(digits)
    .nv_need(n <= 512L)
    if (neg) paste0("I0", sprintf("%06d", 999999L-n), ":", paste(9L-(utf8ToInt(digits)-48L), collapse = "")) else
      paste0("I1", sprintf("%06d", n), ":", digits)
  } else if (name %in% c("present", "full_calendar_period")) {
    .nv_need(x %in% c("true", "false")); if (x == "true") "B1" else "B0"
  } else if (name %in% c("presence_bits", "representation_flags")) {
    .nv_need(grepl("^[01X]{1,16}$", x)); paste0("R:", x)
  } else {
    .nv_need(grepl("^[A-Za-z0-9._:-]{1,128}$", x), "Invalid code dimension"); paste0("E:", x)
  }
}
.v2_row_identity <- function(metric, row) .v2_hash(.v2_bytes(.object(metric_id = metric$id,
  metric_version = metric$version, row_kind = row$row_kind, dimensions = row$dimensions)))
.v2_sort <- function(metric, row) {
  names <- c(unlist(metric$dimensions), unlist(metric$extra_dimensions_by_row_kind[[row$row_kind]]))
  parts <- vapply(names, function(n) .v2_component(row$dimensions[[n]], n), "")
  key <- paste(c(parts, paste0("E:", row$row_kind)), collapse = "|")
  .nv_need(nchar(key, type = "bytes") <= 1024L, "Sort key too large"); key
}
.v2_metadata <- function(id, v) {
  schema <- .v2_assets()$metadata
  .nv_schema(v, schema$`$defs`[[id]], schema)
  identity <- function(x) .nv_need(if (x$state == "known") !is.null(x$value) && !is.null(x$basis) && !is.null(x$assertion_id) && is.null(x$reason_code) else is.null(x$value) && !is.null(x$reason_code))
  coverage <- function(x) {
    .nv_need(isTRUE(x$complete) && (x$scope_kind != "declared_reduced" || !is.null(x$reason_code)))
    if (x$scope_kind == "standard_full") .nv_need(identical(x$excluded_record_count, "0"))
  }
  if (id == "core.source.passport") {
    for (n in c("source_release", "vocabulary_release")) identity(v[[n]])
    coverage(v$coverage)
    .nv_need(v$generation$started_at <= v$generation$ended_at)
    .nv_need(!v$consistency$reusable || v$consistency$within_run == "verified_immutable_source")
  }
  if (id == "core.source.capabilities") .nv_need(if (v$state %in% c("available", "available_empty")) is.null(v$reason_code) else !is.null(v$reason_code))
  if (id == "core.execution.output_status") {
    .nv_need(if (v$state == "computed") is.null(v$reason_code) else !is.null(v$reason_code)); coverage(v$coverage)
    .nv_need(if (v$integrity$state == "validated") !is.null(v$integrity$sha256) && is.null(v$integrity$reason_code) else is.null(v$integrity$sha256) && !is.null(v$integrity$reason_code))
  }
  if (id == "core.execution.timing") .nv_need(if (v$availability == "measured") !is.null(v$duration_ms) && is.null(v$reason_code) else is.null(v$duration_ms) && !is.null(v$reason_code))
  invisible(TRUE)
}
.v2_row <- function(id, row) {
  registry <- .v2_assets()$rows[[id]]; .nv_need(!is.null(registry), "Unknown metric")
  .v2_keys(row, c("row_key", "dimensions", "row_kind", "state", "reason_code", "values", "denominator_refs"))
  .nv_need(row$row_kind %in% names(registry$value_keys_by_row_kind), "Unknown row kind")
  dims <- c(unlist(registry$dimensions), unlist(registry$extra_dimensions_by_row_kind[[row$row_kind]]))
  .v2_keys(row$dimensions, dims); .v2_dimensions(id,row); key <- .v2_sort(registry, row)
  .nv_need(identical(row$row_key, .v2_row_identity(registry, row)), "Row identity mismatch")
  .nv_need(row$state %in% c("computed", "empty_source", "empty_population", "suppressed", "unsupported", "unavailable"))
  if(row$state %in% c("unsupported","unavailable")) .nv_need(id=="core.visit.care_setting_count" && identical(row$dimensions$setting_kind,"place_of_service"),"Unavailable required stratum")
  .nv_need(if (row$state == "computed") is.null(row$reason_code) else .string(row$reason_code) && grepl("^[a-z0-9_.:-]{1,96}$", row$reason_code))
  .nv_need(.nv_array(row$denominator_refs) && length(row$denominator_refs)<=2L)
  for (ref in row$denominator_refs) {
    .v2_keys(ref, c("measure", "metric_id", "row_key", "field", "value"))
    .nv_need(ref$metric_id %in% names(.v2_assets()$metrics))
    .nv_need(.v2_count(ref$value) && grepl("^[0-9a-f]{64}$", ref$row_key))
    .nv_need(ref$measure %in% names(row$values) && ref$field %in% c("record_count", "person_count", "person_days", "interval_count", "n"))
  }
  if (row$state %in% c("suppressed","unsupported","unavailable")) {
    .nv_need(is.null(row$values) && !length(row$denominator_refs), "Suppressed payload leak")
  } else {
    .v2_keys(row$values, unlist(registry$value_keys_by_row_kind[[row$row_kind]]))
    v <- row$values
    if (row$row_kind %in% c("counts", "eligibility_counts")) {
      .nv_need(all(vapply(v, .v2_count, TRUE)), "Invalid exact count")
      if (!is.null(v$person_count) && !is.null(v$record_count)) .nv_need(.nv_unsigned_cmp(v$person_count,v$record_count)<=0L,"People exceed physical records")
      if (row$state != "computed") .nv_need(all(vapply(v, identical, TRUE, "0")))
    } else if (row$row_kind == "summary") {
      .nv_need(.v2_count(v$n))
      stats <- setdiff(names(v), "n")
      if (v$n == "0") .nv_need(row$state != "computed" && all(vapply(v[stats], is.null, TRUE))) else {
        .nv_need(row$state == "computed" && all(vapply(v[setdiff(stats, "mean_denominator")], .v2_decimal, TRUE)))
        .nv_need(identical(v$mean_numerator, v$sum) && identical(v$mean_denominator, v$n))
        .nv_need(.nv_compare(v$min, v$sum, v$n) <= 0 && .nv_compare(v$max, v$sum, v$n) >= 0, "Summary sum bounds")
        ordered <- c("min", "p10", "p25", "p50", "p75", "p90", "max")
        for (i in seq_len(6)) .nv_need(.nv_compare(v[[ordered[i]]], v[[ordered[i+1L]]]) <= 0, "Quantile order")
      }
    } else .v2_metadata(id, v)
  }
  .nv_need(length(.v2_bytes(row)) <= 65536L, "Row resource limit")
  key
}

.v2_dimensions <- function(id,row) {
  d <- row$dimensions;profile <- .v2_assets()$profile
  for(name in names(d)) .nv_schema(d[[name]],.v2_assets()$dimensions[[name]],.v2_assets()$metadata)
  enums <- list(period_kind=c("full_scope","calendar_month","calendar_year","undated"),
    boundary_kind=c("start","end"),source_value_state=c("null","blank","nonblank","schema_absent"),
    source_unit_presence=c("null","blank","nonblank","schema_absent"),
    setting_kind=c("visit","admitted_from","discharged_to","place_of_service"),
    dimension_kind=c("anatomic_site","disease_status"),link_kind=c("visit_occurrence","visit_detail"),
    phase=c("planning","source_read","materialization","aggregation","validation","projection","export","publication","execution","generation"))
  reasons <- unique(c(unlist(profile$contracts$`eligibility-reasons`[c("numeric_summary_order","nonnegative_scalar_order","elapsed_duration_order","age_order","range_boundary_order","range_status_order")]),
    "null_person","orphan_person","null_endpoints","reversed_interval","valid","undated","no_valid_intervals","outside_valid_union","inside_valid_union",
    "null_or_orphan_person","start_date_only","start_datetime_only","start_date_and_datetime","start_absent","end_date_only","end_datetime_only","end_date_and_datetime","end_absent",
    "missing_duration","negative_duration","start_disagreement","end_disagreement"))
  enums$reason <- reasons;enums$eligibility_reason <- reasons
  enums$flag <- c("null_person","orphan_person","missing_date","invalid_date","null_concept","zero_concept","unknown_concept","wrong_domain_concept","missing_end","reversed_end","duplicate_record_id","repeated_person_rows")
  for(name in intersect(names(d),names(enums))) .nv_need(d[[name]]%in%enums[[name]],"Unregistered dimension code")
  if("metric_id"%in%names(d)) .nv_need(d$metric_id%in%names(.v2_assets()$metrics))
  if("probe_id"%in%names(d)) {
    probes <- unique(unlist(lapply(profile$metrics,function(m)c(unlist(m$inputs),unlist(m$conditional_inputs),unlist(m$input_aliases)))))
    .nv_need(d$probe_id%in%probes,"Unregistered capability probe")
  }
  for(name in intersect(names(d),c("first_year_age_decile","year_age_decile","year_age_or_unknown"))) {
    .nv_need(d[[name]]=="unknown" || (.v2_count(d[[name]]) && .nv_unsigned_cmp(d[[name]],if(name=="year_age_or_unknown")"130" else "13")<=0),"Invalid age stratum")
  }
  if("representation_flags"%in%names(d)) {
    n <- if(grepl("measurement",id,fixed=TRUE))3L else 5L
    .nv_need(grepl(paste0("^[01]{",n,"}$"),d$representation_flags) || (n==5L && grepl("^[01]{4}X$",d$representation_flags)),"Invalid representation flags")
  }
  if("presence_bits"%in%names(d)) .nv_need(grepl("^[01]{9}$",d$presence_bits),"Invalid domain presence mask")
  if("period_kind"%in%names(d)) {
    if(d$period_kind=="undated" || (d$period_kind=="full_scope" && d$period_start=="null")) .nv_need(d$period_start=="null"&&d$period_end=="null") else {
      .nv_need(.nv_date(d$period_start)&&.nv_date(d$period_end)&&d$period_start<=d$period_end,"Invalid period bounds")
      if(d$period_kind=="calendar_month") .nv_need(substr(d$period_start,1,7)==substr(d$period_end,1,7))
      if(d$period_kind=="calendar_year") .nv_need(substr(d$period_start,1,4)==substr(d$period_end,1,4))
    }
  }
  if("month"%in%names(d)) .nv_need(substr(d$month,9,10)=="01")
  if(id%in%c("core.measurement.numeric_summary","core.observation.numeric_summary","core.measurement.range_low_summary","core.measurement.range_high_summary") && row$row_kind=="summary") {
    .nv_need(identical(d$unit_concept_tag$kind,"id") && grepl("^[1-9][0-9]*$",d$unit_concept_tag$value),"Numeric summary needs a positive unit identity")
    if(id=="core.measurement.numeric_summary") .nv_need(identical(d$raw_operator_tag$kind,"null") || (identical(d$raw_operator_tag$kind,"id") && identical(d$raw_operator_tag$value,"0")),"Ineligible numeric operator")
  }
  invisible(TRUE)
}
