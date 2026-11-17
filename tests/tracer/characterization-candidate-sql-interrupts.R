# Self-SIGINT reaches ordinary R ownership boundaries without any database.
# Cooperative callbacks alone would miss interruption after a resource returns.
testCharacterizationCandidateInterrupts<-function(program,details) {
  if(.Platform$OS.type=='windows')return(invisible(NULL))
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object')
  root<-tempfile('candidate-interrupt-proof-');stopifnot(dir.create(root,mode='0700'))
  on.exit(unlink(root,recursive=TRUE),add=TRUE)
  signal<-function(){stopifnot(tools::pskill(Sys.getpid(),2L));invisible(NULL)}
  baseCapture<-f('.candidate_capture');baseSpool<-f('.v2_spool')
  originalConnections<-nrow(showConnections(all=TRUE))
  person<-o(metric_id='core.person.count',row_kind='counts',dimensions=o(),values=o(person_count='1'),state='computed',reason_code=NULL)
  for(seam in c('capture_return','spool_return','row_file_open','committed_return')) {
    execute<-generateCharacterizationCandidateFromSql;scope<-new.env(parent=environment(execute))
    scope$.candidate_store_transaction<-function(details,schema,work,limits,tick,ids,readOnly=FALSE,state=NULL,startedClock=NULL) {
      if(readOnly)return(list(value=NULL,telemetry=o()))
      stopifnot(seam=='committed_return',is.environment(state));state$outcome<-'committed'
      signal();Sys.sleep(0.1);stop('private_interrupt_not_delivered')
    }
    scope$executeCharacterizationSql<-function(connectionDetails,program,visit,...) {
      if(seam=='committed_return')return(list())
      visit(person$metric_id,person);stop('private_capture_interrupt_not_delivered')
    }
    if(seam=='capture_return')scope$.candidate_capture<-function(...) {value<-baseCapture(...);signal();value}
    if(seam=='spool_return') {
      capture<-baseCapture;spoolScope<-new.env(parent=environment(capture))
      spoolScope$.v2_spool<-function(...) {value<-baseSpool(...);signal();value}
      environment(capture)<-spoolScope;scope$.candidate_capture<-capture
    }
    if(seam=='row_file_open') {
      capture<-baseCapture;fileScope<-new.env(parent=environment(capture))
      fileScope$file<-function(description='',open='',...) {
        value<-base::file(description,open,...)
        if(identical(open,'ab'))signal()
        value
      }
      environment(capture)<-fileScope;scope$.candidate_capture<-capture
    }
    if(seam=='committed_return')scope$.candidate_capture<-function(...)list(visit=function(...)NULL,complete=function(...)NULL,cleanup=function()NULL)
    environment(execute)<-scope
    error<-tryCatch({execute(details,program,details,'results',scratchParent=root);NULL},error=identity,interrupt=identity)
    cat('CANDIDATE_SELF_SIGINT_SEAM ',seam,' ',error$reason_code,' ',error$outcome,'\n',sep='')
    stopifnot(inherits(error,'AchillesCandidateFailure'),error$reason_code=='candidate.cancelled',
      identical(error$outcome,if(seam=='committed_return')'committed' else 'not_committed'),
      !grepl('private_',conditionMessage(error),fixed=TRUE),is.null(error$call),is.null(error$parent),
      identical(error$publication_changed,FALSE),length(list.files(root,all.files=TRUE,no..=TRUE))==0L,
      nrow(showConnections(all=TRUE))==originalConnections)
    if(seam=='committed_return')for(key in c('attempt_id','run_id','source_release_id','release_id'))
      stopifnot(is.character(error[[key]]),grepl('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',error[[key]]))
  }
  cat('CANDIDATE_SELF_SIGINT_CONSTRUCTOR_FILE_OWNERSHIP_AND_COMMITTED_OUTCOME_OK\n')
}

