# Select formats by the installed, SHA-checked row and analysis registries.
# A future profile or row version falls through to its original execution path.
.pg_count_shape <- function(registry, definition) {
  if (!identical(registry$version, "1.0.0") ||
      !identical(names(registry$value_keys_by_row_kind), "counts") ||
      length(registry$extra_dimensions_by_row_kind)) return(NULL)
  dimensions <- unlist(registry$dimensions, use.names = FALSE)
  values <- unlist(registry$value_keys_by_row_kind$counts, use.names = FALSE)
  rule <- definition$denominator$rule
  matches <- function(d, v) identical(dimensions, d) && identical(values, v)
  both <- c("record_count", "person_count")
  if (matches(c("concept_tag","period_kind","period_start","period_end"), both) &&
      isTRUE(rule %in% c("full_scope_people","same_period_people"))) return("period")
  if (matches(c("concept_tag","source_concept_tag","source_value_state"), both) &&
      is.null(rule)) return("source")
  if (matches(c("concept_tag","event_count"), "person_count") &&
      identical(rule, "all_people")) return("frequency")
  if (matches(c("concept_tag","year","gender_concept_id","year_age_decile"), "person_count") &&
      identical(rule, "same_year_gender_age_people")) return("demographic")
  NULL
}

# All SQL expressions below use package-internal column names.
.pg_count_integer_sql <- function(json, value) {
  paste0("jsonb_typeof(", json, ")='string' AND ", value,
         " ~ '^(0|-?[1-9][0-9]*)$' AND length(ltrim(", value, ",'-'))<=512")
}
.pg_count_integer_order_sql <- function(x) {
  paste0("CASE WHEN left(",x,",1)='-' THEN 'I0'||lpad((999999-length(substr(",x,
    ",2)))::text,6,'0')||':'||translate(substr(",x,",2),'0123456789','9876543210') ",
    "ELSE 'I1'||lpad(length(",x,")::text,6,'0')||':'||",x," END")
}
.pg_count_date_sql <- function(x) {
  paste0("CASE WHEN ",x," ~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' ",
    "AND length(",x,")=10 AND left(",x,",4)<>'0000' THEN substr(",x,
    ",9,2)::int<=extract(day from make_date(left(",x,",4)::int,substr(",x,
    ",6,2)::int,1)+interval '1 month -1 day') ELSE false END")
}
.pg_count_key_set <- function(object, keys) {
  terms <- vapply(keys,.store_literal,"")
  a <- paste0("ARRAY[",paste(terms,collapse=","),"]::text[]")
  paste0("(jsonb_typeof(",object,")='object' AND jsonb_exists_all(",object,",",a,
    ") AND ",object,"-",a,"='{}'::jsonb)")
}
.pg_count_object_sql <- function(fields) {
  # Canonical byte order is independent of registry sort-key order.
  fields <- fields[order(names(fields),method="radix")]
  parts <- paste0(vapply(paste0('"',names(fields),'":'),.store_literal,""),"||(",fields,")")
  paste0("'{'||",paste(parts,collapse="||','||"),"||'}'")
}
.pg_count_field_sql <- function(name) {
  key <- .store_literal(name)
  json <- paste0("(d->",key,")")
  value <- paste0("(d->>",key,")")
  wire <- paste0(json,"::text")
  if (endsWith(name,"_tag")) {
    k <- paste0("(",json,"->>'kind')")
    t <- paste0("(",json,"->>'value')")
    single <- paste0(.pg_count_key_set(json,"kind")," AND ",k," IN ('all','null','schema_absent')")
    id <- paste0(.pg_count_key_set(json,c("kind","value"))," AND ",k,"='id' AND ",
      .pg_count_integer_sql(paste0("(",json,"->'value')"),t))
    wire <- paste0("CASE WHEN ",single," THEN '{\"kind\":'||(",json,"->'kind')::text||'}' WHEN ",
      id," THEN '{\"kind\":\"id\",\"value\":'||(",json,"->'value')::text||'}' END")
    sort <- paste0("CASE ",k," WHEN 'all' THEN 'A' WHEN 'null' THEN 'N' WHEN 'schema_absent' THEN 'S' ELSE ",
      .pg_count_integer_order_sql(t)," END")
    return(list(wire=wire,sort=sort,valid=paste0("(",wire,") IS NOT NULL")))
  }
  if (name %in% c("event_count","year","gender_concept_id")) {
    check <- .pg_count_integer_sql(json,value)
    sort <- .pg_count_integer_order_sql(value)
    if (name=="gender_concept_id") {
      check <- paste0("(",json,"='\"null\"'::jsonb OR (",check,"))")
      sort <- paste0("CASE WHEN ",value,"='null' THEN 'N' ELSE ",sort," END")
    }
  } else if (name %in% c("period_start","period_end")) {
    check <- paste0("jsonb_typeof(",json,")='string' AND (",value,"='null' OR ",.pg_count_date_sql(value),")")
    sort <- paste0("CASE WHEN ",value,"='null' THEN 'N' ELSE 'D'||",value," END")
  } else {
    choices <- switch(name,period_kind=c("full_scope","undated","calendar_month","calendar_year"),
      year_age_decile=c("unknown",as.character(0:13)),source_value_state=c("null","blank","nonblank","schema_absent"))
    .nv_need(length(choices)>0L,"Unexpected count dimension")
    check <- paste0("jsonb_typeof(",json,")='string' AND ",value," IN (",paste(vapply(choices,.store_literal,""),collapse=","),")")
    sort <- paste0("'E:'||",value)
  }
  list(wire=wire,sort=sort,valid=check)
}

