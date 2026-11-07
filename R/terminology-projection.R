# Producer-side disk-backed sorting; no vocabulary map in consumer memory.
.term_temp_writer <- function(tx,table) {
  queue<-character();bytes<-0L;prefix<-paste0("INSERT INTO pg_temp.",table," VALUES ")
  flush<-function(){if(length(queue))tx$execute(paste0(prefix,paste(queue,collapse=",")));queue<<-character();bytes<<-0L}
  add<-function(key,entry,nameKey=NULL) {
    item<-paste0("(",.store_literal(key),",",.store_literal(.json(entry)),"::jsonb,",if(is.null(nameKey))"NULL" else .store_literal(nameKey),")")
    n<-nchar(item,type="bytes");.nv_need(n<=16384L)
    if(length(queue)&&(length(queue)>=128L||nchar(prefix,type="bytes")+bytes+n+length(queue)>262144L))flush()
    queue<<-c(queue,item);bytes<<-bytes+n
  }
  list(add=add,finish=flush)
}
.term_load <- function(tx,snapshot,context,cancel) {
  .term_require_extension(tx)
  tx$execute("CREATE TEMP TABLE achillesnext_term_input (id_key text COLLATE \"C\" PRIMARY KEY,entry jsonb NOT NULL,name_key text COLLATE \"C\") ON COMMIT DROP")
  writer<-.term_temp_writer(tx,"achillesnext_term_input")
  header<-.term_snapshot(snapshot,function(entry,key,header) {
    .nv_need(identical(header$source_id,context$source_id)&&identical(header$release_id,context$release_id),"Snapshot release/source mismatch")
    writer$add(key,entry,if(entry$label_state=="available").term_name_key(entry) else NULL)
  },cancel)
  .nv_need(identical(header$source_id,context$source_id)&&identical(header$release_id,context$release_id),"Snapshot release/source mismatch")
  writer$finish()
  metadata<-.object(extension_version="1.0.0",matching="ascii-fold-prefix-v1",label_source=header$label_source,
    vocabulary_release=header$vocabulary_release,snapshot_sha256=snapshot$sha256,capture=header$capture)
  assets<-.profile_context(context)
  if("core.source.passport"%in%names(assets$metrics)).store_rows(tx,context$release_id,"core.source.passport",function(row,key) {
    if(row$state!="suppressed").term_vocab_match(row$values,metadata)
  },assets)
  metadata
}
.term_project <- function(tx,sql,context,concepts,terms,cancel) {
  tx$execute("CREATE TEMP TABLE achillesnext_term_names (id_key text COLLATE \"C\" PRIMARY KEY,entry jsonb NOT NULL,name_key text COLLATE \"C\" NOT NULL) ON COMMIT DROP")
  names<-.term_temp_writer(tx,"achillesnext_term_names")
  joined<-paste0("SELECT jsonb_build_object('tag',t.doc->'tag','key',t.doc->>'key','saved',i.entry)::text FROM (SELECT doc::jsonb AS doc FROM (",sql,
    ") raw(doc)) t LEFT JOIN pg_temp.achillesnext_term_input i ON i.id_key=t.doc->>'key' ORDER BY (t.doc->>'key') COLLATE \"C\"")
  tx$stream(joined,function(text) {
    .term_check(cancel);item<-.store_decode(text);key<-.v2_component(item$tag,"concept_tag")
    .nv_need(identical(key,item$key))
    entry<-item$saved %||% .object(concept_tag=item$tag,label=NULL,label_state="unavailable",label_reason_code="terminology.id_not_in_snapshot",domain_id=NULL,vocabulary_id=NULL)
    .nv_need(identical(.term_entry(entry,"concept_catalogue","2.1.0"),key),"Snapshot ID mismatch")
    concepts$add(entry,key)
    if(entry$label_state=="available")names$add(key,entry,.term_name_key(entry))
  })
  names$finish()
  tx$stream("SELECT entry::text FROM pg_temp.achillesnext_term_names ORDER BY name_key COLLATE \"C\"",function(text) {
    .term_check(cancel);entry<-.store_decode(text);terms$add(entry,.term_entry(entry,"terminology","2.1.0"))
  })
}
.term_row_ids <- function(row) {
  if(identical(row$state,"suppressed"))return(character())
  ids<-character()
  for(n in names(row$dimensions)) {
    v<-row$dimensions[[n]]
    if(grepl("_tag$",n)&&is.list(v)&&identical(v$kind,"id"))ids<-c(ids,.v2_component(v,"concept_tag"))
    if(grepl("_concept_id$",n)&&is.character(v)&&v!="null")ids<-c(ids,.v2_component(v,"integer"))
  }
  unique(ids)
}