# COMMIT/disconnect may consume the final client budget. The committed outcome
# must survive that late failure; a fresh source capture or rollback is unsafe.
testCharacterizationCandidateCompletionLimits<-function(program,details) {
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object')
  root<-tempfile('candidate-completion-proof-');stopifnot(dir.create(root,mode='0700'))
  on.exit(unlink(root,recursive=TRUE),add=TRUE)
  connections<-nrow(showConnections(all=TRUE))
  for(seam in c('deadline','cancel','slow_check')) {
    generate<-generateCharacterizationCandidateFromSql;scope<-new.env(parent=environment(generate))
    committed<-FALSE;stores<-0L;sources<-0L;captures<-0L;completed<-0L;cleaned<-FALSE;checkExpired<-FALSE
    scope$proc.time<-function()structure(c(user.self=0,sys.self=0,
      elapsed=if((committed&&seam=='deadline')||checkExpired)2 else 0,user.child=0,sys.child=0),class='proc_time')
    scope$.candidate_store_transaction<-function(details,schema,work,limits,tick,ids,readOnly=FALSE,state=NULL,startedClock=NULL) {
      stores<<-stores+1L
      if(readOnly)return(list(value=NULL,telemetry=o()))
      stopifnot(is.environment(state));state$outcome<-'committed';committed<<-TRUE
      list(value=list(persistence=o(),scratch=o()),telemetry=o())
    }
    scope$executeCharacterizationSql<-function(...) {sources<<-sources+1L;list()}
    scope$.candidate_capture<-function(...) {
      captures<<-captures+1L
      list(visit=function(...)NULL,complete=function(...)completed<<-completed+1L,cleanup=function()cleaned<<-TRUE)
    }
    environment(generate)<-scope
    error<-tryCatch({generate(details,program,details,'results',scratchParent=root,maxElapsedSeconds=1,
      check=function(){if(committed&&seam=='slow_check')checkExpired<<-TRUE;!(committed&&seam=='cancel')});NULL},error=identity,interrupt=identity)
    expected<-if(seam=='cancel')'candidate.cancelled' else 'candidate.elapsed_limit'
    stopifnot(inherits(error,'AchillesCandidateFailure'),identical(error$reason_code,expected),
      identical(error$outcome,'committed'),identical(error$publication_changed,FALSE),
      is.null(error$call),is.null(error$parent),committed,cleaned,stores==2L,sources==1L,captures==1L,completed==1L,
      length(list.files(root,all.files=TRUE,no..=TRUE))==0L,nrow(showConnections(all=TRUE))==connections)
    for(key in c('attempt_id','run_id','source_release_id','release_id'))
      stopifnot(is.character(error[[key]]),grepl('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',error[[key]]))
  }
  # A slow successful callback at the first boundary must also stop before
  # any endpoint, rather than consuming the remaining budget and starting SQL.
  generate<-generateCharacterizationCandidateFromSql;scope<-new.env(parent=environment(generate));expired<-FALSE;endpoints<-0L
  scope$proc.time<-function()structure(c(user.self=0,sys.self=0,elapsed=if(expired)2 else 0,user.child=0,sys.child=0),class='proc_time')
  scope$.candidate_store_transaction<-function(...) {endpoints<<-endpoints+1L;stop('private late readiness sentinel')}
  environment(generate)<-scope
  error<-tryCatch({generate(details,program,details,'results',scratchParent=root,maxElapsedSeconds=1,
    check=function(){expired<<-TRUE;TRUE});NULL},error=identity)
  stopifnot(inherits(error,'AchillesCandidateFailure'),error$reason_code=='candidate.elapsed_limit',
    error$outcome=='not_committed',endpoints==0L)
  cat('CANDIDATE_POST_COMMIT_DEADLINE_AND_CANCELLATION_RETAIN_IDS_NO_RETRY_OK\n')
}

# Initial compilation is also cancellable; no endpoint or attempt exists yet.
testCharacterizationCandidateValidationInterrupt<-function(program,details) {
  if(.Platform$OS.type=='windows')return(invisible(NULL))
  f<-function(n)get(n,asNamespace('AchillesNext'));generate<-generateCharacterizationCandidateFromSql
  scope<-new.env(parent=environment(generate));validate<-f('.sql_execution_program');stores<-0L;sources<-0L
  scope$.sql_execution_program<-function(value) {
    checked<-validate(value)
    stopifnot(tools::pskill(Sys.getpid(),2L));Sys.sleep(0.1);checked
  }
  scope$.candidate_store_transaction<-function(...) {stores<<-stores+1L;stop('private premature store sentinel')}
  scope$executeCharacterizationSql<-function(...) {sources<<-sources+1L;stop('private premature source sentinel')}
  environment(generate)<-scope
  error<-tryCatch({generate(details,program,details,'results');NULL},error=identity,interrupt=identity)
  stopifnot(inherits(error,'AchillesCandidateFailure'),error$reason_code=='candidate.cancelled',
    error$outcome=='not_committed',stores==0L,sources==0L,is.null(error$call),is.null(error$parent),
    all(vapply(c('attempt_id','run_id','source_release_id','release_id'),function(key)is.null(error[[key]]),TRUE)))
  cat('CANDIDATE_INITIAL_VALIDATION_SELF_SIGINT_CANCELLED_ZERO_ENDPOINTS_OK\n')
}

