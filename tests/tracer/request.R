# Base-R request boundary regression: no database, Java or package install needed.
# Exercise the validator called by both generators, including low Gregorian years.
env <- new.env(parent = globalenv())
sys.source("R/count-tracer.R", env)
request <- list(profile_id = "alpha-measurement-v1", source_id = "fixture:dates",
  window = list(start = "2020-01-01", end = "2020-12-31"),
  measurement_concept_ids = list(900000001L), output_scope = "restricted",
  disclosure_policy_id = "synthetic-unsuppressed-v1")
check <- function(start, end = start) {
  r <- request; r$window <- list(start = start, end = end)
  env$.check_request(r, "fixture:dates")
}
reject <- function(start, end = start) {
  failed <- tryCatch({check(start, end); FALSE}, error = function(e) TRUE)
  stopifnot(failed)
}
for (timezone in c("UTC", "America/Los_Angeles")) {
  Sys.setenv(TZ = timezone)
  for (date in c("0001-01-01", "0004-02-29", "0100-02-28", "0400-02-29",
                 "1900-02-28", "2000-02-29", "2100-02-28", "9999-12-31")) check(date)
  for (date in c("0000-01-01", "0001-02-29", "0100-02-29", "1900-02-29",
                 "2100-02-29", "2020-02-30", "2020-04-31", "2020-00-01",
                 "2020-13-01", "2020-01-00", "2020-1-01", "10000-01-01",
                 "2020-01-01T00:00:00Z", "2020-01-01suffix", "2020-01-01\n",
                 "2020-01-01 ")) reject(date)
  reject(NA_character_); reject(TRUE); reject(character())
  check("0001-01-01", "0010-12-31") # 120 touched months
  reject("0001-01-01", "0011-01-01")
  reject("2020-01-02", "2020-01-01")
}
cat("PASS: Gregorian year bounds, leap/century rules, strict DATE syntax, bounded windows and timezone independence\n")
