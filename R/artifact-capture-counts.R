# Capture-count pages repeat the same concept tags across periods and vice versa.
# Verify each distinct tag and period with the registered schema, then rebuild
# every complete row from those validated fields and its exact count strings.
.v2_capture_count_page <- function(doc, assets, check) {
  id <- doc$metric_id
  metric <- assets$rows[[id]]
  if (!isTRUE(assets$is_core) || !endsWith(id, ".capture_count") ||
      !identical(unlist(metric$dimensions), c("concept_tag","period_kind","period_start","period_end")) ||
      !identical(unlist(metric$value_keys_by_row_kind$counts), c("record_count","person_count")) ||
      length(metric$extra_dimensions_by_row_kind$counts)) return(NULL)

  rows <- doc$rows
  computed <- vapply(rows, function(row) {
    identical(row$row_kind,"counts") && identical(row$state,"computed") &&
      identical(row$denominator_refs,list())
  }, TRUE)
  if (sum(computed)<2L) return(NULL)
  rows <- rows[computed]

  tags <- lapply(rows, function(row) row$dimensions$concept_tag)
  tagIds <- vapply(tags, function(tag) {
    check()
    if (identical(tag$kind,"id")) {
      .nv_need(.string(tag$value),"Invalid concept ID")
      paste0("id:",tag$value)
    } else tag$kind
  }, "")
  representatives <- which(!duplicated(tagIds))
  tagsById <- lapply(tags[representatives], function(tag) {
    .nv_schema(tag,assets$dimensions$concept_tag,assets$metadata)
    list(key=.v2_component(tag,"concept_tag"), wire=.json(tag))
  })
  tagIndex <- match(tagIds,tagIds[representatives])

  periodFields <- c("period_kind","period_start","period_end")
  periodIds <- do.call(paste, c(lapply(periodFields,function(field)
    vapply(rows,function(row) row$dimensions[[field]],"")),sep="|"))
  representatives <- which(!duplicated(periodIds))
  enums <- .v2_dimension_enums(assets$profile)
  periods <- lapply(rows[representatives],function(row) {
    d <- row$dimensions[periodFields]
    for (field in periodFields) .nv_schema(d[[field]],assets$dimensions[[field]],assets$metadata)
    .v2_dimension_rules(id,row,assets,enums)
    keys <- vapply(periodFields,function(field) .v2_component(d[[field]],field),"")
    list(key=paste(keys,collapse="|"), tail=substring(.json(d),2L))
  })
  periodIndex <- match(periodIds,periodIds[representatives])
  dimensions <- paste0('{"concept_tag":',vapply(tagsById,`[[`,"","wire")[tagIndex],",",
                       vapply(periods,`[[`,"","tail")[periodIndex])
  keys <- paste(vapply(tagsById,`[[`,"","key")[tagIndex],
                vapply(periods,`[[`,"","key")[periodIndex],"E:counts",sep="|")
  .nv_need(all(nchar(keys,type="bytes")<=1024L),"Sort key too large")

  people <- vapply(rows,function(row) row$values$person_count,"")
  records <- vapply(rows,function(row) row$values$record_count,"")
  digits <- nchar(people,type="bytes")
  recordDigits <- nchar(records,type="bytes")
  .nv_need(all(digits+recordDigits<=65536L),"Row resource limit")
  .nv_need(all(grepl("^(0|[1-9][0-9]*)$",people)) &&
    all(grepl("^(0|[1-9][0-9]*)$",records)),"Invalid exact count")
  # Canonical unsigned integers compare by digit count, then lexicographically.
  .nv_need(all(digits<recordDigits | (digits==recordDigits & people<=records)),
           "People exceed physical records")

  identities <- .v2_identity_json(metric,"counts",dimensions)
  hashes <- vapply(identities,.hash,"",USE.NAMES=FALSE)
  values <- paste0('{"person_count":"',people,'","record_count":"',records,'"}')
  frames <- .v2_row_json("[]",dimensions,"null",paste0('"',hashes,'"'),'"counts"','"computed"',values)
  .nv_need(all(nchar(frames,type="bytes")+1L<=65536L),"Row resource limit")
  if (!all(computed)) {
    # Rows carrying references or explicit non-computed states use the ordinary
    # row verifier, including every reference and disclosure predicate.
    codec <- .v2_leaf_dimension_codec(id,assets)
    extra <- lapply(doc$rows[!computed],function(row) {
      check()
      .v2_row(id,row,assets,includeFrame=TRUE,dimensionCodec=codec)
    })
    join <- function(common,other) {
      result <- character(length(computed))
      result[computed] <- common
      result[!computed] <- other
      result
    }
    keys <- join(keys,vapply(extra,`[[`,"","key"))
    frames <- join(frames,vapply(extra,function(x) rawToChar(x$bytes[-length(x$bytes)]),""))
  }
  list(keys=paste0(id,"|",keys),frames=frames)
}
