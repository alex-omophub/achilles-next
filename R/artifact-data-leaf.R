# Verify canonical data bytes using the frames produced by semantic validation.
# Each row is compared with its exact location in the bounded input page.
.v2_artifact_data_leaf <- function(bytes, descriptor, context, assets, check, retainFrames=TRUE) {
  .nv_need(identical(as.character(length(bytes)),descriptor$bytes) &&
    identical(.v2_hash(bytes),descriptor$sha256),"Page integrity mismatch")
  doc <- .nv_json(bytes)
  .v2_keys(doc,c(names(context),"kind","metric_id","metric_version","rows"))
  mid <- doc$metric_id
  .nv_need(.string(mid) && mid %in% names(assets$metrics),"Unknown metric")
  n <- length(doc$rows)
  .nv_need(.nv_array(doc$rows) && n>0L && n<=2048L &&
    identical(as.character(n),descriptor$rows),"Leaf row count mismatch")

  envelope <- .v2_data_envelope(context,mid,assets$metrics[[mid]]$version)
  offset <- length(envelope$prefix)
  end <- length(bytes)-length(envelope$suffix)
  .nv_need(end>offset && identical(bytes[seq_len(offset)],envelope$prefix) &&
    identical(bytes[seq.int(end+1L,length(bytes))],envelope$suffix),"Noncanonical data page envelope")

  keys <- character(n)
  frames <- if(retainFrames) vector("list",n)
  dimensions <- if(retainFrames) character(n)
  comma <- as.raw(44L)
  dimensionCodec <- .v2_leaf_dimension_codec(mid,assets)
  for(i in seq_len(n)) {
    check()
    checked <- .v2_row(mid,doc$rows[[i]],assets,includeFrame=TRUE,dimensionCodec=dimensionCodec)
    frame <- checked$bytes
    # The frame's terminal newline becomes a comma between rows and the
    # envelope's closing bracket after the last row.
    size <- length(frame)
    frame[[size]] <- if(i==n) as.raw(93L) else comma
    .nv_need(offset+size<=end+1L && identical(bytes[seq.int(offset+1L,length.out=size)],frame),
      "Noncanonical data row bytes")
    if(retainFrames) {
      frames[[i]] <- checked$bytes
      dimensions[[i]] <- checked$dimensions
    }
    offset <- offset+size
    keys[[i]] <- paste0(mid,"|",checked$key)
  }
  .nv_need(offset==end+1L,"Noncanonical data page length")
  .nv_need(!anyDuplicated(keys) && identical(order(keys,method="radix"),seq_len(n)),"Unordered leaf")
  list(doc=doc,keys=keys,frames=frames,dimensions=dimensions)
}