# The original call clock reaches both store phases, including time spent in
# readiness and source capture. Phase telemetry may use its own local clock.
testCharacterizationCandidateGlobalClock<-function(program,details) {
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object')
  generate<-generateCharacterizationCandidateFromSql;scope<-new.env(parent=environment(generate))
  now<-0;starts<-numeric();phases<-logical();sourceCalls<-0L
  scope$proc.time<-function()structure(c(user.self=0,sys.self=0,elapsed=now,user.child=0,sys.child=0),class='proc_time')
  scope$.candidate_store_transaction<-function(details,schema,work,limits,tick,ids,readOnly=FALSE,state=NULL,startedClock=NULL) {
    starts<<-c(starts,startedClock);phases<<-c(phases,readOnly)
    stopifnot(identical(startedClock,0),limits$max_elapsed_seconds==10)
    if(readOnly){now<<-4;return(list(value=NULL,telemetry=o()))}
    state$outcome<-'committed';list(value=list(persistence=o(),scratch=o()),telemetry=o())
  }
  scope$executeCharacterizationSql<-function(...) {sourceCalls<<-sourceCalls+1L;now<<-7.4;list()}
  scope$.candidate_capture<-function(...)list(visit=function(...)NULL,complete=function(...)NULL,cleanup=function()NULL)
  environment(generate)<-scope
  result<-generate(details,program,details,'results',maxElapsedSeconds=10)
  stopifnot(result$state=='building',identical(starts,c(0,0)),identical(phases,c(TRUE,FALSE)),sourceCalls==1L)
  cat('CANDIDATE_BOTH_STORE_PHASES_RECEIVE_ORIGINAL_CLIENT_CLOCK_OK\n')
}

