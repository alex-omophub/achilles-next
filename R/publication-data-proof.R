# Hash the concatenated canonical rows for each metric in fixed byte blocks.
# Input boundaries (one stored row or a complete file page) do not affect the
# digest. At most one page, one partial block and one digest per metric are held.
.publication_row_stream <- function() {
  block <- 65536L
  metric <- NULL; digests <- list(); chain <- raw(32L)
  pieces <- list(); buffered <- 0L
  finishMetric <- function() {
    if(!is.null(metric)) {
      digests[[metric]] <<- .v2_hash(c(as.raw(255L),chain,do.call(c,pieces)))
      chain <<- raw(32L); pieces <<- list(); buffered <<- 0L
    }
  }
  add <- function(mid,bytes) {
    if(!identical(metric,mid)) {
      .nv_need(is.null(metric)||.v2_less(metric,mid),"Unordered projection metric")
      finishMetric();metric <<- mid
    }
    pieces[[length(pieces)+1L]] <<- bytes;buffered <<- buffered+length(bytes)
    if(buffered>=block) {
      joined <- do.call(c,pieces);at <- 1L
      while(buffered>=block) {
        chain <<- digest::digest(c(chain,joined[seq.int(at,length.out=block)]),algo="sha256",serialize=FALSE,raw=TRUE)
        at <- at+block;buffered <<- buffered-block
      }
      pieces <<- if(buffered)list(joined[seq.int(at,length(joined))]) else list()
    }
  }
  list(add=add,finish=function(){finishMetric();metric <<- NULL;digests})
}

# This witness is private to one locked, unfiltered core publication. It binds
# staged data to the canonical frames that passed the store validators. Ordinary
# artifact admission has no store witness and always validates its own rows.
.publication_data_proof <- function(release,policy,savedTerminology,publicationId,scopeId) {
  assets <- release$assets
  if(!isTRUE(assets$is_core)||!is.null(savedTerminology)||
     !setequal(.v2_policy(policy,assets),names(assets$metrics)))return(NULL)
  expected <- .publication_row_stream();actual <- .publication_row_stream()
  comma <- as.raw(44L)
  add <- function(mid,frame) {
    .nv_need(length(frame)>1L&&frame[[length(frame)]]==as.raw(10L),"Invalid canonical row frame")
    frame[[length(frame)]] <- comma
    expected$add(mid,frame)
  }
  # Parse each bounded leaf to check its row count and true index endpoints.
  # Match its envelope exactly, then fingerprint the original payload bytes.
  read <- function(d,bytes,context) {
    .nv_need(identical(as.character(length(bytes)),d$bytes)&&identical(.v2_hash(bytes),d$sha256),"Page integrity mismatch")
    doc <- .nv_json(bytes);mid <- doc$metric_id
    .nv_need(.string(mid)&&mid%in%names(assets$metrics)&&.nv_array(doc$rows))
    rows <- length(doc$rows)
    .nv_need(rows>0L&&rows<=2048L&&identical(as.character(rows),d$rows),"Leaf row count mismatch")
    envelope <- .v2_data_envelope(context,mid,assets$metrics[[mid]]$version)
    prefix <- length(envelope$prefix);end <- length(bytes)-length(envelope$suffix)
    .nv_need(end>prefix&&identical(bytes[seq_len(prefix)],envelope$prefix)&&
      identical(bytes[seq.int(end+1L,length(bytes))],envelope$suffix),"Noncanonical data page envelope")
    actual$add(mid,c(bytes[seq.int(prefix+1L,end)],comma))
    bound <- function(row)paste0(mid,"|",.v2_sort(assets$rows[[mid]],row))
    list(metric_id=mid,lo=bound(doc$rows[[1L]]),hi=bound(doc$rows[[rows]]))
  }
  finish <- function(root,catalogue) {
    .nv_need(identical(expected$finish(),actual$finish()),"Projected rows differ from validated store rows")
    .nv_need(identical(.json(catalogue),.json(release$datasets)),"Projected catalogue differs from validated inventory")
    context <- release$context
    .nv_need(identical(root$publication_id,publicationId)&&identical(root$access_scope_id,scopeId)&&
      identical(root$contract_version,"2.0.0")&&identical(.json(root$disclosure$policy),.json(policy)) &&
      all(vapply(c("source_id","release_id","profile_id","profile_revision","profile_sha256"),function(k)identical(root[[k]],context[[k]]),TRUE)) &&
      identical(root$source_schema$sha256,context$observed_schema_sha256)&&
      identical(root$source_schema$declared_cdm_version,context$declared_cdm_version)&&
      identical(root$source_consistency$within_run,context$consistency_basis),"Projected release context mismatch")
  }
  list(add=add,read=read,finish=finish)
}

# The store enforces per-metric keys. Artifact admission additionally requires
# global row-key uniqueness and reconciles full-scope all-concept capture totals.
.publication_complete_checks <- function(tx,id) {
  cells <- paste0(tx$schema,".achillesnext_aggregate_cell")
  scope <- paste0(" FROM ",cells," WHERE release_id=",.store_uuid(id))
  .nv_need(tx$one(paste0("SELECT CASE WHEN EXISTS (SELECT row_key",scope,
    " GROUP BY row_key HAVING count(*)>1) THEN 'bad' ELSE 'ok' END"))=="ok","Repeated row identity")
  totals <- paste0("SELECT metric_id,bool_or(state='suppressed') AS hidden,",
    "count(record_count) FILTER (WHERE dimensions->>'period_kind'='full_scope' AND dimensions->'concept_tag'->>'kind'='all') AS all_cells,",
    "sum(record_count) FILTER (WHERE dimensions->>'period_kind'='full_scope' AND dimensions->'concept_tag'->>'kind'='all') AS total,",
    "sum(record_count) FILTER (WHERE dimensions->>'period_kind'='full_scope' AND dimensions->'concept_tag'->>'kind'<>'all') AS parts",
    scope," AND right(metric_id,14)='.capture_count' GROUP BY metric_id")
  .nv_need(tx$one(paste0("SELECT CASE WHEN EXISTS (SELECT 1 FROM (",totals,") g WHERE all_cells>1 OR ",
    "(all_cells=1 AND NOT hidden AND total<>coalesce(parts,0))) THEN 'bad' ELSE 'ok' END"))=="ok","Projected all-concepts record total does not reconcile")
}
