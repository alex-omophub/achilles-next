# Templates have only fixed internal identifiers. Values and registry-derived
# fragments are bound in a single pass so text cannot turn into another token.
.pg_count_store_template <- function(name, bindings) {
  file <- switch(name, cells = "count-store-cells.sql", edges = "count-store-edges.sql")
  path <- system.file("sql", "postgresql", file, package = "AchillesNext", mustWork = TRUE)
  sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
  match <- gregexpr("__[A-Z_]+__", sql, perl = TRUE)
  tokens <- regmatches(sql, match)[[1L]]
  .candidate_need(all(tokens %in% names(bindings)))
  regmatches(sql, match) <- list(unname(bindings[tokens]))
  sql
}

.pg_count_row_key <- function(registry, dimensions) {
  suffix <- paste0(',"metric_id":', .json(registry$id), ',"metric_version":',
                   .json(registry$version), ',"row_kind":"counts"}')
  paste0("encode(sha256(convert_to('{\"dimensions\":'||(", dimensions, ")||",
         .store_literal(suffix), "||chr(10),'UTF8')),'hex')")
}

.pg_count_target_sql <- function(rule, registry, fields) {
  # The checked count shapes have exact, one-measure denominator rules.
  .candidate_need(identical(rule$match, "exact") && identical(rule$row_kind, "counts") &&
    !length(rule$key_defaults) && length(rule$measures) == 1L &&
    identical(rule$measures[[1L]]$source, "person_count") &&
    identical(rule$measures[[1L]]$target, "person_count"))
  need <- character()
  for (key in names(rule$when)) {
    .candidate_need(key %in% names(fields) && .string(rule$when[[key]]))
    need <- c(need, paste0("d->", .store_literal(key), " = ",
                           .store_literal(.json(rule$when[[key]])), "::jsonb"))
  }
  predicate <- if (length(need)) paste(need, collapse = " AND ") else "true"
  dimensions <- rule$dimensions
  .candidate_need(setequal(names(dimensions), unlist(registry$dimensions, use.names = FALSE)))
  if (!length(dimensions)) {
    key <- .v2_row_identity(registry, .object(row_kind = "counts", dimensions = .object()))
    return(c("__WHEN__" = predicate, "__TARGET_DIMS__" = "'{}'::jsonb", "__TARGET_KEY__" = .store_literal(key)))
  }
  source <- vapply(dimensions, function(binding) binding$source, "")
  .candidate_need(all(source %in% names(fields)))
  pairs <- paste(.store_literal(names(source)), paste0("d->", .store_literal(source)), sep = ",")
  wire <- vapply(fields[unname(source)], function(x) x$wire, "")
  names(wire) <- names(source)
  c("__WHEN__" = predicate, "__TARGET_DIMS__" = paste0("jsonb_build_object(", paste(pairs, collapse = ","), ")"),
    "__TARGET_KEY__" = .pg_count_row_key(registry, .pg_count_object_sql(wire)))
}

.candidate_copy_import <- function(tx, mid, dataset, assets, ids, tick, limits, receipt) {
  tick()
  schema <- gsub('"', '', tx$schema, fixed = TRUE)
  .candidate_need(.batch_identifier(schema) && identical(tx$schema, paste0('"', schema, '"')))
  .candidate_need(.string(mid) && identical(dataset$metric_id, mid) && mid %in% names(assets$rows))
  registry <- assets$rows[[mid]]
  shape <- .pg_count_shape(registry, assets$analysis$definitions$analyses[[mid]])
  .candidate_need(!is.null(shape) && .v2_count(dataset$rows) && is.numeric(receipt$rows) &&
    length(receipt$rows) == 1L && is.finite(receipt$rows) && receipt$rows >= 0 &&
    receipt$rows <= limits$max_aggregate_rows && receipt$rows == floor(receipt$rows) &&
    identical(format(receipt$rows, scientific = FALSE, trim = TRUE), dataset$rows))
  lit <- .store_literal
  metric <- lit(mid)
  rid <- .store_uuid(ids$release_id)
  table <- function(name) paste0(tx$schema, ".achillesnext_", name)
  scope <- paste0("release_id=", rid, " AND metric_id=", metric)
  .candidate_need(identical(tx$one(paste0(
    "SELECT count(*)::text FROM ", table("result_release"), " l JOIN ", table("analysis_run"),
    " a USING(run_id) JOIN ", table("dataset"), " d USING(release_id) WHERE l.release_id=", rid,
    " AND l.run_id=", .store_uuid(ids$run_id), " AND a.source_release_id=", .store_uuid(ids$source_release_id),
    " AND l.state='building' AND a.state='running' AND a.profile_sha256=", lit(assets$hash),
    " AND d.metric_id=", metric, " AND d.definition_sha256=", lit(dataset$definition_sha256),
    " AND d.row_count=", dataset$rows, " AND NOT EXISTS (SELECT 1 FROM ", table("aggregate_cell"),
    " WHERE ", scope, ")")), "1"))
  bindings <- c("__STORE__" = tx$schema, "__METRIC__" = metric, "__RELEASE__" = rid)
  dims <- unlist(registry$dimensions, use.names = FALSE)
  fields <- stats::setNames(lapply(dims, .pg_count_field_sql), dims)
  canonical <- .pg_count_object_sql(vapply(fields, function(x) x$wire, ""))
  sort <- paste0("(", vapply(fields, function(x) x$sort, ""), ")", collapse = "||'|'||")
  sql <- .pg_count_store_template("cells", c(bindings, "__ROW_KEY__" = .pg_count_row_key(registry, canonical),
                                              "__SORT_KEY__" = paste0(sort, "||'|E:counts'")))
  tx$execute(sql)
  sizes <- nchar(enc2utf8(sql), type = "bytes")
  rule <- .analysis_rule(mid, assets)
  predicate <- "false"
  if (!is.null(rule)) {
    target <- .pg_count_target_sql(rule, assets$rows[[rule$metric_id]], fields)
    predicate <- target[["__WHEN__"]]
    stmt <- .pg_count_store_template("edges", c(bindings, target, "__TARGET__" = lit(rule$metric_id)))
    tx$execute(stmt)
    sizes <- c(sizes, nchar(enc2utf8(stmt), type = "bytes"))
  }
  # Independently count the rows demanding a denominator from the verified
  # frames. A join losing an eligible zero cell must fail this check, too.
  totals <- .store_decode(tx$one(paste0(
    "SELECT jsonb_build_object('rows',(SELECT count(*)::text FROM ", table("aggregate_cell"),
    " WHERE ", scope, "),'edges',(SELECT count(*)::text FROM ", table("denominator_edge"),
    " WHERE ", scope, "),'expected',(SELECT count(*)::text FROM (SELECT convert_from(doc,'UTF8')::jsonb->'dimensions' d",
    " FROM pg_temp.count_frames WHERE mid=", metric, ") f WHERE ", predicate, "))::text")))
  .candidate_need(identical(totals$rows, dataset$rows))
  .candidate_need(identical(totals$expected, totals$edges), "candidate.invalid_denominator")
  tick()
  list(rows = totals$rows, edges = totals$edges, cell_statements = 1L,
       edge_statements = as.integer(!is.null(rule)), sql_bytes = sum(sizes), max_statement_bytes = max(sizes))
}