.pg_count_select_sql <- function(output, registry, shape) {
  dimensions <- unlist(registry$dimensions,use.names=FALSE)
  measures <- unlist(registry$value_keys_by_row_kind$counts,use.names=FALSE)
  fields <- stats::setNames(lapply(dimensions,.pg_count_field_sql),dimensions)
  part <- function(name) vapply(fields,function(x)x[[name]],"")
  bracket <- function(terms) paste(paste0("(",terms,")"),collapse=" AND ")
  sort <- paste0(paste(paste0("(",part("sort"),")"),collapse="||'|'||"),"||'|E:counts'")
  dims <- .pg_count_object_sql(part("wire"))
  # SQL numeric text can carry a scale. Match .baseline_normalize while
  # the input charge retains the unmodified serialized database row.
  measureSql <- function(k) {
    value <- paste0("(v->>'",k,"')")
    trimmed <- paste0("CASE WHEN strpos(",value,",'.')>0 THEN rtrim(rtrim(",value,", '0'),'.') ELSE ",value," END")
    paste0("CASE WHEN ",trimmed,"='-0' THEN '0' ELSE ",trimmed," END AS ",k)
  }
  normalized <- paste(vapply(measures,measureSql,""),collapse=",")
  encoded <- stats::setNames(paste0("to_jsonb(",measures,")::text"),measures)
  tests <- c(.pg_count_key_set("d",dimensions),part("valid"),.pg_count_key_set("v",measures))
  for (measure in measures) {
    tests <- c(tests,paste0("jsonb_typeof(v->'",measure,"')='string' AND ",measure," ~ '^(0|[1-9][0-9]*)$'"),
      paste0("state='computed' OR ",measure,"='0'"))
  }
  if (length(measures)==2L) tests <- c(tests,
    "length(person_count)<length(record_count) OR (length(person_count)=length(record_count) AND person_count COLLATE \"C\"<=record_count COLLATE \"C\")")
  if (shape=="period") tests <- c(tests,"
    (d->>'period_kind' IN ('undated','full_scope') AND d->>'period_start'='null' AND d->>'period_end'='null') OR
    (d->>'period_kind'<>'undated' AND d->>'period_start'<>'null' AND d->>'period_end'<>'null' AND
     (d->>'period_start') COLLATE \"C\"<=(d->>'period_end') COLLATE \"C\" AND
     (d->>'period_kind'<>'calendar_month' OR left(d->>'period_start',7)=left(d->>'period_end',7)) AND
     (d->>'period_kind'<>'calendar_year' OR left(d->>'period_start',4)=left(d->>'period_end',4)))")
  # The public checked source rejects suppressed/unavailable rows for these four shapes.
  tests <- c(tests,"kind='counts'",paste0("mid=", .store_literal(registry$id)),
    "(state='computed' AND reason IS NULL) OR (state IN ('empty_source','empty_population') AND reason ~ '^[a-z0-9_.:-]{1,96}$')")
  version <- .store_literal(.json(registry$version))
  paste0("WITH source_rows AS (SELECT x.metric_id AS mid,x.row_kind AS kind,x.dimensions AS d,",
    "x.values AS v,x.state,x.reason_code AS reason,octet_length(convert_to(to_jsonb(x)::text,'UTF8')) AS input_bytes FROM (",output$sql,") x),",
    "normalized AS (SELECT *,",normalized," FROM source_rows),typed AS (SELECT *,",dims," AS dims,",.pg_count_object_sql(encoded)," AS vals,",sort,
    " AS sort_key,(",bracket(tests),") IS TRUE AS valid FROM normalized),",
    "ids AS (SELECT *,encode(sha256(convert_to('{\"dimensions\":'||dims||',\"metric_id\":'||to_jsonb(mid)::text||",
    "',\"metric_version\":'||",version,"||',\"row_kind\":\"counts\"}'||chr(10),'UTF8')),'hex') AS key FROM typed)",
    " SELECT key,sort_key,input_bytes,CASE WHEN valid AND octet_length(sort_key)<=1024 THEN convert_to(",
    "'{\"denominator_refs\":[],\"dimensions\":'||dims||',\"reason_code\":'||COALESCE(to_jsonb(reason)::text,'null')||",
    "',\"row_key\":\"'||key||'\",\"row_kind\":\"counts\",\"state\":'||to_jsonb(state)::text||',\"values\":'||vals||'}'||chr(10),'UTF8') END AS raw FROM ids")
}

.pg_count_capture_plan <- function(program) {
  checked <- .sql_execution_program(program)
  assets <- .v2_assets()
  queries <- list()
  for (id in names(checked$outputs)) {
    registry <- assets$rows[[id]]
    shape <- .pg_count_shape(registry, assets$analysis$definitions$analyses[[id]])
    if (is.null(shape)) next
    output <- checked$outputs[[id]]
    .nv_need(identical(output$metric_id,id) && identical(output$kind,"aggregate") &&
      !length(output$parameters),"Unexpected count program output")
    queries[[id]] <- .pg_count_select_sql(output,registry,shape)
  }
  bounded <- function(metricId, remainingRows, remainingBytes, maxRowBytes) {
    number <- function(x,max,min=0) is.numeric(x) && !is.complex(x) && length(x)==1L &&
      is.finite(x) && x>=min && x<=max && x==floor(x)
    .nv_need(.string(metricId) && metricId %in% names(queries) &&
      number(remainingRows,.Machine$integer.max) && number(remainingBytes,2^53) &&
      number(maxRowBytes,1024^2,1),"Invalid count capture request")
    decimal <- function(x) format(x,scientific=FALSE,trim=TRUE,digits=22)
    # Keep the scalar transport's guard order. Negative charges are protocol
    # errors; only a positive original UTF-8 size can enter an accepted receipt.
    paste0("SELECT key,CASE WHEN charge>0 AND octet_length(raw)<=65536 THEN raw END AS raw,",
      "charge AS input_bytes FROM (SELECT bounded.*,CASE WHEN rn>",decimal(remainingRows),
      " THEN -1 WHEN input_bytes IS NULL OR input_bytes>",decimal(maxRowBytes),
      " THEN -3 WHEN consumed>",decimal(remainingBytes)," THEN -2 ELSE input_bytes END AS charge FROM (",
      "SELECT f.*,row_number() OVER (ROWS UNBOUNDED PRECEDING) AS rn,",
      "sum(input_bytes) OVER (ROWS UNBOUNDED PRECEDING) AS consumed FROM (",
      queries[[metricId]],") f LIMIT ",decimal(as.double(remainingRows)+1),") bounded) guarded")
  }
  list(metrics=names(queries),program_sha256=checked$program_sha256,query=bounded)
}
