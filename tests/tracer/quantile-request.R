suppressPackageStartupMessages(library(AchillesNext))
for (strategy in list("approximate", "", NA_character_, c("reference", "weighted"), NULL, 1L)) {
  error <- tryCatch({generateMeasurementReport(NULL,NULL,NULL,NULL,NULL,NULL,numericStrategy=strategy); "accepted"}, error = conditionMessage)
  stopifnot(grepl("numericStrategy must be reference or weighted", error, fixed = TRUE))
}
stopifnot(formals(generateMeasurementReport)$numericStrategy == "reference")
cat("PASS: reference default and invalid strategy rejected before database access\n")
