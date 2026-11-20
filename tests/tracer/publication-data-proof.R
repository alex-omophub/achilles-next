# The store-backed path must reject even self-consistently serialized pages
# whose values or denominator links differ from the original validated frames.
testPublicationDataProof <- function(details,schema,release,root,policy) {
  f <- function(name)get(name,asNamespace("AchillesNext"))
  pages <- f(".v2_pages");transaction <- f(".store_transaction")
  on.exit({
    assignInNamespace(".v2_pages",pages,ns="AchillesNext")
    assignInNamespace(".store_transaction",transaction,ns="AchillesNext")
  })
  cause <- NULL
  assignInNamespace(".store_transaction",function(details,schema,work,...) {
    transaction(details,schema,function(tx)tryCatch(work(tx),error=function(e){cause<<-conditionMessage(e);stop(e)}),...)
  },ns="AchillesNext")
  for(mode in c("value","edge")) {
    changed <- FALSE;approved <- FALSE;cause <- NULL
    assignInNamespace(".v2_pages",function(kind,context,emit,metricId=NULL,assets=f(".v2_assets")()) {
      writer <- pages(kind,context,emit,metricId,assets);add <- writer$add
      if(kind=="data") writer$add <- function(row,key) {
        if(!changed && mode=="value" && metricId=="core.person.count") {
          row$values$person_count <- f(".nv_add")(row$values$person_count,"1");changed <<- TRUE
        }
        if(!changed && mode=="edge" && length(row$denominator_refs)) {
          ref <- row$denominator_refs[[1L]]
          row$denominator_refs[[1L]]$value <- f(".nv_add")(ref$value,"1");changed <<- TRUE
        }
        add(row,key)
      }
      writer
    },ns="AchillesNext")
    dest <- file.path(root,paste0("invalid-verified-",mode))
    err <- tryCatch(publishResultRelease(details,schema,release,dest,"fixture-proof","fixture-approval",policy,
      function(candidate){approved<<-TRUE;TRUE}),error=identity)
    stopifnot(inherits(err,"error"),identical(cause,"Projected rows differ from validated store rows"),
      changed,!approved,!file.exists(dest))
  }
  # Cross-metric row keys and full-scope capture totals are artifact-wide
  # constraints in addition to those checked by ordinary release validation.
  transaction(details,schema,function(tx) {
    tx$execute("CREATE TEMP TABLE achillesnext_aggregate_cell(release_id uuid,metric_id text,row_key text,state text,dimensions jsonb,record_count numeric) ON COMMIT DROP")
    tx$schema <- "pg_temp";table <- "pg_temp.achillesnext_aggregate_cell"
    add <- function(metric,key,tag,count,state="computed") tx$execute(paste0("INSERT INTO ",table," VALUES (",
      f(".store_uuid")(release),",",f(".store_literal")(metric),",",f(".store_literal")(key),",",f(".store_literal")(state),",",
      f(".store_literal")(f(".json")(list(period_kind="full_scope",concept_tag=list(kind=tag)))),",",count,")"))
    check <- function(expected=NULL) stopifnot(identical(tryCatch({f(".publication_complete_checks")(tx,release);NULL},error=conditionMessage),expected))
    mid <- "core.condition.capture_count"
    add(mid,"total","all","11");add(mid,"part","id","11");check()
    tx$execute(paste0("UPDATE ",table," SET record_count=0 WHERE row_key='part'"))
    check("Projected all-concepts record total does not reconcile")
    add(mid,"hidden","id","NULL","suppressed");check()
    add(mid,"other-total","all","11");check("Projected all-concepts record total does not reconcile")
    add("core.drug.capture_count","part","id","0");check("Repeated row identity")
  })
  cat("COMPLETE_STORE_PROJECTION_EXACT_FRAME_VALUE_EDGE_AND_GLOBAL_RECONCILIATION_OK\n")
}
