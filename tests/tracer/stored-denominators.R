# Copy the small registered release into session-local tables without FKs.
# Invalid references must be detected by the reader independently of storage constraints.
testStoredDenominators <- function(details, schema, release, assets) {
  ns <- asNamespace("AchillesNext")
  mid <- "example.person.gender_count"
  parent <- "example.person.count"
  get(".store_transaction", ns)(details, schema, function(tx) {
    rid <- get(".store_uuid", ns)(release)
    for (table in c("achillesnext_aggregate_cell","achillesnext_denominator_edge")) {
      tx$execute(paste0("CREATE TEMP TABLE ", table, " ON COMMIT DROP AS SELECT * FROM ",
                        tx$schema, ".", table, " WHERE release_id=", rid))
    }
    shadow <- tx
    shadow$schema <- "pg_temp"
    read <- function(metric) {
      result <- list()
      get(".store_rows", ns)(shadow, release, metric, function(row,key) {
        result[[key]] <<- row
      }, assets)
      result
    }
    children <- read(mid)
    singleton <- read(parent)[[1L]]
    stopifnot(length(children)>0L, all(vapply(children, function(row) {
      ref <- row$denominator_refs[[1L]]
      identical(ref$row_key, singleton$row_key) && identical(ref$value, singleton$values$person_count)
    }, TRUE)))
    key <- get(".store_literal", ns)(children[[1L]]$row_key)
    # The exact requested key sorts before the true singleton. Put decoys at
    # that key in another release and metric; none may satisfy this edge.
    for (override in c("'release_id','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'",
                       "'metric_id','example.wrong_metric'")) {
      tx$execute(paste0("INSERT INTO pg_temp.achillesnext_aggregate_cell ",
        "SELECT (jsonb_populate_record(NULL::pg_temp.achillesnext_aggregate_cell, to_jsonb(t)||",
        "jsonb_build_object('row_key',repeat('0',64),",override,"))).* ",
        "FROM pg_temp.achillesnext_aggregate_cell t WHERE release_id=",rid," AND metric_id='",parent,"'"))
    }
    tx$execute(paste0("UPDATE pg_temp.achillesnext_denominator_edge SET target_row_key=repeat('0',64) WHERE row_key=",key))
    rejected <- function(metric) identical(tryCatch({read(metric);NULL}, error=conditionMessage),
                                           "Missing stored denominator target")
    stopifnot(rejected(mid))
    tx$execute(paste0("UPDATE pg_temp.achillesnext_denominator_edge SET target_row_key=",
                      get(".store_literal", ns)(singleton$row_key)," WHERE row_key=",key))
    tx$execute(paste0("UPDATE pg_temp.achillesnext_aggregate_cell SET person_count=0 WHERE row_key=", key))
    stopifnot(identical(read(mid)[[1L]]$values$person_count, "0"))
    tx$execute(paste0("UPDATE pg_temp.achillesnext_aggregate_cell SET person_count=NULL, state='suppressed', ",
                      "reason_code='fixture.suppressed' WHERE row_key=", key))
    tx$execute(paste0("DELETE FROM pg_temp.achillesnext_denominator_edge WHERE row_key=", key))
    suppressed <- read(mid)[[1L]]
    stopifnot(is.null(suppressed$values), !length(suppressed$denominator_refs))
    # A foreign target must not disappear: this singleton legitimately has no
    # references, so silently dropping the edge would accept its corrupted row.
    tx$execute(paste0("INSERT INTO pg_temp.achillesnext_denominator_edge VALUES (",
      rid, ",'", parent, "',", get(".store_literal", ns)(singleton$row_key),
      ",'person_count','", parent, "',repeat('0',64),'person_count')"))
    stopifnot(rejected(parent))
  })
}