# Actual store write and read transports run against a fake JDBC connection.
# Captured JDBC timeouts expose the remaining whole-call budget, not a new
# timeout allowance at the beginning of each store phase.
testCharacterizationCandidateStoreTimeouts<-function(details) {
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object')
  if(!methods::isClass('AchillesCandidateClockConnection'))
    methods::setClass('AchillesCandidateClockConnection',slots=c(jConnection='environment'))
  previous<-list(connect=get('connect',asNamespace('DatabaseConnector')),
    disconnect=get('disconnect',asNamespace('DatabaseConnector')),jcall=get('.jcall',asNamespace('rJava')))
  on.exit({assignInNamespace('connect',previous$connect,ns='DatabaseConnector')
    assignInNamespace('disconnect',previous$disconnect,ns='DatabaseConnector')
    assignInNamespace('.jcall',previous$jcall,ns='rJava')},add=TRUE)
  trials<-list(list(now=7.4,statement=30000,expected=3L),list(now=7.4,statement=1500,expected=2L),
    list(now=9.9,statement=30000,expected=1L),list(now=7.4,acquisition=9.1,statement=30000,expected=1L),
    list(now=7.4,acquisition=10.1,statement=30000,expired=TRUE))
  for(readOnly in c(TRUE,FALSE))for(trial in trials) {
    now<-trial$now;timeouts<-list();writes<-0L;queries<-0L;rollbacks<-0L;disconnects<-0L;commits<-0L;transportStart<-NULL
    jdbc<-new.env(parent=emptyenv());connection<-methods::new('AchillesCandidateClockConnection',jConnection=jdbc)
    assignInNamespace('connect',function(...)connection,ns='DatabaseConnector')
    assignInNamespace('disconnect',function(...) {disconnects<<-disconnects+1L;invisible(NULL)},ns='DatabaseConnector')
    assignInNamespace('.jcall',function(obj,returnSig='V',method,...) {
      args<-list(...)
      if(method%in%c('createStatement','prepareStatement')) {
        if(!is.null(trial$acquisition))now<<-trial$acquisition
        statement<-new.env(parent=emptyenv());statement$kind<-if(method=='createStatement')'write' else 'read';return(statement)
      }
      if(method=='setQueryTimeout'){timeouts[[length(timeouts)+1L]]<<-list(kind=obj$kind,seconds=args[[1]]);return(invisible(NULL))}
      if(method=='execute'){writes<<-writes+1L;return(TRUE)}
      if(method=='executeQuery'){queries<<-queries+1L;rs<-new.env(parent=emptyenv());rs$position<-0L;return(rs)}
      if(method=='getMetaData')return(new.env(parent=emptyenv()))
      if(method=='getColumnCount')return(2L)
      if(method=='next'){obj$position<-obj$position+1L;return(obj$position==1L)}
      if(method=='getString')return(if(args[[1]]==2L)'ok' else 'one')
      if(method=='rollback')rollbacks<<-rollbacks+1L
      if(method=='commit')commits<<-commits+1L
      if(method%in%c('setAutoCommit','setReadOnly','setTransactionIsolation','setFetchSize','setString','rollback','commit','cancel','close'))return(invisible(NULL))
      stop('private unexpected JDBC clock sentinel')
    },ns='rJava')
    clock<-function()structure(c(user.self=0,sys.self=0,elapsed=now,user.child=0,sys.child=0),class='proc_time')
    execute<-f('.candidate_store_transaction');scope<-new.env(parent=environment(execute));scope$proc.time<-clock
    originalTransport<-f('.sql_execution_transport')
    scope$.sql_execution_transport<-function(jdbc,limits,tick,startedClock) {
      transportStart<<-startedClock;transport<-originalTransport;transportScope<-new.env(parent=environment(transport))
      transportScope$proc.time<-clock;environment(transport)<-transportScope;transport(jdbc,limits,tick,startedClock)
    }
    environment(execute)<-scope
    limits<-f('.sql_execution_limits')(64*1024^2,1000000L,256*1024^2,131072L,128L,trial$statement,10,function(...)NULL,NULL)
    ids<-o(attempt_id='00000000-0000-4000-8000-000000000001',run_id='00000000-0000-4000-8000-000000000002',
      source_release_id='00000000-0000-4000-8000-000000000003',release_id='00000000-0000-4000-8000-000000000004')
    tick<-function()f('.candidate_need')(now<=10,'candidate.elapsed_limit')
    result<-tryCatch(execute(details,'results',function(tx) {
      stopifnot(tx$one("SELECT 'one'")=='one');tx$execute('INSERT fixed_test_payload');'complete'
    },limits,tick,ids,readOnly=readOnly,startedClock=0),error=identity)
    stopifnot(identical(transportStart,0),disconnects==1L)
    if(isTRUE(trial$expired))stopifnot(inherits(result,'AchillesCandidateFailure'),result$reason_code=='candidate.elapsed_limit',
      result$outcome=='not_committed',length(timeouts)==0L,writes==0L,queries==0L,rollbacks==1L,commits==0L) else {
      stopifnot(!inherits(result,'condition'),result$value=='complete',queries==1L,writes==6L,
        setequal(vapply(timeouts,function(x)x$kind,''),c('read','write')),
        all(vapply(timeouts,function(x)identical(x$seconds,trial$expected),TRUE)),
        commits==if(readOnly)0L else 1L,rollbacks==if(readOnly)1L else 0L)
    }
  }
  cat('CANDIDATE_STORE_READ_WRITE_TIMEOUTS_SHARE_GLOBAL_BUDGET_AND_ACQUISITION_TICK_OK\n')
}

# Preserve cancellation/deadline meaning across the source port, while an
# ordinary query error remains a source failure. None may enter persistence.
testCharacterizationCandidateSourceConditions<-function(program,details) {
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object')
  root<-tempfile('candidate-source-condition-');stopifnot(dir.create(root,mode='0700'))
  on.exit(unlink(root,recursive=TRUE),add=TRUE)
  expected<-c(execution.cancelled='candidate.cancelled',execution.elapsed_limit='candidate.elapsed_limit',execution.query_failed='candidate.source_failed')
  for(cause in names(expected)) {
    generate<-generateCharacterizationCandidateFromSql;scope<-new.env(parent=environment(generate))
    stores<-0L;sources<-0L;captures<-0L;cleaned<-FALSE
    scope$.candidate_store_transaction<-function(details,schema,work,limits,tick,ids,readOnly=FALSE,...) {
      stores<<-stores+1L;stopifnot(readOnly);list(value=NULL,telemetry=o())
    }
    scope$.candidate_capture<-function(...) {
      captures<<-captures+1L;list(visit=function(...)NULL,cleanup=function()cleaned<<-TRUE)
    }
    scope$executeCharacterizationSql<-function(...) {
      sources<<-sources+1L
      stop(structure(list(message='private source condition sentinel',call=NULL,reason_code=cause),
        class=c('AchillesSqlExecutionFailure','error','condition')))
    }
    environment(generate)<-scope
    error<-tryCatch({generate(details,program,details,'results',scratchParent=root);NULL},error=identity)
    stopifnot(inherits(error,'AchillesCandidateFailure'),identical(error$reason_code,unname(expected[[cause]])),
      identical(error$cause_code,cause),error$outcome=='not_committed',identical(error$publication_changed,FALSE),
      stores==1L,sources==1L,captures==1L,cleaned,is.null(error$call),is.null(error$parent),
      !grepl('private source condition sentinel',conditionMessage(error),fixed=TRUE),
      length(list.files(root,all.files=TRUE,no..=TRUE))==0L)
  }
  cat('CANDIDATE_SOURCE_CANCEL_AND_DEADLINE_CAUSES_PRESERVED_WITHOUT_IMPORT_OR_RETRY_OK\n')
}

