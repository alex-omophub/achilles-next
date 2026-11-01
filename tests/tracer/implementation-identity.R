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
cat("PASS: cold/warm implementation and ledger identities stable; stale same-version body and foreign environment refused\n")
