# Executable rules live separately from the frozen mathematical descriptions.
# This is an installed, closed registry; it does not load caller/remote code.
.analysis_keys <- function(x, keys) {
  .v2_keys(x, keys)
  .nv_need(!anyDuplicated(names(x)), "Duplicate analysis definition fields")
}
.analysis_validate <- function(doc, profile, rows) {
  .analysis_keys(doc, c("format_version", "profile_sha256", "rules", "analyses"))
  .nv_need(identical(doc$format_version, "1.0.0"), "Unsupported analysis definition version")
  .nv_need(.nv_object(doc$rules) && length(doc$rules) > 0L && !anyDuplicated(names(doc$rules)), "Invalid analysis rules")
  .nv_need(.nv_object(doc$analyses) && !anyDuplicated(names(doc$analyses)), "Invalid analysis inventory")
  metrics <- stats::setNames(profile$metrics, vapply(profile$metrics, function(m) m$id, ""))
  schemas <- stats::setNames(rows$metrics, vapply(rows$metrics, function(m) m$id, ""))
  .nv_need(setequal(names(doc$analyses), names(metrics)), "Incomplete analysis inventory")
  for (rule in doc$rules) {
    .analysis_keys(rule, c("row_kind", "when", "dimensions", "key_defaults", "match", "measures"))
    .nv_need(identical(rule$row_kind, "counts") && .string(rule$match) && rule$match %in% c("exact", "subset"), "Unsupported denominator rule")
    for (field in c("when", "dimensions", "key_defaults"))
      .nv_need(.nv_object(rule[[field]]) && !anyDuplicated(names(rule[[field]])), "Invalid denominator dimensions")
    .nv_need(all(vapply(rule$when, .string, TRUE)) && all(vapply(rule$key_defaults, .string, TRUE)), "Unsupported denominator constant")
    .nv_need(!length(rule$when) || (identical(names(rule$when), "period_kind") &&
      identical(rule$when$period_kind, "full_scope")), "Unsupported denominator condition")
    .nv_need(all(names(rule$key_defaults) %in% c("period_start", "period_end")) &&
      all(vapply(rule$key_defaults, function(x) identical(x, "null"), TRUE)), "Unsupported denominator key default")
    .nv_need(!length(intersect(names(rule$dimensions), names(rule$key_defaults))) &&
      (rule$match == "subset" || !length(rule$key_defaults)), "Invalid denominator key defaults")
    for (dimension in names(rule$dimensions)) {
      binding <- rule$dimensions[[dimension]]
      .nv_need(.nv_object(binding) && length(binding) == 1L &&
        names(binding) %in% c("source", "constant") && .string(binding[[1]]), "Unsupported denominator binding")
      if (!is.null(binding$constant)) .nv_need(dimension == "period_kind" &&
        binding$constant == "full_scope", "Unsupported denominator dimension constant")
    }
    .nv_need(.nv_array(rule$measures) && length(rule$measures) %in% 1:2, "Invalid denominator measures")
    for (binding in rule$measures) {
      .analysis_keys(binding, c("source", "target"))
      .nv_need(.string(binding$source) && .string(binding$target) &&
        all(c(binding$source, binding$target) %in% c("record_count", "person_count", "person_days", "interval_count", "n")), "Unsupported denominator measure")
    }
    .nv_need(!anyDuplicated(vapply(rule$measures, function(m) m$source, "")), "Duplicate denominator measure")
  }
  for (mid in names(doc$analyses)) {
    analysis <- doc$analyses[[mid]]; schema <- schemas[[mid]]
    .analysis_keys(analysis, c("population", "denominator"))
    .nv_need(identical(analysis$population, metrics[[mid]]$population), "Analysis population mismatch")
    ref <- analysis$denominator
    if (is.null(ref)) next
    .analysis_keys(ref, c("rule", "metric_id"))
    .nv_need(.string(ref$rule) && ref$rule %in% names(doc$rules) &&
      .string(ref$metric_id) && ref$metric_id %in% names(metrics) && ref$metric_id != mid, "Unknown denominator rule or metric")
    rule <- doc$rules[[ref$rule]]; target <- schemas[[ref$metric_id]]
    sourceDims <- unlist(schema$dimensions, use.names = FALSE)
    targetDims <- unlist(target$dimensions, use.names = FALSE)
    copies <- unlist(lapply(rule$dimensions, function(b) b$source), use.names = FALSE)
    .nv_need(all(c(copies, names(rule$when)) %in% sourceDims) &&
      setequal(c(names(rule$dimensions), names(rule$key_defaults)), targetDims), "Invalid denominator dimension mapping")
    .nv_need(rule$row_kind %in% names(schema$value_keys_by_row_kind) &&
      rule$row_kind %in% names(target$value_keys_by_row_kind), "Invalid denominator row kind")
    for (binding in rule$measures)
      .nv_need(binding$source %in% unlist(schema$value_keys_by_row_kind[[rule$row_kind]]) &&
        binding$target %in% unlist(target$value_keys_by_row_kind[[rule$row_kind]]), "Invalid denominator measure mapping")
  }
  for (mid in names(doc$analyses)) {
    seen <- character(); current <- mid
    repeat {
      .nv_need(!current %in% seen, "Cyclic denominator definitions")
      seen <- c(seen, current); ref <- doc$analyses[[current]]$denominator
      if (is.null(ref)) break
      current <- ref$metric_id
    }
  }
  doc
}
.analysis_load <- function(profile, rows, profileHash) {
  path <- system.file("analysis/core-analysis-definitions-v1.json", package = "AchillesNext", mustWork = TRUE)
  lock <- jsonlite::fromJSON(system.file("analysis/analysis-definition-lock.json", package = "AchillesNext", mustWork = TRUE), simplifyVector = FALSE)
  hash <- digest::digest(file = path, algo = "sha256")
  .nv_need(identical(hash, lock$sha256[[basename(path)]]), "Analysis definition integrity failure")
  doc <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  .nv_need(identical(doc$profile_sha256, profileHash), "Analysis profile identity mismatch")
  list(definitions = .analysis_validate(doc, profile, rows), hash = hash)
}
.analysis_rule <- function(mid, assets = .v2_assets()) {
  analysis <- assets$analysis$definitions$analyses[[mid]]
  .nv_need(!is.null(analysis), "Unknown analysis")
  ref <- analysis$denominator
  if (is.null(ref)) return(NULL)
  c(.object(metric_id = ref$metric_id), assets$analysis$definitions$rules[[ref$rule]])
}
.analysis_denominator <- function(mid, row, assets = .v2_assets(), forKey = FALSE) {
  rule <- .analysis_rule(mid, assets)
  if (is.null(rule) || row$state == "suppressed" || row$row_kind != rule$row_kind) return(NULL)
  for (key in names(rule$when))
    if (!identical(row$dimensions[[key]], rule$when[[key]])) return(NULL)
  dims <- lapply(rule$dimensions, function(binding) {
    if (!is.null(binding$source)) {
      value <- row$dimensions[[binding$source]]
      .nv_need(!is.null(value), "Missing denominator source dimension"); value
    } else binding$constant
  })
  if (forKey) dims <- c(dims, rule$key_defaults)
  if (!length(dims)) dims <- .object()
  .object(metric_id = rule$metric_id, dimensions = dims, measures = rule$measures, match = rule$match)
}
.analysis_dependency <- function(mid, assets = .v2_assets()) {
  rule <- .analysis_rule(mid, assets)
  if (is.null(rule)) NULL else rule$metric_id
}
