# The fixture owns both endpoints. Fail a real active COPY, then use fresh
# connections to build the same source and compare its rows to the other producer.
testCharacterizationCandidateSqlCopy <- function(sourceDetails,program,storeDetails,results,out,
  snap,expected,prior,tableCounts) {
  native <- asNamespace("AchillesNext")
  run <- function(check=NULL,generate=generateCharacterizationCandidateFromSql) generate(sourceDetails,program,
    storeDetails,results,scratchParent=out,transferStrategy="postgresql_copy",fetchSize=7L,check=check)
  before <- tableCounts()
  files <- sort(list.files(out,all.files=TRUE,no..=TRUE))
  cancel <- FALSE
  relay <- get(".pg_count_copy_pages",native)
  failAfterPage <- function(src,sink,query,mid,maxRows,maxBytes,maxFrames,maxRow,timeout,tick,
                            remaining,afterPage,pageRows=128L) {
    note <- function(...) {
      afterPage(...)
      if (!is.null(sink)) cancel <<- TRUE
    }
    relay(src,sink,query,mid,maxRows,maxBytes,maxFrames,maxRow,timeout,tick,remaining,note,pageRows)
  }
  # Keep the installed namespace and its checked runtime digest unchanged.
  # Only this failed attempt observes the callback just after a real COPY page.
  scope <- new.env(parent=native)
  scope$.pg_count_copy_pages <- failAfterPage
  workspace <- get(".candidate_copy_workspace",native)
  environment(workspace) <- scope
  scope$.candidate_copy_workspace <- workspace
  generate <- generateCharacterizationCandidateFromSql
  environment(generate) <- scope
  failure <- tryCatch(run(function()!cancel,generate),error=identity)
  if (!cancel && inherits(failure,"AchillesCandidateFailure"))
    stop(paste("Expected the active COPY callback but generation stopped at",failure$reason_code,failure$cause_code))
  stopifnot(cancel,inherits(failure,"AchillesCandidateFailure"),failure$reason_code=="candidate.cancelled",
    failure$outcome=="not_committed",identical(tableCounts(),before),
    identical(sort(list.files(out,all.files=TRUE,no..=TRUE)),files))
  prior()
  # Change only one staged key after the source disconnect. The document
  # digest remains identical, while the complete tuple digest must change.
  originalWorkspace <- get(".candidate_copy_workspace",native)
  changed <- FALSE
  scope$.candidate_copy_workspace <- function(tx,...) {
    copy <- originalWorkspace(tx,...)
    complete <- copy$complete
    copy$complete <- function(receipt) {
      counts <- complete(receipt)
      tx$execute(paste0("UPDATE pg_temp.count_frames SET key=repeat('c',64) ",
        "WHERE seq=(SELECT min(seq) FROM pg_temp.count_frames)"))
      changed <<- TRUE
      counts
    }
    copy
  }
  corrupted <- tryCatch(run(generate=generate),error=identity)
  stopifnot(changed,inherits(corrupted,"AchillesCandidateFailure"),
    corrupted$reason_code=="candidate.invalid_capture",corrupted$outcome=="not_committed",
    identical(tableCounts(),before),identical(sort(list.files(out,all.files=TRUE,no..=TRUE)),files))
  prior()
  result <- run()
  saved <- snap(result)
  wire <- get(".json",native)
  canonical <- function(rows) sort(vapply(rows,wire,""),method="radix")
  numerical <- setdiff(names(expected$datasets),get(".core_metadata_ids",native)())
  stopifnot(length(numerical)==138L)
  for (mid in numerical) {
    stopifnot(identical(wire(saved$datasets[[mid]]),wire(expected$datasets[[mid]])),
      identical(canonical(saved$rows[[mid]]),canonical(expected$rows[[mid]])))
  }
  transfer <- result$telemetry$source_capture$count_transfer
  store <- result$telemetry$store_persistence
  writes <- result$persistence
  stopifnot(!result$publication_changed,result$state=="building",result$generated_metric_count=="142",
    identical(result$source_receipt$cleanup$transaction,"rolled_back"),
    identical(result$source_receipt$cleanup$connection,"disconnected"),
    transfer$metrics==45L,transfer$page_rows==7L,length(transfer$receipts)==45L,
    transfer$pages==result$scratch$copy$verification_pages,result$scratch$copy$peak_targets_per_page<=7L,
    writes$rows==as.numeric(result$source_receipt$rows),writes$rows==writes$copy_writes$rows+writes$spool_writes$rows,
    writes$edges==writes$copy_writes$edges+writes$spool_writes$edges,
    as.numeric(store$store_transaction_wall_ms)>=as.numeric(store$wall_ms),
    identical(sort(list.files(out,all.files=TRUE,no..=TRUE)),files))
  prior()
  invisible(result)
}
