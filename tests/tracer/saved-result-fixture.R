# Independent small reduced-scope result fixture; no CDM or store connection.
makeSavedResultFixture <- function(directory,pageRows=2L,fault=NULL,extraConceptIds=character(),saveConcepts=TRUE,savedLabels=NULL,saveCalendar=FALSE) {
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');a<-f('.v2_assets')();wire<-f('.v2_bytes');hash<-f('.v2_hash')
  stopifnot(dir.create(directory,mode='0700'));dir.create(file.path(directory,'objects'))
  context<-o(contract_version='2.0.0',publication_id='00000000-0000-4000-8000-000000000031',release_id='00000000-0000-4000-8000-000000000032',source_id='fixture:semantic',profile_id='core-characterization-v2',profile_revision='2.0.0',profile_sha256=a$hash,access_scope_id='fixture-semantic')
  if(!is.null(savedLabels))context$contract_version<-'2.1.0'
  rows<-list()
  row<-function(mid,dims,values,kind='counts',state='computed',reason=NULL,refs=list()) {
    r<-o(row_key='',dimensions=dims,row_kind=kind,state=state,reason_code=reason,values=values,denominator_refs=refs)
    r$row_key<-f('.v2_row_identity')(a$rows[[mid]],r);rows[[mid]]<<-c(rows[[mid]],list(r));r
  }
  ref<-function(mid,r,field,source=field)o(measure=source,metric_id=mid,row_key=r$row_key,field=field,value=r$values[[field]])
  person<-row('core.person.count',o(),o(person_count='10'))
  for(pair in list(c('0','6'),c('9007199254740993','4')))row('core.person.gender_count',o(gender_concept_id=pair[[1]]),o(person_count=pair[[2]]),refs=list(ref('core.person.count',person,'person_count')))
  for(id in extraConceptIds)row('core.person.gender_count',o(gender_concept_id=id),o(person_count='0'),refs=list(ref('core.person.count',person,'person_count')))
  capture<-row('core.condition.capture_count',o(concept_tag=o(kind='id',value='123'),period_kind='full_scope',period_start='null',period_end='null'),o(record_count='4',person_count='3'),refs=list(ref('core.person.count',person,'person_count')))
  row('core.condition.capture_count',o(concept_tag=o(kind='all'),period_kind='full_scope',period_start='null',period_end='null'),o(record_count='4',person_count='3'),refs=list(ref('core.person.count',person,'person_count')))
  if(saveCalendar)for(period in list(c('calendar_month','2020-01-01','2020-01-31','2','2'),
                                    c('calendar_month','2020-02-01','2020-02-29','2','2'),
                                    c('calendar_year','2020-01-01','2020-12-31','4','3'))) {
    for(tag in list(o(kind='id',value='123'),o(kind='all')))
      row('core.condition.capture_count',o(concept_tag=tag,period_kind=period[[1]],period_start=period[[2]],period_end=period[[3]]),
        o(record_count=period[[4]],person_count=period[[5]]))
  }
  row('core.condition.observation_qualification_count',o(concept_tag=o(kind='id',value='123'),reason='inside_valid_union'),o(record_count='4',person_count='3'),refs=list(ref('core.condition.capture_count',capture,'record_count'),ref('core.condition.capture_count',capture,'person_count')))
  for(unit in c('456','777','9007199254740993')) {
    dims<-o(concept_tag=o(kind='id',value='123'),unit_concept_tag=o(kind='id',value=unit),raw_operator_tag=o(kind='null'))
    empty<-unit=='777'
    values<-if(empty)o(n='0',sum=NULL,min=NULL,max=NULL,mean_numerator=NULL,mean_denominator=NULL,p10=NULL,p25=NULL,p50=NULL,p75=NULL,p90=NULL) else
      o(n='6',sum='20.5',min='1',max='10',mean_numerator='20.5',mean_denominator='6',p10='1',p25='2',p50='2.5',p75='2.5',p90='10')
    row('core.measurement.numeric_summary',dims,values,'summary',if(empty)'empty_population' else 'computed',if(empty)'fixture.no_eligible' else NULL)
    row('core.measurement.numeric_summary',c(dims,o(eligibility_reason='eligible')),o(record_count=if(empty)'0' else '6'),'eligibility_counts',if(empty)'empty_population' else 'computed',if(empty)'fixture.no_eligible' else NULL)
  }
  row('core.visit.care_setting_count',o(concept_tag=o(kind='id',value='1'),setting_kind='place_of_service',setting_concept_tag=o(kind='schema_absent')),NULL,state='unavailable',reason='capability.care_site_absent')
  row('core.specimen.capture_count',o(concept_tag=o(kind='all'),period_kind='full_scope',period_start='null',period_end='null'),o(record_count='0',person_count='0'),state='empty_source',reason='fixture.empty_source',refs=list(ref('core.person.count',person,'person_count')))
  retained<-names(rows)
  # Faults are applied before hashing to exercise semantics, not checksum failure.
  if(identical(fault,'wrong_reference'))rows[['core.person.gender_count']][[1]]$denominator_refs[[1]]$row_key<-strrep('f',64)
  if(identical(fault,'wrong_value'))rows[['core.person.gender_count']][[1]]$denominator_refs[[1]]$value<-'11'
  if(identical(fault,'missing_eligibility'))rows[['core.measurement.numeric_summary']]<-Filter(function(r)!(r$row_kind=='eligibility_counts' && r$dimensions$unit_concept_tag$value=='456'),rows[['core.measurement.numeric_summary']])
  if(identical(fault,'wrong_eligibility'))for(i in seq_along(rows[['core.measurement.numeric_summary']]))if(rows[['core.measurement.numeric_summary']][[i]]$row_kind=='eligibility_counts' && rows[['core.measurement.numeric_summary']][[i]]$dimensions$unit_concept_tag$value=='456')rows[['core.measurement.numeric_summary']][[i]]$values$record_count<-'7'
  emit<-function(doc,kind,count) {
    if(identical(fault,'mixed_version')&&kind=='terminology')doc$contract_version<-'2.0.0'
    raw<-wire(doc);d<-f('.v2_descriptor')(raw,kind,count);writeBin(raw,file.path(directory,'objects',paste0(d$sha256,'.json')));d
  }
  tree<-function(kind,items,keys,mid=NULL) {
    build<-f('.v2_tree')(kind,context,emit)
    if(length(items)) {
      order<-order(keys,method='radix');items<-items[order];keys<-keys[order]
      for(start in seq.int(1L,length(items),by=pageRows)) {
        index<-seq.int(start,min(start+pageRows-1L,length(items)))
        doc<-c(context,o(kind=kind),if(kind=='data')o(metric_id=mid,metric_version=a$metrics[[mid]]$version,rows=items[index]) else o(entries=items[index]))
        d<-emit(doc,kind,as.character(length(index)));build$add(d,keys[index[1]],keys[index[length(index)]])
      }
    }
    build$finish()
  }
  data<-f('.v2_tree')('data',context,emit);datasets<-list()
  for(mid in sort(names(a$metrics),method='radix')) {
    m<-a$metrics[[mid]];rs<-rows[[mid]];count<-length(rs)
    datasets[[length(datasets)+1L]]<-o(metric_id=mid,version=m$version,population=m$population,grain=m$grain,row_schema_id=a$rows[[mid]]$row_schema_id,definition_sha256=hash(wire(m)),state=if(count)if(mid=='core.specimen.capture_count')'empty_source' else 'computed' else 'suppressed',reason_code=if(count)if(mid=='core.specimen.capture_count')'fixture.empty_source' else NULL else 'policy.output_omitted',required=TRUE,conditional_support=o(state='supported',reason_code=NULL),rows=as.character(count),completeness=o(scope_kind='standard_full',complete=TRUE,excluded_record_count='0',reason_code=NULL))
    if(count) {
      keys<-vapply(rs,function(r)paste0(mid,'|',f('.v2_sort')(a$rows[[mid]],r)),'')
      d<-tree('data',rs,keys,mid);keys<-sort(keys,method='radix');data$add(d,keys[1],keys[length(keys)])
    }
  }
  catalogue<-tree('metric_catalogue',datasets,vapply(datasets,function(d)d$metric_id,''))
  # Mirror the producer's retained typed-ID inventory, never synthetic names.
  conceptIds<-character()
  if(saveConcepts)for(rs in rows)for(r in rs)for(n in names(r$dimensions)) {
    v<-r$dimensions[[n]]
    if(grepl('_tag$',n)&&is.list(v)&&identical(v$kind,'id'))conceptIds<-c(conceptIds,v$value)
    if(grepl('_concept_id$',n)&&is.character(v)&&v!='null')conceptIds<-c(conceptIds,v)
  }
  entries<-lapply(unique(conceptIds),function(id)o(concept_tag=o(kind='id',value=id),label=NULL,label_state='unavailable'))
  metadata<-NULL
  if(!is.null(savedLabels)) {
    entries<-lapply(unique(conceptIds),function(id) {
      label<-savedLabels[[id]]
      o(concept_tag=o(kind='id',value=id),label=label,label_state=if(is.null(label))'unavailable' else 'available',
        label_reason_code=if(is.null(label))'terminology.id_not_in_snapshot' else NULL,domain_id=if(is.null(label))NULL else 'Synthetic',vocabulary_id=if(is.null(label))NULL else 'Fixture')
    })
    unknown<-o(state='unknown',value=NULL,basis=NULL,assertion_id=NULL,reason_code='fixture.unknown')
    metadata<-o(extension_version='1.0.0',matching='ascii-fold-prefix-v1',label_source=unknown,vocabulary_release=unknown,
      snapshot_sha256=hash(wire(savedLabels)),capture=o(captured_at='2026-01-01T00:00:00.000Z',within_capture='single_repeatable_read',with_aggregate_release='not_asserted'))
    if(identical(fault,'extra_concept'))entries<-c(entries,list(o(concept_tag=o(kind='id',value='999999'),label='Hidden name',label_state='available',label_reason_code=NULL,domain_id=NULL,vocabulary_id=NULL)))
    if(identical(fault,'missing_concept'))entries<-Filter(function(e)e$concept_tag$value!='123',entries)
  }
  if(identical(fault,'unversioned_label')){entries[[1]]$label<-'Unapproved name';entries[[1]]$label_state<-'available'}
  if(identical(fault,'non_id_concept'))entries[[1]]$concept_tag<-o(kind='all')
  conceptKeys<-vapply(entries,function(e)f('.v2_component')(e$concept_tag,'concept_tag'),'')
  concepts<-tree('concept_catalogue',entries,conceptKeys)
  termEntries<-if(is.null(savedLabels))lapply(entries,function(e)c(e,o(domain_id=NULL))) else Filter(function(e)e$label_state=='available',entries)
  if(identical(fault,'missing_name_index'))termEntries<-termEntries[-1L]
  if(identical(fault,'wrong_name_label'))termEntries[[1]]$label<-'Wrong name'
  termKeys<-if(is.null(savedLabels))conceptKeys else vapply(termEntries,f('.term_name_key'),'')
  terms<-tree('terminology',termEntries,termKeys)
  policy<-o(id='fixture-semantic',revision='1',scope_kind='restricted',allow_metrics=as.list(retained))
  root<-c(context,o(kind='root',scope_kind='restricted',publication_state='ready',eligible_for_current_pointer=TRUE,expected_metric_count='142',generated_at='2026-01-01T00:00:00.000Z',source_schema=o(sha256=strrep('a',64),declared_cdm_version='5.5'),source_consistency=o(within_run='unknown',reusable=FALSE,reason_code='fixture.synthetic'),disclosure=o(approval_id='fixture-review',policy=policy,policy_sha256=hash(wire(policy))),catalogue=catalogue,concepts=concepts,data=data$finish(),terminology=terms),if(!is.null(metadata))o(saved_terminology=metadata))
  descriptor<-emit(root,'root','0')
  writeBin(wire(o(contract_version=context$contract_version,publication_id=context$publication_id,source_id=context$source_id,access_scope_id=context$access_scope_id,root=descriptor)),file.path(directory,'publication.json'))
  list(directory=normalizePath(directory),context=c(context,o(root=descriptor,authorization_epoch='1',instance_id='semantic-fixture')),rows=rows)
}