# The real source executor deliberately classifies a thrown check as cancelled.
# Preserve the bridge's elapsed reason without invoking the user check again.
testCharacterizationCandidateSourceWrappedCheck<-function(program,details) {
  f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object')
  sourceExecute<-executeCharacterizationSql
  previous<-get('connect',asNamespace('DatabaseConnector'));connections<-0L
  on.exit(assignInNamespace('connect',previous,ns='DatabaseConnector'),add=TRUE)
  assignInNamespace('connect',function(...){connections<<-connections+1L;stop('private unexpected source connection')},ns='DatabaseConnector')
  root<-tempfile('candidate-wrapped-check-');stopifnot(dir.create(root,mode='0700'))
  on.exit(unlink(root,recursive=TRUE),add=TRUE)
  for(seam in c('deadline','cancel')) {
    now<-0;inSource<-FALSE;stores<-0L;sources<-0L;checks<-0L;captures<-0L;cleaned<-FALSE
    clock<-function(value)structure(c(user.self=0,sys.self=0,elapsed=value,user.child=0,sys.child=0),class='proc_time')
    generate<-generateCharacterizationCandidateFromSql;scope<-new.env(parent=environment(generate))
    scope$proc.time<-function()clock(now)
    scope$.candidate_store_transaction<-function(...,readOnly=FALSE) {
      stores<<-stores+1L;stopifnot(stores==1L);list(value=NULL,telemetry=o())
    }
    scope$.candidate_capture<-function(...) {
      captures<<-captures+1L;list(visit=function(...)stop('private unexpected visit'),cleanup=function()cleaned<<-TRUE)
    }
    scope$executeCharacterizationSql<-function(...) {
      sources<<-sources+1L;inSource<<-TRUE;on.exit(inSource<<-FALSE)
      actual<-sourceExecute;sourceScope<-new.env(parent=environment(actual))
      # Keep the executor's own clock within its budget; only the bridge check
      # observes the outer deadline. The installed source function body is real.
      sourceScope$proc.time<-function()clock(0);environment(actual)<-sourceScope
      stopifnot(identical(body(actual),body(sourceExecute)))
      actual(...)
    }
    environment(generate)<-scope
    error<-tryCatch({generate(details,program,details,'results',scratchParent=root,maxElapsedSeconds=1,
      check=function(){checks<<-checks+1L;if(inSource&&seam=='deadline')now<<-2;!(inSource&&seam=='cancel')});NULL},error=identity)
    expected<-if(seam=='deadline')'candidate.elapsed_limit' else 'candidate.cancelled'
    if(!identical(error$reason_code,expected))stop(paste('Expected wrapped source reason',expected,'received',error$reason_code),call.=FALSE)
    stopifnot(inherits(error,'AchillesCandidateFailure'),identical(error$reason_code,expected),
      identical(error$cause_code,'execution.cancelled'),error$outcome=='not_committed',
      stores==1L,sources==1L,captures==1L,checks==2L,cleaned,connections==0L,
      is.null(error$call),is.null(error$parent),identical(error$publication_changed,FALSE),
      length(list.files(root,all.files=TRUE,no..=TRUE))==0L)
    for(key in c('attempt_id','run_id','source_release_id','release_id'))
      stopifnot(is.character(error[[key]]),length(error[[key]])==1L,
        isTRUE(grepl('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',error[[key]])))
  }
  cat('CANDIDATE_REAL_SOURCE_WRAPPED_CHECK_DEADLINE_AND_TRUE_CANCEL_REASON_PRESERVED_OK\n')
}
