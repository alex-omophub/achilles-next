# Offline provenance regression: identical dev versions must not hide stale code.
library(AchillesNext)
source("tools/benchmark/implementation_identity.R")
root <- normalizePath(".")
current <- implementationIdentity(root)
stopifnot(identical(current$source_bindings_sha256, current$installed_bindings_sha256),
  all(c("R/count-tracer.R", "R/measurement.R", "R/tracer-session.R", "R/observation.R", "R/local-viewer.R") %in% names(current$source_files_sha256)))
clone <- new.env(parent = baseenv())
for (name in names(current$installed_bindings_sha256)) {
  v <- get(name, asNamespace("AchillesNext"))
  # Copy functions into a test-only namespace; never unlock installed bindings.
  if (is.function(v)) v <- eval(call("function", formals(v), body(v)), clone)
  assign(name, v, clone)
}
stopifnot(identical(current, implementationIdentity(root, clone)))
body(clone$.generate_tracer) <- quote(stop("Stale implementation at the same version"))
error <- tryCatch({implementationIdentity(root, clone); "accepted"}, error = conditionMessage)
stopifnot(grepl("Installed R implementation differs from checkout: .generate_tracer", error, fixed = TRUE))
cat("PASS: actual namespace implementation matches checkout; stale same-version body refused\n")
