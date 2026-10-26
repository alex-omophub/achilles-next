#!/usr/bin/env python3
"""Author the v1 schemas and synthetic contract examples. Not an analysis engine."""
import hashlib
import itertools
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'inst/contracts/v1'
FIX = ROOT / 'tests/fixtures/contracts'
PROFILE = json.loads((ROOT/'inst/analysis/alpha-measurement-v1.json').read_text())
IDS = PROFILE['required_outputs']
URN = 'urn:achilles-next:contracts:1'
V = '1.0.0'

def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + '\n')

def sha(data): return hashlib.sha256(data).hexdigest()
def obj(properties): return dict(type='object',properties=properties,required=list(properties),additionalProperties=False)
def arr(items): return dict(type='array',items=items)
def ref(name): return {'$ref': f'{URN}#/$defs/{name}'}
def nullable(schema): return {'anyOf':[schema,{'type':'null'}]}
def const(value): return {'const':value}
S = {'type':'string','minLength':1}
BOOL = {'type':'boolean'}
COUNT = {'type':'string','pattern':'^(0|[1-9][0-9]*)$'}
DEC = {'type':'string','pattern':r'^-?(0|[1-9][0-9]*)(\.[0-9]+)?$'}
CID = {'type':'integer','minimum':0,'maximum':2147483647}
HASH = {'type':'string','pattern':'^[0-9a-f]{64}$'}
DATE = {'type':'string','format':'date'}
STAMP = {'type':'string','format':'date-time'}
TAG = {'type':'string','pattern':r'^(null|zero|id:-?[1-9][0-9]*)$'}
STATE = {'enum':['computed','empty_source','empty_population','unavailable','unsupported','inaccessible','not_requested','failed','suppressed','stale']}
identity = {'oneOf':[obj({'state':const('known'),'id':S,'reason':const(None)}),obj({'state':const('unknown'),'id':const(None),'reason':S})]}
snapshot = {'oneOf':[obj({'state':const('known'),'id':S,'reason':const(None),'basis':{'enum':['database_snapshot','institution_assertion','synthetic_fixture']},'assertion_id':S,'immutable':const(True)}),
                    obj({'state':const('unknown'),'id':const(None),'reason':S,'basis':const(None),'assertion_id':const(None),'immutable':const(False)})]}
source = obj({'source_id':S,'snapshot':ref('snapshot'),'data_release':ref('identity'),'vocabulary_release':ref('identity'),
              'schema_fingerprint':ref('identity'),'declared_cdm_version':nullable({'enum':['5.3','5.4','5.5']})})
context = obj({'source_id':S,'bundle_id':S,'manifest_sha256':HASH,'access_scope_id':S,'authorization_epoch':S})
denominator = obj({'metric_id':{'enum':IDS},'dimensions':{'type':'object'},'field':{'enum':['count','n']},'value':nullable(COUNT)})
period = {'measurement_concept_id':CID,'period_kind':{'enum':['window','month']},'period_start':DATE,'period_end':DATE}
dimension_schemas = {
 'month':DATE,'measurement_concept_id':CID,'period_kind':period['period_kind'],'period_start':DATE,'period_end':DATE,
 'numeric_present':BOOL,'coded_present':BOOL,'source_text_present':BOOL,'raw_unit_tag':TAG,'raw_operator_tag':TAG,
 'unit_concept_id':{'type':'integer','minimum':1,'maximum':2147483647},
 'eligibility_reason':{'enum':[r['reason'] for r in PROFILE['numeric_eligibility']]},
 'probe_id':{'enum':[p['id'] for p in PROFILE['prerequisite_probes']]},'metric_id':{'enum':IDS},
 'phase':{'enum':['compute','materialize','validate','export']}}
values = {
 'source.passport': obj({'source_id':S,'source_snapshot_id':nullable(S),'data_release_id':nullable(S),
   'declared_cdm_version':nullable(S),'observed_schema_evidence':ref('identity'),'vocabulary_release_id':nullable(S),
   'profile_id':const(PROFILE['profile_id']),'profile_revision':const(PROFILE['revision']),
   'metric_versions':obj({mid:const('1.0.0') for mid in IDS}),'run_id':S}),
 'source.capabilities':obj({'table_present':nullable(BOOL),'column_present':nullable(BOOL),'readable':nullable(BOOL),
   'required_for':arr({'enum':IDS}),'availability':{'enum':['available','absent','inaccessible','unknown']},'reason':nullable(S)}),
 'execution.output_status':obj({'state':STATE,'reason':nullable(S),'requested':BOOL,'metric_version':const('1.0.0'),'source_id':S}),
 'execution.timing':obj({'duration_ms':nullable(COUNT),'availability':{'enum':['measured','unavailable']},'reason':nullable(S)}),
 'measurement.numeric_summary':obj({field:(COUNT if field=='n' else nullable(COUNT) if field=='mean_denominator' else nullable(DEC))
                                   for field in next(m for m in PROFILE['metrics'] if m['id']=='measurement.numeric_summary')['fields']})}
