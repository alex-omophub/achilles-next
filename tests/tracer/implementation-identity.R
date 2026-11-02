# Offline provenance regression: identical dev versions must not hide stale code.
library(AchillesNext)
source("tools/benchmark/implementation_identity.R")
root <- normalizePath(".")
current <- implementationIdentity(root)
stopifnot(identical(current$source_bindings_sha256, current$installed_bindings_sha256),
  all(c("R/count-tracer.R", "R/measurement.R", "R/tracer-session.R", "R/observation.R", "R/local-viewer.R") %in% names(current$source_files_sha256)))
# Memoization is runtime data: warming installed schema/profile caches must not
# change the implementation identity or the execution-ledger fingerprint.
ns <- asNamespace("AchillesNext")
ledgerBefore <- get(".run_definitions",ns)()
for(version in c("1.0.0","1.1.0")) get(".nv_legacy_assets",ns)(version)
invisible(get(".v2_assets",ns)())
stopifnot(identical(current,implementationIdentity(root)),
  identical(ledgerBefore,get(".run_definitions",ns)()))
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
# A function with the correct body but a foreign lexical environment is still
# refused. Cache support must not weaken the existing provenance guard.
value <- get(".generate_tracer",ns)
assign(".generate_tracer",eval(call("function",formals(value),body(value)),new.env(parent=clone)),clone)
error <- tryCatch({implementationIdentity(root,clone);"accepted"},error=conditionMessage)
stopifnot(grepl("Installed R implementation has a foreign function environment: .generate_tracer",error,fixed=TRUE))
local({
  # A same-version install with stale registry bytes must not pass the guard.
  tree <- tempfile("identity-assets-");dir.create(tree)
  on.exit(unlink(tree,recursive=TRUE),add=TRUE)
  stopifnot(all(file.copy(file.path(root,c("R","DESCRIPTION","NAMESPACE")),tree,recursive=TRUE)))
  dir.create(file.path(tree,"inst/sql"),recursive=TRUE)
  stopifnot(file.copy(file.path(root,"inst/sql/postgresql"),file.path(tree,"inst/sql"),recursive=TRUE))
  dir.create(file.path(tree,"inst/analysis"))
  assets <- c("analysis-definition-lock.json","core-analysis-definitions-v1.json")
  stopifnot(all(file.copy(file.path(root,"inst/analysis",assets),file.path(tree,"inst/analysis"))))
  stopifnot(identical(current$installed_analysis_sha256,implementationIdentity(tree)$installed_analysis_sha256))
  cat("\n",file=file.path(tree,"inst/analysis/core-analysis-definitions-v1.json"),append=TRUE)
  error <- tryCatch({implementationIdentity(tree);"accepted"},error=conditionMessage)
  stopifnot(grepl("Installed analysis definitions differ from checkout",error,fixed=TRUE))
})
cat("PASS: cold/warm implementation and ledger identities stable; stale same-version body, foreign environment and registry bytes refused\n")
