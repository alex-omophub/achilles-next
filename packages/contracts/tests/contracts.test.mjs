import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, mkdtemp, cp, writeFile, rm, symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {ROOT,validateDocument,validateBundleDocuments,validateBundleDirectory} from '../src/validator.mjs';
import {canonical,inputReuseIdentity,viewCacheKey,toSafeCountNumber} from '../src/index.mjs';
import {createHostHarness} from './support/host.mjs';
const FIX=resolve(ROOT,'tests/fixtures/contracts');
const load=async path=>JSON.parse(await readFile(resolve(FIX,path),'utf8'));
const source=await validateBundleDirectory(resolve(FIX,'complete'));
const context=await load('context.json');
const clone=()=>({manifest:structuredClone(source.manifest),documents:structuredClone(source.documents),terminology:structuredClone(source.terminology)});
const validate=b=>validateBundleDocuments(b.manifest,b.documents,b.terminology);
test('complete synthetic bundle has all fifteen typed, integrity-checked outputs',()=>assert.equal(source.documents.size,15));
for(const invalid of await load('invalid-cases.json')) test(`reject ${invalid.id}`,async()=>{
  const doc=await load(invalid.base);let target=doc;
  for(const key of invalid.path.slice(0,-1)) target=target[key];target[invalid.path.at(-1)]=invalid.value;
  assert.throws(()=>validateDocument(invalid.document,doc));
});
test('preserve all ten result availability states and known zero',async()=>{
  const states=await load('result-states.json');states.forEach(r=>validateDocument('result',r));
  assert.equal(states.length,10);assert.equal(states[0].rows[0].values.count,'0');
});
test('large exact counts survive validation; unsafe Number conversion is refused',()=>{
  const doc=structuredClone(source.documents.get('person.count'));doc.rows[0].values.count='9007199254740993';
  validateDocument('result',doc);assert.equal(JSON.parse(JSON.stringify(doc)).rows[0].values.count,'9007199254740993');
  assert.throws(()=>toSafeCountNumber(doc.rows[0].values.count),RangeError);assert.equal(toSafeCountNumber('0'),0);
});
test('suppressed row cannot carry a numeric payload or denominator',()=>{
  const doc=structuredClone(source.documents.get('person.count'));Object.assign(doc.rows[0],{state:'suppressed',reason:'fixture_policy'});
  assert.throws(()=>validateDocument('result',doc));doc.rows[0].values=null;validateDocument('result',doc);
});
test('zero-n statistics preserve undefined mean and extrema',()=>{
  const doc=structuredClone(source.documents.get('measurement.numeric_summary')),r=doc.rows[0];
  r.state='empty_population';r.reason='no_numeric_values';for(const key of Object.keys(r.values)) r.values[key]=key==='n'?'0':null;
  r.denominator.value='0';validateDocument('result',doc);r.values.sum='0';assert.throws(()=>validateDocument('result',doc));
});
for(const [label,n,min,max,sum,valid] of [
  ['positive lower bound','2','1','3','0',false],
  ['positive upper bound','2','1','3','7',false],
  ['negative lower bound','2','-3','-1','-7',false],
  ['negative upper bound','2','-3','-1','0',false],
  ['fraction beyond Number precision','2','9007199254740993.125','9007199254740993.125','18014398509481986.249',false],
  ['count beyond safe integer','9007199254740993','0.1','0.1','900719925474099.2',false],
  ['positive boundary','3','0.125','0.125','0.375',true],
  ['negative boundary','3','-0.125','-0.125','-0.375',true],
  ['mixed signs','2','-1.25','1.25','0',true],
  ['large count exact product','9007199254740993','0.1','0.1','900719925474099.3',true]
]) test(`numeric sum bounds: ${label}`,()=>{
  const doc=structuredClone(source.documents.get('measurement.numeric_summary')),r=doc.rows[0];
  Object.assign(r.values,{n,min,max,sum,mean_numerator:sum,mean_denominator:n,p10:min,p25:min,p50:min,p75:max,p90:max});
  r.denominator.value=n;
  if(valid) validateDocument('result',doc);
  else assert.throws(()=>validateDocument('result',doc),/sum.*bounds/i);
});
test('absent capability requires a missing table or column, not unknown or fully present flags',()=>{
  const doc=structuredClone(source.documents.get('source.capabilities')),v=doc.rows[0].values;
  Object.assign(v,{availability:'absent',reason:'Missing dependency',table_present:true,column_present:true,readable:true});
  assert.throws(()=>validateDocument('result',doc),/Absent capability/);
  Object.assign(v,{table_present:null,column_present:null,readable:null});
  assert.throws(()=>validateDocument('result',doc),/Absent capability/);
  Object.assign(v,{table_present:true,column_present:false});validateDocument('result',doc);
  Object.assign(v,{table_present:false,column_present:null});validateDocument('result',doc);
});
test('a resolvable but wrong all-person denominator is rejected',()=>{
  const b=clone(),r=b.documents.get('measurement.person_count').rows[0];
  r.denominator={metric_id:'person.count',dimensions:{},field:'count',value:'4'};assert.throws(()=>validate(b),/Wrong denominator/);
});
test('representation totals and numeric n must reconcile',()=>{
  const b=clone();b.documents.get('measurement.representation_count').rows[0].values.count='99';assert.throws(()=>validate(b),/reconcile/);
  const c=clone(),r=c.documents.get('measurement.numeric_summary').rows[0];r.values.n='4';r.values.mean_denominator='4';r.denominator.value='4';
  assert.throws(()=>validate(c),/reconcile/);
});
test('failed output cannot be promoted to complete publication',()=>{
  const b=clone(),p=b.manifest.outputs.find(p=>p.metric_id==='measurement.numeric_summary');p.state='failed';p.reason='fixture_failure';
  p.rows='0';
  Object.assign(b.documents.get(p.metric_id),{state:p.state,reason:p.reason,rows:null});
  const ledger=b.documents.get('execution.output_status').rows.find(r=>r.dimensions.metric_id===p.metric_id);Object.assign(ledger.values,{state:p.state,reason:p.reason});
  assert.throws(()=>validate(b),/Complete bundle/);b.manifest.publication='partial';b.manifest.eligible_for_current_pointer=false;validate(b);
});
test('unknown snapshot can be viewed with a limitation but cannot authorize reuse',()=>{
  const b=clone();b.manifest.source.snapshot={state:'unknown',id:null,reason:'no_immutable_snapshot',basis:null,assertion_id:null,immutable:false};
  b.manifest.reproducibility.consistent_snapshot=false;b.manifest.reproducibility.limitation='Read occurred without an immutable snapshot';
  b.documents.get('source.passport').rows[0].values.source_snapshot_id=null;validate(b);
  assert.equal(inputReuseIdentity(b.manifest),null);assert.equal(viewCacheKey(b.manifest,context,'person.count','instance'),null);
});
test('cache keys isolate instances, authorization changes, vocabulary and metric definitions',()=>{
  const base=viewCacheKey(source.manifest,context,'person.count','a');
  assert.notEqual(base,viewCacheKey(source.manifest,context,'person.count','b'));
  assert.notEqual(base,viewCacheKey(source.manifest,{...context,authorization_epoch:'new-auth'},'person.count','a'));
  assert.notEqual(base,viewCacheKey(source.manifest,{...context,access_scope_id:'other-access'},'person.count','a'));
  const b=clone();b.manifest.source.vocabulary_release.id='new-vocabulary';assert.notEqual(inputReuseIdentity(b.manifest),inputReuseIdentity(source.manifest));
});
test('an immutable source assertion cannot authorize reuse of an inconsistent execution',()=>{
  const b=clone();b.manifest.reproducibility.consistent_snapshot=false;
  assert.throws(()=>validate(b),/reproducibility limitation/);
  b.manifest.reproducibility.limitation='Outputs were read across separate snapshots';validate(b);
  assert.equal(inputReuseIdentity(b.manifest),null);
});
test('unavailable capabilities and failed ledger entries retain explicit reasons',()=>{
  const cap=structuredClone(source.documents.get('source.capabilities'));
  Object.assign(cap.rows[0].values,{availability:'inaccessible',readable:false});
  assert.throws(()=>validateDocument('result',cap),/availability\/reason/);
  cap.rows[0].values.reason='fixture_access_denied';validateDocument('result',cap);
  const ledger=structuredClone(source.documents.get('execution.output_status'));
  ledger.rows[0].values.state='failed';assert.throws(()=>validateDocument('result',ledger),/State\/reason/);
});
test('file tampering and symlinked artifact paths are refused',async()=>{
  const directory=await mkdtemp(resolve(tmpdir(),'achilles-contract-'));
  try {
    await cp(resolve(FIX,'complete'),directory,{recursive:true});const target=resolve(directory,'results/person.count.json');
    await writeFile(target,'{}');await assert.rejects(validateBundleDirectory(directory),/integrity mismatch/);
    await rm(target);await symlink(resolve(FIX,'complete/results/person.count.json'),target);await assert.rejects(validateBundleDirectory(directory),/Symlinked/);
  } finally {await rm(directory,{recursive:true,force:true});}
});
const bytes=value=>new TextEncoder().encode(JSON.stringify(value));
const hash=value=>createHash('sha256').update(value).digest('hex');
function memorySource(label) {
  const b=clone();b.manifest.bundle_id=`fixture-bundle-${label}`;b.manifest.source.source_id=`fixture:${label}`;b.manifest.request.source_id=b.manifest.source.source_id;
  b.manifest.request_sha256=hash(canonical(b.manifest.request));b.terminology.source_id=b.manifest.source.source_id;
  const resultBytes=new Map();
  for(const p of b.manifest.outputs) {
    const r=b.documents.get(p.metric_id);Object.assign(r,{bundle_id:b.manifest.bundle_id,source_id:b.manifest.source.source_id,request_sha256:b.manifest.request_sha256});
    if(p.metric_id==='source.passport') r.rows[0].values.source_id=b.manifest.source.source_id;
    if(p.metric_id==='execution.output_status') r.rows.forEach(row=>row.values.source_id=b.manifest.source.source_id);
    const raw=bytes(r);p.sha256=hash(raw);p.bytes=String(raw.length);resultBytes.set(p.metric_id,raw);
  }
  const term=bytes(b.terminology);b.manifest.terminology.sha256=hash(term);b.manifest.terminology.bytes=String(term.length);validate(b);
  const raw=bytes(b.manifest);return {context:{...context,source_id:b.manifest.source.source_id,bundle_id:b.manifest.bundle_id,manifest_sha256:hash(raw)},raw,resultBytes,term};
}
const a=memorySource('source-a'),b=memorySource('source-b');
function providerFor(sources,wait=async()=>{}) {
  const get=c=>sources.find(s=>s.context.bundle_id===c.bundle_id);
  return {async getManifest(c,o){await wait(c,o,'manifest');return get(c).raw;},
    async getResult(c,id,o){await wait(c,o,'result');return get(c).resultBytes.get(id);},
    async getTerminology(c,o){await wait(c,o,'terminology');return get(c).term;}};
}
const view={kind:'metric',metric_id:'person.count'};
test('context switch cancels old requests and discards a late response even if provider ignores abort',async()=>{
  let release,arrived;const gate=new Promise(r=>release=r),started=new Promise(r=>arrived=r);let aborted=false;const visible=[],events=[];
  const provider=providerFor([a,b],async(c,o,op)=>{if(c.bundle_id===a.context.bundle_id&&op==='result'){o.signal.addEventListener('abort',()=>aborted=true,{once:true});arrived();await gate;}});
  const host=createHostHarness({provider,context:a.context,view,render:v=>visible.push(v),onEvent:e=>events.push(e)});
  await started;assert.equal((await host.update({context:b.context,view,correlation_id:'switch-b'})).status,'applied');release();
  assert.equal((await host.ready).status,'superseded');assert.ok(aborted);
  assert.equal(visible.filter(Boolean).length,1);assert.equal(visible.filter(Boolean)[0].context.source_id,b.context.source_id);
  assert.ok(events.every(e=>e.context.source_id===b.context.source_id));await host.destroy();
});
test('destroy during read is immediate, idempotent and prevents later render/events',async()=>{
  let release,started;const gate=new Promise(r=>release=r),waiting=new Promise(r=>started=r);const visible=[],events=[];let cleaned=0;
  const provider=providerFor([a],async()=>{started();await gate;});
  const host=createHostHarness({provider,context:a.context,view,render:v=>visible.push(v),onEvent:e=>events.push(e),cleanup:()=>{cleaned++;}});
  await waiting;const first=host.destroy();assert.equal(first,host.destroy());await first;release();assert.equal((await host.ready).status,'destroyed');
  assert.equal(cleaned,1);assert.equal(visible.filter(Boolean).length,0);assert.deepEqual(events.map(e=>e.type),['destroyed']);
  await assert.rejects(host.update({context:a.context,view,correlation_id:'too-late'}),/DESTROYED/);
});
test('shared provider instances preserve per-instance context, events and lifetime',async()=>{
  const provider=providerFor([a,b]);let disposed=0;provider.dispose=()=>disposed++;const ea=[],eb=[];
  const x=createHostHarness({provider,context:a.context,view,instance_id:'x',onEvent:e=>ea.push(e)});
  const y=createHostHarness({provider,context:b.context,view,instance_id:'y',onEvent:e=>eb.push(e)});
  await Promise.all([x.ready,y.ready]);await x.destroy();assert.ok(ea.every(e=>e.instance_id==='x'&&e.context.source_id===a.context.source_id));
  assert.ok(eb.every(e=>e.instance_id==='y'&&e.context.source_id===b.context.source_id));assert.equal(disposed,0);await y.destroy();
});
test('wrong-source bytes cannot render under another source context',async()=>{
  const visible=[];const host=createHostHarness({provider:providerFor([a]),context:{...a.context,source_id:'wrong-source'},view,render:v=>visible.push(v)});
  await assert.rejects(host.ready,/INCOMPATIBLE_CONTEXT/);assert.equal(visible.filter(Boolean).length,0);await host.destroy();
});
test('authorization update clears old content and failed new access never reuses it',async()=>{
  const visible=[];const base=providerFor([a]);const provider={...base,async getManifest(c,o){if(c.authorization_epoch==='revoked') throw new Error('INACCESSIBLE');return base.getManifest(c,o);}};
  const host=createHostHarness({provider,context:a.context,view,render:v=>visible.push(v)});await host.ready;
  await assert.rejects(host.update({context:{...a.context,authorization_epoch:'revoked'},view,correlation_id:'auth-change'}),/INACCESSIBLE/);
  assert.equal(visible.at(-1),null);await host.destroy();
});
test('destroy still cleans up once when renderer teardown throws',async()=>{
  let fail=false,cleaned=0;const host=createHostHarness({provider:providerFor([a]),context:a.context,view,
    render:()=>{if(fail)throw new Error('renderer teardown failed');},cleanup:()=>cleaned++});
  await host.ready;fail=true;const first=host.destroy();assert.equal(first,host.destroy());
  await assert.rejects(first,/teardown failed/);assert.equal(cleaned,1);
});