result_branches=[]
for metric in PROFILE['metrics']:
    mid=metric['id']
    row=obj({'dimensions':obj({d:dimension_schemas[d] for d in metric['dimensions']}),
      'state':{'enum':['computed','empty_source','empty_population','suppressed']},'reason':nullable(S),
      'values':nullable(values.get(mid,obj({'count':COUNT}))),'denominator':nullable(ref('denominator'))})
    result_branches.append(obj({'contract_version':const(V),'bundle_id':S,'source_id':S,'run_id':S,'request_sha256':HASH,
      'metric_id':const(mid),'metric_version':const('1.0.0'),'state':STATE,'reason':nullable(S),'rows':nullable(arr(row))}))
partition=obj({'metric_id':{'enum':IDS},'metric_version':const('1.0.0'),'state':STATE,'reason':nullable(S),
  'path':{'type':'string','pattern':r'^results/[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*\.json$'},'sha256':HASH,'bytes':COUNT,'rows':COUNT})
request=obj({'profile_id':const(PROFILE['profile_id']),'source_id':S,'window':obj({'start':DATE,'end':DATE}),
  'measurement_concept_ids':dict(type='array',items=CID,minItems=1,maxItems=10,uniqueItems=True),
  'output_scope':const('restricted'),'disclosure_policy_id':S})
terminology=obj({'contract_version':const(V),'provider_id':S,'provider_version':S,'source_id':S,'vocabulary_release':ref('identity'),
 'concepts':arr(obj({'concept_id':CID,'state':{'enum':['available','unknown','unavailable']},'concept_name':nullable(S),
                   'domain_id':nullable(S),'reason':nullable(S)}))})
bundle=obj({'contract_version':const(V),'bundle_id':S,'run_id':S,'created_at':STAMP,
 'generator':obj({'name':S,'version':S}), 'profile':obj({'id':const(PROFILE['profile_id']),'revision':const(PROFILE['revision']),'sha256':HASH}),
 'source':ref('source'),'request':ref('request'),'request_sha256':HASH,
 'publication':{'enum':['complete','partial','failed']},'eligible_for_current_pointer':BOOL,
 'disclosure':obj({'policy_id':S,'applied':BOOL,'approval_id':nullable(S),'scope':const('restricted')}),
 'reproducibility':obj({'consistent_snapshot':BOOL,'execution_start':STAMP,'execution_end':STAMP,'limitation':nullable(S)}),
 'outputs':dict(type='array',items=ref('partition'),minItems=15,maxItems=15),
 'terminology':obj({'path':const('terminology.json'),'sha256':HASH,'bytes':COUNT}),
 'timing_phases':{'const':['compute','materialize','validate','export']}})
provider_request={'oneOf':[obj({'contract_version':const(V),'request_id':S,'operation':const(op),'context':ref('context'),'parameters':params})
  for op,params in [('manifest',obj({})),('result',obj({'metric_id':{'enum':IDS}})),('terminology',obj({}))]]}
event={'oneOf':[obj({'contract_version':const(V),'event_id':S,'instance_id':S,'generation':{'type':'integer','minimum':1,'maximum':9007199254740991},
 'correlation_id':S,'origin':{'enum':['user','host','system']},'context':ref('context'),'type':const(kind),'payload':payload})
 for kind,payload in [('ready',obj({})),('concept_selected',obj({'concept_id':CID})),
 ('navigation_requested',obj({'target':const('concept'),'concept_id':CID})),
 ('error',obj({'code':S,'message':S})),('destroyed',obj({}))]]}
defs={'identity':identity,'snapshot':snapshot,'source':source,'context':context,'denominator':denominator,'request':request,
      'partition':partition,'result':{'oneOf':result_branches},'bundle':bundle,'terminology':terminology,
      'provider_request':provider_request,'event':event}
write(OUT/'contract.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema','$id':URN,'$defs':defs})
for name in ['bundle','result','context','provider_request','event','terminology']:
    write(OUT/f'{name}.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema','$id':URN+':'+name,'$ref':f'{URN}#/$defs/{name}'})

# A hand-authored partial-January example: not generated by an analytical engine.
known=lambda s: dict(state='known',id=s,reason=None)
src={'source_id':'fixture:tiny_a','snapshot':dict(**known('fixture-1:tiny-a:55'),basis='synthetic_fixture',assertion_id='fixture-v1',immutable=True),
     'data_release':known('fixture-release-1'),'vocabulary_release':known('fixture-vocabulary-1'),
     'schema_fingerprint':known(sha((ROOT/'tests/fixtures/postgresql/ddl/5.5.sql').read_bytes())),'declared_cdm_version':'5.5'}
