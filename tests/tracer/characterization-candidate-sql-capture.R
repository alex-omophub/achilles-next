# Pure capture integrity/ownership tests; no database or fabricated candidate.
testCharacterizationCandidateCapture<-function(program) {
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');wire<-f('.json');assets<-f('.v2_assets')()
  order<-f('.candidate_order')(assets);ids<-names(assets$metrics)
  stopifnot(length(order)==142L,setequal(order,ids),!anyDuplicated(order))
  edges<-0L
  for(mid in ids) {
    target<-f('.analysis_dependency')(mid,assets)
    if(!is.null(target)){stopifnot(match(target,order)<match(mid,order));edges<-edges+1L}
  }
  stopifnot(edges==62L,match('core.person.gender_count',ids)<match('core.person.count',ids),
    match('core.person.count',order)<match('core.person.gender_count',order))
  huge<-'9007199254740993'
  person<-o(metric_id='core.person.count',row_kind='counts',dimensions=o(),values=o(person_count=huge),state='computed',reason_code=NULL)
  gender<-o(metric_id='core.person.gender_count',row_kind='counts',dimensions=o(gender_concept_id='0'),values=o(person_count=huge),state='computed',reason_code=NULL)
  # Literal expectations cover every denominator binding family, rather than
  # deriving expected dimensions from the same installed binding rules.
  checkDenominator<-function(mid,dimensions,targetId,targetDimensions) {
    values<-stats::setNames(lapply(unlist(assets$rows[[mid]]$value_keys_by_row_kind$counts),function(key)'1'),
      unlist(assets$rows[[mid]]$value_keys_by_row_kind$counts))
    row<-o(row_key='',dimensions=dimensions,row_kind='counts',state='computed',reason_code=NULL,values=values,denominator_refs=list())
    row$row_key<-f('.v2_row_identity')(assets$rows[[mid]],row)
    spec<-f('.analysis_denominator')(mid,row,forKey=TRUE)
    stopifnot(identical(spec$metric_id,targetId),identical(wire(spec$dimensions),wire(targetDimensions)))
    target<-o(metric_id=targetId,row_key=f('.v2_row_identity')(assets$rows[[targetId]],o(row_kind='counts',dimensions=targetDimensions)),
      dimensions=targetDimensions,values=o(person_count=huge,record_count=huge))
    refs<-f('.domain_denominators')(mid,row,target)
    stopifnot(length(refs)>0L,all(vapply(refs,function(ref)ref$value==huge&&ref$metric_id==targetId,TRUE)))
    for(field in c('metric_id','row_key','dimensions')) {
      bad<-target;bad[[field]]<-switch(field,metric_id='unknown.metric',row_key=strrep('0',64),dimensions=o(unexpected='1'))
      stopifnot(inherits(try(f('.domain_denominators')(mid,row,bad),silent=TRUE),'try-error'))
    }
    invisible(row)
  }
  concept<-o(kind='id',value='9007199254740993')
  checkDenominator('core.person.gender_count',o(gender_concept_id='0'),'core.person.count',o())
  full<-o(concept_tag=concept,period_kind='full_scope',period_start='null',period_end='null')
  checkDenominator('core.condition.capture_count',full,'core.person.count',o())
  period<-o(period_kind='calendar_month',period_start='2020-01-01',period_end='2020-01-31')
  conditional<-o(row_kind='counts',state='computed',dimensions=c(o(concept_tag=concept),period),values=o(record_count='1',person_count='1'))
  stopifnot(is.null(f('.analysis_denominator')('core.condition.capture_count',conditional,forKey=TRUE)))
  checkDenominator('observed.condition.capture_count',c(o(concept_tag=concept),period),'core.observation_period.coverage_count',period)
  year<-o(year='2020',gender_concept_id='0',year_age_decile='unknown')
  checkDenominator('observed.condition.year_gender_age_count',c(o(concept_tag=concept),year),'core.observation_period.year_gender_age_count',year)
  checkDenominator('core.condition.observation_qualification_count',o(concept_tag=concept,reason='outside_observation'),
    'core.condition.capture_count',full)
  for(state in c('unsupported','unavailable')) {
    conditional$state<-state;conditional$values<-NULL
    stopifnot(length(f('.domain_denominators')('observed.condition.capture_count',conditional,NULL))==0L)
  }
  root<-tempfile('candidate-capture-proof-');stopifnot(dir.create(root,mode='0700'))
  on.exit(unlink(root,recursive=TRUE),add=TRUE)
  connections<-nrow(showConnections(all=TRUE))
  fresh<-function(bytes=16*1024^2,files=256L,tick=function()NULL) {
    budget<-f('.v2_scratch_budget')(bytes,files)
    capture<-f('.candidate_capture')(tempfile('attempt-',tmpdir=root),assets,budget,tick)
    list(capture=capture,budget=budget)
  }
  rejects<-function(work)stopifnot(inherits(tryCatch({work();NULL},error=identity),'error'))
  receipt<-function() {
    inv<-stats::setNames(lapply(ids,function(mid)o(rows=if(mid%in%c('core.person.count','core.person.gender_count'))'1' else '0')),ids)
    audit<-o(population=o(person_count=huge,nonnull=huge,distinct=huge,raw_observation_count='0',merged_interval_count='0'),
      domains=stats::setNames(lapply(f('.domain_names')(TRUE),function(d)o(raw='0',linked='0',observed='0',start=NULL,end=NULL)),f('.domain_names')(TRUE)))
    o(state='succeeded',program_sha256=program$program_sha256,profile=program$batch$profile,source=program$batch$source,
      cleanup=o(transaction='rolled_back',connection='disconnected'),publication_changed=FALSE,canonical_wire=FALSE,
      inventory=inv,metric_rows=lapply(inv,function(x)x$rows),rows='2',audit_totals=audit)
  }
  run<-fresh();cap<-run$capture
  # Source order deliberately precedes its target. Capture is disk-backed;
  # topological replay binds exact large counts without a floating conversion.
  cap$visit(gender$metric_id,gender);cap$visit(person$metric_id,person)
  cap$complete(receipt(),program);cap$verify()
  target<-NULL;cap$replay('core.person.count',function(row)target<<-row)
  row<-NULL;cap$replay('core.person.gender_count',function(value)row<<-value)
  stored<-cap$lookup('core.person.count',target$row_key)
  refs<-f('.domain_denominators')('core.person.gender_count',row,stored)
  stopifnot(length(refs)==1L,refs[[1]]$value==huge,stored$values$person_count==huge)
  stopifnot(identical(wire(stored),wire(c(o(metric_id=person$metric_id),target))))
  rejects(function()cap$lookup('core.condition.capture_count',target$row_key))
  rejects(function()cap$lookup('core.person.count',strrep('0',64)))
  rejects(function()cap$complete(receipt(),program))
  cap$cleanup();cap$cleanup();stopifnot(run$budget$inspect()$bytes==0,run$budget$inspect()$files==0)
  # Cross two frame batches, including a partial final batch and real zeros.
  run<-fresh();cap<-run$capture
  genders<-gender
  for(i in seq_len(259L)) {
    genders$dimensions$gender_concept_id<-as.character(i)
    genders$values$person_count<-'0'
    cap$visit(genders$metric_id,genders)
  }
  cap$visit(person$metric_id,person)
  many<-receipt();many$inventory[[gender$metric_id]]$rows<-'259'
  many$metric_rows[[gender$metric_id]]<-'259';many$rows<-'260'
  cap$complete(many,program);seen<-0L
  cap$replay(gender$metric_id,function(value) {
    seen<<-seen+1L
    stopifnot(value$dimensions$gender_concept_id==as.character(seen),value$values$person_count=='0')
  })
  stopifnot(seen==259L);cap$cleanup()
  # Every fault owns only its attempt directory and releases its budget.
  run<-fresh();cap<-run$capture;cap$visit(person$metric_id,person)
  rejects(function()cap$visit(person$metric_id,person));cap$cleanup()
  run<-fresh();cap<-run$capture
  rejects(function()cap$replay('core.person.count',identity));rejects(function()cap$verify());cap$cleanup()
  run<-fresh();cap<-run$capture;cap$visit(person$metric_id,person)
  rejects(function()cap$complete(receipt(),program));cap$cleanup()
  for(fault in c('control','frame')) {
    run<-fresh();cap<-run$capture;cap$visit(person$metric_id,person);cap$visit(gender$metric_id,gender);cap$complete(receipt(),program)
    dir<-list.dirs(root,recursive=FALSE,full.names=TRUE);stopifnot(length(dir)==1L)
    path<-if(fault=='control')file.path(dir,'receipt.json') else file.path(dir,paste0(f('.hash')('core.person.count'),'.rows'))
    con<-file(path,'ab');writeBin(as.raw(0),con);close(con)
    if(fault=='control')rejects(function()cap$verify()) else rejects(function()cap$replay('core.person.count',identity))
    cap$cleanup();stopifnot(run$budget$inspect()$bytes==0,run$budget$inspect()$files==0)
  }
  rejects(function()fresh(bytes=0));rejects(function()fresh(files=0))
  cancelled<-FALSE;run<-fresh(tick=function(){if(cancelled)stop('private capture cancellation sentinel')});cap<-run$capture
  cancelled<-TRUE;rejects(function()cap$visit(person$metric_id,person));cancelled<-FALSE;cap$cleanup()
  stopifnot(length(list.files(root,all.files=TRUE,no..=TRUE))==0L,nrow(showConnections(all=TRUE))==connections)
  cat('CANDIDATE_CAPTURE_TOPOLOGY_62_EDGES_EXACT_TARGETS_INTEGRITY_BUDGETS_CLEANUP_OK\n')
}
