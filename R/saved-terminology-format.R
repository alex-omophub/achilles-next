# Physical 2.1.0 is opt-in; original 2.0.0 remains a closed format.
.term_version <- function(version) .string(version)&&version%in%c("2.0.0","2.1.0")
.term_normalize <- function(x) chartr("ABCDEFGHIJKLMNOPQRSTUVWXYZ","abcdefghijklmnopqrstuvwxyz",trimws(x,whitespace=" "))
.term_prefix <- function(x) paste0("T:",paste(sprintf("%02x",as.integer(charToRaw(enc2utf8(.term_normalize(x))))),collapse=""))
.term_name_key <- function(entry) paste0(.term_prefix(entry$label),"!",.v2_component(entry$concept_tag,"concept_tag"))
.term_assets <- function() {
  if(exists("terminology1",.validation_cache,inherits=FALSE))return(invisible(TRUE))
  path<-system.file("contracts/v2.1",package="AchillesNext",mustWork=TRUE)
  lock<-jsonlite::fromJSON(file.path(path,"schema-lock.json"),simplifyVector=FALSE)
  .nv_need(identical(lock$contract_version,"2.1.0")&&identical(lock$extension_version,"1.0.0")&&identical(names(lock$sha256),"terminology.schema.json"))
  .nv_need(identical(digest::digest(file=file.path(path,"terminology.schema.json"),algo="sha256"),lock$sha256[[1]]),"Terminology schema integrity failure")
  assign("terminology1",TRUE,.validation_cache);invisible(TRUE)
}
.term_identity <- function(x) {
  .nv_need(.nv_object(x)&&!anyDuplicated(names(x)),"Invalid terminology identity object")
  schema<-.v2_assets()$metadata;.nv_schema(x,schema$`$defs`$identity,schema)
  .nv_need(.string(x$state))
  if(x$state=="known") .nv_need(.string(x$value)&&.string(x$basis)&&.string(x$assertion_id)&&is.null(x$reason_code)) else
    .nv_need(is.null(x$value)&&is.null(x$basis)&&is.null(x$assertion_id)&&.string(x$reason_code))
  invisible(x)
}
.term_metadata <- function(x) {
  .term_assets()
  .v2_keys(x,c("extension_version","matching","label_source","vocabulary_release","snapshot_sha256","capture"))
  .nv_need(identical(x$extension_version,"1.0.0")&&identical(x$matching,"ascii-fold-prefix-v1")&&
    .string(x$snapshot_sha256)&&grepl("^[a-f0-9]{64}$",x$snapshot_sha256))
  .term_identity(x$label_source);.term_identity(x$vocabulary_release)
  .v2_keys(x$capture,c("captured_at","within_capture","with_aggregate_release"))
  .nv_need(.nv_date(x$capture$captured_at,TRUE)&&identical(x$capture$within_capture,"single_repeatable_read")&&
    identical(x$capture$with_aggregate_release,"not_asserted"))
  invisible(x)
}
.term_entry <- function(entry,kind,version) {
  if(identical(version,"2.0.0")) {
    .v2_keys(entry,c("concept_tag","label","label_state",if(kind=="terminology")"domain_id"))
    .nv_need(identical(entry$concept_tag$kind,"id"),"Only retained exact concept IDs are indexed")
    .nv_need(identical(entry$label_state,"unavailable")&&is.null(entry$label)&&(kind!="terminology"||is.null(entry$domain_id)),"Unapproved terminology fields")
    return(.v2_component(entry$concept_tag,"concept_tag"))
  }
  .nv_need(identical(version,"2.1.0"),"Unsupported terminology format")
  .v2_keys(entry,c("concept_tag","label","label_state","label_reason_code","domain_id","vocabulary_id"))
  .nv_need(identical(entry$concept_tag$kind,"id"),"Only retained exact concept IDs are indexed")
  key<-.v2_component(entry$concept_tag,"concept_tag")
  .nv_need(.string(entry$label_state)&&entry$label_state%in%c("available","unavailable"))
  for(n in c("domain_id","vocabulary_id")) .nv_need(is.null(entry[[n]])||
    (.string(entry[[n]])&&validUTF8(entry[[n]])&&nchar(entry[[n]],type="bytes")<=128L&&!grepl("[[:cntrl:]]",entry[[n]])))
  if(entry$label_state=="available") {
    .nv_need(.string(entry$label)&&validUTF8(entry$label)&&nchar(entry$label,type="bytes")<=1024L&&
      !grepl("[[:cntrl:]]",entry$label)&&nzchar(.term_normalize(entry$label))&&is.null(entry$label_reason_code),"Invalid saved label")
  } else .nv_need(is.null(entry$label)&&.string(entry$label_reason_code)&&
    entry$label_reason_code%in%c("terminology.missing_label","terminology.id_not_in_snapshot"))
  if(kind=="terminology") {
    .nv_need(entry$label_state=="available","Name index contains an unavailable label")
    key<-.term_name_key(entry)
  }
  .nv_need(.saved_key(key,version));key
}
.term_vocab_match <- function(passport,metadata) {
  if(!is.null(metadata)&&identical(passport$vocabulary_release$state,"known")&&identical(metadata$vocabulary_release$state,"known"))
    .nv_need(identical(passport$vocabulary_release$value,metadata$vocabulary_release$value),"Saved vocabulary release disagrees with passport")
}
.term_check <- function(cancel) {
  .nv_need(is.function(cancel));v<-cancel();.nv_need(identical(v,TRUE)||identical(v,FALSE))
  if(v).saved_error("aborted")
  invisible(NULL)
}