req=dict(profile_id=PROFILE['profile_id'],source_id=src['source_id'],window={'start':'2020-01-01','end':'2020-01-20'},
         measurement_concept_ids=[900000001],output_scope='restricted',disclosure_policy_id='synthetic-unsuppressed-v1')
canonical=lambda value: json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False)
request_hash=sha(canonical(req).encode())
manifest=dict(contract_version=V,bundle_id='contract-fixture-january-v1',run_id='contract-fixture-run-1',created_at='2026-10-26T00:00:00.000Z',
 generator={'name':'handwritten-contract-fixture','version':'1.0.0'},profile={'id':PROFILE['profile_id'],'revision':PROFILE['revision'],'sha256':sha((ROOT/'inst/analysis/alpha-measurement-v1.json').read_bytes())},
 source=src,request=req,request_sha256=request_hash,publication='complete',eligible_for_current_pointer=True,
 disclosure={'policy_id':req['disclosure_policy_id'],'applied':True,'approval_id':'synthetic-fixture-only','scope':'restricted'},
 reproducibility={'consistent_snapshot':True,'execution_start':'2026-10-26T00:00:00.000Z','execution_end':'2026-10-26T00:00:00.000Z','limitation':None},
 outputs=[],terminology={},timing_phases=['compute','materialize','validate','export'])
docs={}
def result(mid,rows):
    docs[mid]=dict(contract_version=V,bundle_id=manifest['bundle_id'],source_id=src['source_id'],run_id=manifest['run_id'],
                   request_sha256=request_hash,metric_id=mid,metric_version='1.0.0',state='computed',reason=None,rows=rows)
def row(dims,vals,den=None,state='computed',reason=None):return dict(dimensions=dims,state=state,reason=reason,values=vals,denominator=den)
def den(mid,dims,value,field='count'):return dict(metric_id=mid,dimensions=dims,field=field,value=str(value))
result('source.passport',[row({},dict(source_id=src['source_id'],source_snapshot_id=src['snapshot']['id'],data_release_id=src['data_release']['id'],
 declared_cdm_version='5.5',observed_schema_evidence=src['schema_fingerprint'],vocabulary_release_id=src['vocabulary_release']['id'],
 profile_id=PROFILE['profile_id'],profile_revision=PROFILE['revision'],metric_versions={mid:'1.0.0' for mid in IDS},run_id=manifest['run_id']))])
result('source.capabilities',[row({'probe_id':p['id']},dict(table_present=True,column_present=True,readable=True,
 required_for=IDS if p['required'] else [],availability='available',reason=None)) for p in PROFILE['prerequisite_probes']])
result('person.count',[row({}, {'count':'4'})])
result('observation.person_count',[row({}, {'count':'1'},den('person.count',{},4))])
result('observation.monthly_person_count',[row({'month':'2020-01-01'},{'count':'1'},den('person.count',{},4))])
result('observation.person_days',[row({}, {'count':'20'})])
periods=[dict(measurement_concept_id=900000001,period_kind=k,period_start='2020-01-01',period_end='2020-01-20') for k in ['window','month']]
result('measurement.record_count',[row(d,{'count':'5'}) for d in periods])
result('measurement.person_count',[row(d,{'count':'1'},den('observation.person_count',{},1) if d['period_kind']=='window' else den('observation.monthly_person_count',{'month':'2020-01-01'},1)) for d in periods])
result('measurement.representation_count',[row(dict(**d,numeric_present=n,coded_present=c,source_text_present=s),{'count':str(4 if n and not c and not s else 1 if not n and not c and not s else 0)},den('measurement.record_count',d,5))
 for d in periods for n,c,s in itertools.product([False,True],repeat=3)])
