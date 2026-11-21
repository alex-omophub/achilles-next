# Values often repeat in adjacent rows. Reuse the schema check and both encodings
# only for the same typed value of the same field in this metric and page.
.v2_leaf_dimension_codec <- function(mid, assets) {
  metric <- assets$rows[[mid]]
  enums <- .v2_dimension_enums(assets$profile)
  layouts <- lapply(names(metric$value_keys_by_row_kind),function(kind) {
    fields <- c(unlist(metric$dimensions),unlist(metric$extra_dimensions_by_row_kind[[kind]]))
    canonical <- if(length(fields)) order(fields,method="radix") else integer()
    list(fields=fields,canonical=canonical,prefix=paste0(vapply(fields,.json,""),":"))
  })
  names(layouts) <- names(metric$value_keys_by_row_kind)
  cache <- new.env(hash=TRUE,parent=emptyenv())
  entries <- 0L
  encode <- function(name,value) {
    hint <- if(is.list(value)) value[["value"]] %||% value[["kind"]] else value
    cacheable <- is.character(hint) && length(hint)==1L && !is.na(hint) && nchar(hint,type="bytes")<=512L
    if(cacheable) {
      id <- paste(name,hint,sep="=")
      entry <- cache[[id]]
      if(!is.null(entry) && identical(entry$value,value)) return(entry)
    }
    .nv_schema(value,assets$dimensions[[name]],assets$metadata)
    entry <- list(value=value,key=.v2_component(value,name),wire=.json(value))
    if(cacheable) {
      if(entries==256L) {
        cache <<- new.env(hash=TRUE,parent=emptyenv())
        entries <<- 0L
      }
      cache[[id]] <- entry
      entries <<- entries+1L
    }
    entry
  }
  function(row) {
    layout <- layouts[[row$row_kind]]
    n <- length(layout$fields)
    keys <- character(n+1L); terms <- character(n)
    for(i in seq_len(n)) {
      name <- layout$fields[[i]]
      entry <- encode(name,row$dimensions[[name]])
      keys[[i]] <- entry$key;terms[[i]] <- paste0(layout$prefix[[i]],entry$wire)
    }
    keys[[n+1L]] <- paste0("E:",row$row_kind)
    key <- paste(keys,collapse="|")
    .nv_need(nchar(key,type="bytes")<=1024L,"Sort key too large")
    .v2_dimension_rules(mid,row,assets,enums)
    list(key=key,wire=paste0("{",paste(terms[layout$canonical],collapse=","),"}"))
  }
}
