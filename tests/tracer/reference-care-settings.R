# The matching Python fixture supplies the observed rows from PostgreSQL.
source("tools/benchmark/matched_reference.R")
examples <- jsonlite::fromJSON(paste(readLines("stdin", warn=FALSE), collapse=""), simplifyVector=FALSE)
for (example in examples) {
  for (raw in example$rows) {
    row <- c(raw, list(state="computed", reason_code=NULL))
    typed <- referenceCareSettingRow(row, example$declared_reason)
    reason <- example$expected_reason
    if (is.null(reason) || row$dimensions$setting_kind != "place_of_service") {
      matches <- identical(typed, row)
    } else {
      state <- if (reason == "capability.care_site_absent") "unsupported" else "unavailable"
      matches <- identical(typed$state, state) && identical(typed$reason_code, reason) &&
        "values" %in% names(typed) && is.null(typed$values)
    }
    if (!matches) {
      stop(sprintf("Reference care-setting mismatch for %s (%s), dimensions %s",
                   example$case, row$dimensions$setting_kind,
                   jsonlite::toJSON(row$dimensions, auto_unbox=TRUE)), call.=FALSE)
    }
  }
}