result('measurement.unit_count',[row(dict(**d,raw_unit_tag='id:900000101'),{'count':'5'},den('measurement.record_count',d,5)) for d in periods])
result('measurement.operator_count',[row(dict(**d,raw_operator_tag=t),{'count':str(n)},den('measurement.record_count',d,5)) for d in periods for t,n in [('zero',4),('id:900000201',1)]])
result('measurement.numeric_eligibility_count',[row(dict(**d,eligibility_reason=r['reason']),{'count':str({'eligible':3,'missing_numeric':1,'explicit_operator':1}.get(r['reason'],0))},den('measurement.record_count',d,5)) for d in periods for r in PROFILE['numeric_eligibility']])
nd=dict(measurement_concept_id=900000001,unit_concept_id=900000101,raw_operator_tag='zero')
result('measurement.numeric_summary',[row(nd,dict(n='3',sum='-3',min='-5',max='1',mean_numerator='-3',mean_denominator='3',p10='-5',p25='-5',p50='1',p75='1',p90='1'),den('measurement.numeric_summary',nd,3,'n'))])
result('execution.output_status',[row({'metric_id':mid},dict(state='computed',reason=None,requested=True,metric_version='1.0.0',source_id=src['source_id'])) for mid in IDS])
result('execution.timing',[row({'metric_id':mid,'phase':phase},dict(duration_ms=None,availability='unavailable',reason='contract_fixture_no_execution')) for mid in IDS for phase in manifest['timing_phases']])
complete=FIX/'complete'
for mid in IDS:
    path=f'results/{mid}.json';write(complete/path,docs[mid]);data=(complete/path).read_bytes()
    manifest['outputs'].append(dict(metric_id=mid,metric_version='1.0.0',state='computed',reason=None,path=path,sha256=sha(data),bytes=str(len(data)),rows=str(len(docs[mid]['rows']))))
terms=dict(contract_version=V,provider_id='local-fixture-vocabulary',provider_version='1.0.0',source_id=src['source_id'],vocabulary_release=src['vocabulary_release'],
 concepts=[dict(concept_id=i,state='available',concept_name=name,domain_id=domain,reason=None) for i,name,domain in [(900000001,'Toy laboratory A','Measurement'),(900000101,'Toy unit A','Unit'),(900000201,'Toy explicit operator','Meas Value Operator')]])
write(complete/'terminology.json',terms);data=(complete/'terminology.json').read_bytes();manifest['terminology']=dict(path='terminology.json',sha256=sha(data),bytes=str(len(data)))
write(complete/'manifest.json',manifest)
ctx=dict(source_id=src['source_id'],bundle_id=manifest['bundle_id'],manifest_sha256=sha((complete/'manifest.json').read_bytes()),access_scope_id='fixture-access-scope',authorization_epoch='fixture-auth-1')
write(FIX/'context.json',ctx)
write(FIX/'provider-request.json',dict(contract_version=V,request_id='fixture-read-1',operation='result',context=ctx,parameters={'metric_id':'measurement.numeric_summary'}))
write(FIX/'event.json',dict(contract_version=V,event_id='fixture-event-1',instance_id='fixture-instance-1',generation=1,correlation_id='fixture-update-1',origin='user',context=ctx,type='concept_selected',payload={'concept_id':900000001}))
states=[]
for state in ['computed','empty_source','empty_population','unavailable','unsupported','inaccessible','not_requested','failed','suppressed','stale']:
    r=json.loads(json.dumps(docs['measurement.record_count']));r['state']=state;r['reason']=None if state=='computed' else 'fixture_'+state
    r['rows']=[row(periods[0],{'count':'0'},state=state,reason=r['reason'])] if state in ['computed','empty_source','empty_population'] else None
    states.append(r)
write(FIX/'result-states.json',states)
invalid=[
 {'id':'unsupported-result-version','document':'result','base':'complete/results/person.count.json','path':['contract_version'],'value':'2.0.0'},
 {'id':'unsafe-json-number','document':'result','base':'complete/results/person.count.json','path':['rows',0,'values','count'],'value':9007199254740992},
 {'id':'computed-without-rows','document':'result','base':'complete/results/person.count.json','path':['rows'],'value':None},
 {'id':'failed-with-values','document':'result','base':'complete/results/person.count.json','path':['state'],'value':'failed'},
 {'id':'negative-count','document':'result','base':'complete/results/person.count.json','path':['rows',0,'values','count'],'value':'-1'},
 {'id':'wrong-value-type','document':'result','base':'complete/results/measurement.numeric_summary.json','path':['rows',0,'values','p50'],'value':1},
 {'id':'unknown-context-field','document':'context','base':'context.json','path':['token'],'value':'must-not-be-serialized'},
 {'id':'arbitrary-provider-filter','document':'provider_request','base':'provider-request.json','path':['parameters','cohort_filter'],'value':'unsupported'},
 {'id':'missing-requested-output','document':'bundle','base':'complete/manifest.json','path':['outputs'],'value':manifest['outputs'][:-1]},
 {'id':'traversal-path','document':'bundle','base':'complete/manifest.json','path':['outputs',0,'path'],'value':'../private.json'},
 {'id':'unsupported-embed-version','document':'event','base':'event.json','path':['contract_version'],'value':'9.0.0'}]
write(FIX/'invalid-cases.json',invalid)
write(OUT/'schema-lock.json',{'contract_version':V,'sha256':{p.name:sha(p.read_bytes()) for p in sorted(OUT.glob('*.schema.json'))}})
print('Wrote v1 schemas, complete 15-output synthetic bundle, explicit states and invalid examples')
