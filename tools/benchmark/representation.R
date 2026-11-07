# Contributor-only native validator and routing-fixture builder. No CDM access.
library(AchillesNext)
source('tools/benchmark/implementation_identity.R')
args<-commandArgs(TRUE);stopifnot(length(args)>=3L)
identity<-implementationIdentity(getwd())
f<-function(n)get(n,asNamespace('AchillesNext'));o<-f('.object');wire<-f('.v2_bytes')
if(args[1]=='validate') {
  stopifnot(length(args)==3L)
  time<-system.time(validateResultArtifact(args[2]))
  writeLines(f('.json')(o(status='passed',scope='complete_native_artifact_semantics',elapsed_seconds=unname(time['elapsed']),
    cpu_seconds=unname(time['user.self']+time['sys.self']),implementation=identity)),args[3])
} else {
  stopifnot(args[1]=='catalogue',length(args)==3L)
  count<-as.integer(args[3]);stopifnot(!is.na(count),count>=1L,count<=262144L)
  out<-normalizePath(args[2],mustWork=TRUE);stopifnot(dir.create(file.path(out,'objects')))
  context<-o(contract_version='2.0.0',publication_id='00000000-0000-4000-8000-000000000001',
    release_id='00000000-0000-4000-8000-000000000002',source_id='fixture:routing-only',
    profile_id='core-characterization-v2',profile_revision='2.0.0',profile_sha256=f('.v2_assets')()$hash,access_scope_id='fixture-routing')
  savePage<-function(raw,kind,rows) {
    d<-f('.v2_descriptor')(raw,kind,rows)
    stopifnot(length(raw)<=f('.v2_limit')(kind))
    writeBin(raw,file.path(out,'objects',paste0(d$sha256,'.json')));d
  }
  emit<-function(doc,kind,rows)savePage(wire(doc),kind,rows)
  tree<-f('.v2_tree')('concept_catalogue',context,emit)
  # Deterministic ASCII-only routing entries: vectorize fixture encoding, not
  # production serialization. The Python comparator independently checks exact
  # canonical JSON bytes. These are not approved analytical results.
  template<-rawToChar(wire(c(context,o(kind='concept_catalogue',entries='__fixture_entries__'))))
  for(start in seq.int(1L,count,by=512L)) {
    ids<-as.character(seq.int(start,min(start+511L,count)))
    entries<-sprintf('{"concept_tag":{"kind":"id","value":"%s"},"label":null,"label_state":"unavailable"}',ids)
    raw<-charToRaw(sub('"__fixture_entries__"',paste0('[',paste(entries,collapse=','),']'),template,fixed=TRUE))
    d<-savePage(raw,'concept_catalogue',as.character(length(ids)))
    tree$add(d,f('.v2_component')(o(kind='id',value=ids[1]),'concept_tag'),
      f('.v2_component')(o(kind='id',value=ids[length(ids)]),'concept_tag'))
  }
  descriptor<-tree$finish()
  writeLines(f('.json')(o(scope='routing_fixture_not_an_approved_publication',entries=as.character(count),
    context=context,trees=o(concept_catalogue=descriptor),implementation=identity)),file.path(out,'routing.json'))
}
