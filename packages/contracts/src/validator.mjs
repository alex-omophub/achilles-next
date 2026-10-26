// Node-only producer/fixture validator. Schema registry is local and offline.
import Ajv2020 from 'ajv/dist/2020.js';
import { readFile, lstat, realpath } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, sep } from 'node:path';
import { createHash } from 'node:crypto';
import { canonical } from './index.mjs';
export const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
export const profile = JSON.parse(await readFile(resolve(ROOT, 'inst/analysis/alpha-measurement-v1.json'), 'utf8'));
const schema = JSON.parse(await readFile(resolve(ROOT, 'inst/contracts/v1/contract.schema.json'), 'utf8'));
const digest = data => createHash('sha256').update(data).digest('hex');
export function ensure(test, message) { if (!test) throw new Error(message); }
const schemaLock=JSON.parse(await readFile(resolve(ROOT,'inst/contracts/v1/schema-lock.json'),'utf8'));
for(const [name,hash] of Object.entries(schemaLock.sha256)) ensure(digest(await readFile(resolve(ROOT,'inst/contracts/v1',name)))===hash,`Schema lock mismatch: ${name}`);
const ajv = new Ajv2020({allErrors: true, strict: true, coerceTypes: false, removeAdditional: false, useDefaults: false});
ajv.addFormat('date', value => /^\d{4}-\d{2}-\d{2}$/.test(value) && value.slice(0,4) !== '0000' &&
  !Number.isNaN(Date.parse(`${value}T00:00:00.000Z`)) && new Date(`${value}T00:00:00.000Z`).toISOString().slice(0,10) === value);
ajv.addFormat('date-time', value => /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value) &&
  value.slice(0,4) !== '0000' && !Number.isNaN(Date.parse(value)) && new Date(value).toISOString() === value);
ajv.addSchema(schema);
const validators = new Map();
const AVAILABLE = new Set(['computed','empty_source','empty_population']);
const ALL_STATS = ['sum','min','max','mean_numerator','mean_denominator','p10','p25','p50','p75','p90'];
function reason(state, value) {
  ensure(state === 'computed' ? value === null : typeof value === 'string' && value.length > 0, 'State/reason mismatch');
}
function compareDecimal(a, b) {
  const parse = value => { const [i, f=''] = value.split('.'); return [BigInt(i + f), f.length]; };
  const [x, p] = parse(a), [y, q] = parse(b), scale = Math.max(p,q);
  const left=x*10n**BigInt(scale-p), right=y*10n**BigInt(scale-q);
  return left < right ? -1 : left > right ? 1 : 0;
}
export function validateDocument(name, document) {
  let validate = validators.get(name);
  if (!validate) { validate = ajv.compile({$ref: `${schema.$id}#/$defs/${name}`}); validators.set(name,validate); }
  ensure(validate(document), `${name} schema: ${ajv.errorsText(validate.errors, {separator: '; '})}`);
  if (name === 'result') validateResult(document);
  if (name === 'bundle') validateManifest(document);
  if (name === 'terminology') {
    ensure(new Set(document.concepts.map(c => c.concept_id)).size === document.concepts.length, 'Duplicate terminology concept ID');
    for (const c of document.concepts) ensure(c.state === 'available' ? c.concept_name !== null && c.domain_id !== null && c.reason === null :
      c.concept_name === null && c.domain_id === null && c.reason !== null, 'Terminology state/value mismatch');
  }
  return document;
}
export function validateResult(doc) {
  reason(doc.state, doc.reason);
  ensure(AVAILABLE.has(doc.state) ? Array.isArray(doc.rows) : doc.rows === null, 'State/rows mismatch: unavailable values must not leak');
  if (doc.rows === null) return;
  if(doc.state!=='computed') ensure(doc.rows.every(r=>r.state===doc.state||r.state==='suppressed'),'Output/row empty state mismatch');
  const seen=new Set();
  for (const row of doc.rows) {
    const key=canonical(row.dimensions); ensure(!seen.has(key), 'Duplicate result stratum'); seen.add(key);
    reason(row.state,row.reason);
    if (row.state === 'suppressed') { ensure(row.values === null && row.denominator === null, 'Suppressed row leaked values'); continue; }
    ensure(row.values !== null, 'Computed/empty row has no typed values');
    const v=row.values;
    if (row.state !== 'computed') ensure(v.count === '0' || v.n === '0', 'Empty row must carry zero count/n');
    if (doc.metric_id === 'measurement.numeric_summary') {
      ensure(['null','zero'].includes(row.dimensions.raw_operator_tag), 'Nonzero operator cannot enter numeric summary');
      if (v.n === '0') ensure(row.state !== 'computed' && ALL_STATS.every(k => v[k] === null), 'Zero-n summary has non-null statistics or wrong state');
      else {
        ensure(row.state === 'computed' && ALL_STATS.every(k => v[k] !== null), 'Nonempty summary lacks statistics');
        ensure(v.mean_numerator === v.sum && v.mean_denominator === v.n, 'Mean must retain exact sum/n');
        const ordered=['min','p10','p25','p50','p75','p90','max'];
        ensure(ordered.slice(1).every((k,i) => compareDecimal(v[ordered[i]],v[k]) <= 0), 'Numeric order statistics out of order');
      }
    }
    if (doc.metric_id === 'execution.timing') ensure(v.availability === 'measured' ? v.duration_ms !== null && v.reason === null :
      v.duration_ms === null && v.reason !== null, 'Unavailable timing must not become zero');
    if (doc.metric_id === 'source.capabilities') ensure(v.availability === 'available' ?
      v.table_present === true && v.column_present === true && v.readable === true && v.reason === null :
      v.reason !== null, 'Capability availability/reason is inconsistent');
    if (doc.metric_id === 'execution.output_status') reason(v.state,v.reason);
  }
}
export function periods(request) {
  const {start,end}=request.window, output=[];
  const [year,month]=start.split('-').map(Number), [ey,em]=end.split('-').map(Number);
  const count=(ey-year)*12+em-month+1;
  ensure(start<=end && count>=1 && count<=120, 'Invalid bounded window');
  output.push({period_kind:'window',period_start:start,period_end:end});
  for(let i=0;i<count;i++) {
    const y=year+Math.floor((month-1+i)/12),m=(month-1+i)%12+1;
    const first=`${String(y).padStart(4,'0')}-${String(m).padStart(2,'0')}-01`;
    const date=new Date(`${first}T00:00:00.000Z`); date.setUTCMonth(date.getUTCMonth()+1);date.setUTCDate(0);
    output.push({period_kind:'month',period_start:start>first?start:first,period_end:end<date.toISOString().slice(0,10)?end:date.toISOString().slice(0,10)});
  }
  return output;
}
export function validateManifest(doc) {
  ensure(doc.source.source_id === doc.request.source_id, 'Request/source mismatch'); periods(doc.request);
  ensure(doc.request_sha256 === digest(canonical(doc.request)), 'Request hash mismatch');
  ensure(doc.profile.sha256 === digest(awaitProfileBytes), 'Frozen profile hash mismatch');
  const ids=doc.outputs.map(o=>o.metric_id),paths=doc.outputs.map(o=>o.path);
  ensure(new Set(ids).size===ids.length && profile.required_outputs.every(id=>ids.includes(id)), 'Missing/duplicate requested outputs');
  ensure(new Set(paths).size===paths.length, 'Duplicate partition path');
  for(const o of doc.outputs) reason(o.state,o.reason);
  ensure(doc.eligible_for_current_pointer === (doc.publication === 'complete'), 'Partial run cannot replace current complete pointer');
  if(doc.publication === 'complete') ensure(doc.outputs.every(o=>AVAILABLE.has(o.state)||o.state==='suppressed'), 'Complete bundle contains a required failure/unavailable output');
  ensure(doc.disclosure.policy_id===doc.request.disclosure_policy_id, 'Disclosure policy mismatch');
  if(doc.publication === 'complete') ensure(doc.disclosure.applied && doc.disclosure.approval_id!==null, 'Complete bundle lacks applied disclosure policy');
  if(doc.source.snapshot.state==='unknown') ensure(!doc.reproducibility.consistent_snapshot && doc.reproducibility.limitation!==null, 'Unknown snapshot needs reproducibility limitation');
  if(!doc.reproducibility.consistent_snapshot) ensure(doc.reproducibility.limitation!==null,'Inconsistent execution needs reproducibility limitation');
  ensure(doc.reproducibility.execution_start<=doc.reproducibility.execution_end, 'Invalid execution window');
  ensure(doc.source.schema_fingerprint.state!=='known'||/^[0-9a-f]{64}$/.test(doc.source.schema_fingerprint.id), 'Schema identity must be a fingerprint');
}
const awaitProfileBytes=await readFile(resolve(ROOT,'inst/analysis/alpha-measurement-v1.json'));
export function validateBundleDocuments(manifest, documents, terminology) {
  validateDocument('bundle',manifest);validateDocument('terminology',terminology);
  ensure(documents.size===manifest.outputs.length && [...documents.keys()].every(id=>profile.required_outputs.includes(id)),'Unexpected result documents');
  ensure(terminology.source_id===manifest.source.source_id && canonical(terminology.vocabulary_release)===canonical(manifest.source.vocabulary_release), 'Terminology scope/vocabulary mismatch');
  const byId=new Map();
  for(const partition of manifest.outputs) {
    const doc=documents.get(partition.metric_id);ensure(doc,'Missing declared result document');validateDocument('result',doc);
    ensure(doc.metric_id===partition.metric_id && doc.metric_version===partition.metric_version && doc.state===partition.state && doc.reason===partition.reason, 'Partition/result identity or status mismatch');
    ensure(doc.bundle_id===manifest.bundle_id && doc.source_id===manifest.source.source_id && doc.run_id===manifest.run_id && doc.request_sha256===manifest.request_sha256,'Result source/run/request mismatch');
    ensure(partition.rows===String(doc.rows?.length??0),'Declared row count mismatch');byId.set(doc.metric_id,doc);
  }
  const lookup=(mid,dims)=>byId.get(mid)?.rows?.find(r=>canonical(r.dimensions)===canonical(dims));
  const passport=lookup('source.passport',{})?.values;
  if(passport) ensure(passport.source_id===manifest.source.source_id && passport.source_snapshot_id===manifest.source.snapshot.id &&
    passport.data_release_id===manifest.source.data_release.id && passport.vocabulary_release_id===manifest.source.vocabulary_release.id &&
    passport.declared_cdm_version===manifest.source.declared_cdm_version && canonical(passport.observed_schema_evidence)===canonical(manifest.source.schema_fingerprint) &&
    passport.run_id===manifest.run_id,'Passport/manifest identity mismatch');
  for(const doc of documents.values()) for(const row of doc.rows??[]) {
    let expected=null;const d=row.dimensions;
    if(['observation.person_count','observation.monthly_person_count'].includes(doc.metric_id)) expected=['person.count',{},'count'];
    if(doc.metric_id==='measurement.person_count') expected=d.period_kind==='window'?['observation.person_count',{},'count']:
      ['observation.monthly_person_count',{month:d.period_start.slice(0,7)+'-01'},'count'];
    if(['measurement.representation_count','measurement.unit_count','measurement.operator_count','measurement.numeric_eligibility_count'].includes(doc.metric_id))
      expected=['measurement.record_count',Object.fromEntries(['measurement_concept_id','period_kind','period_start','period_end'].map(k=>[k,d[k]])),'count'];
    if(doc.metric_id==='measurement.numeric_summary') expected=[doc.metric_id,d,'n'];
    if(row.state!=='suppressed') ensure(expected ? row.denominator?.metric_id===expected[0] && canonical(row.denominator.dimensions)===canonical(expected[1]) && row.denominator.field===expected[2] : row.denominator===null,'Wrong denominator definition');
    if(row.denominator) {
      const d=row.denominator,target=lookup(d.metric_id,d.dimensions);
      ensure(target && target.values?.[d.field]===d.value,'Denominator does not resolve to exact source cell');
    }
    if('measurement_concept_id' in row.dimensions) ensure(manifest.request.measurement_concept_ids.includes(row.dimensions.measurement_concept_id),'Result concept outside request');
    if('period_kind' in d) ensure(periods(manifest.request).some(p=>p.period_kind===d.period_kind&&p.period_start===d.period_start&&p.period_end===d.period_end),'Result period outside request');
    if(doc.metric_id==='measurement.numeric_summary') ensure(terminology.concepts.some(c=>c.concept_id===row.dimensions.unit_concept_id && c.state==='available' && c.domain_id==='Unit'),'Numeric unit is not known locally');
    if(doc.metric_id==='execution.output_status' && row.values) {
      const p=manifest.outputs.find(p=>p.metric_id===row.dimensions.metric_id);
      ensure(p && row.values.state===p.state && row.values.reason===p.reason && row.values.requested===true && row.values.source_id===manifest.source.source_id,'Execution ledger disagrees with requested outputs');
    }
  }
  const sameSet=(actual,expected,label)=>ensure(canonical([...actual].sort())===canonical([...expected].sort()),`Missing/extra dense cells: ${label}`);
  const keys=rows=>(rows??[]).map(r=>canonical(r.dimensions));
  const dense=['measurement.record_count','measurement.person_count','measurement.representation_count','measurement.numeric_eligibility_count'];
  const ps=periods(manifest.request), base=manifest.request.measurement_concept_ids.flatMap(c=>ps.map(p=>({measurement_concept_id:c,...p})));
  for(const mid of dense) if(byId.get(mid).rows!==null) {
    let expected=base;
    if(mid==='measurement.representation_count') expected=base.flatMap(d=>[false,true].flatMap(n=>[false,true].flatMap(c=>[false,true].map(s=>({...d,numeric_present:n,coded_present:c,source_text_present:s})))));
    if(mid==='measurement.numeric_eligibility_count') expected=base.flatMap(d=>profile.numeric_eligibility.map(r=>({...d,eligibility_reason:r.reason})));
    sameSet(keys(byId.get(mid).rows),expected.map(canonical),mid);
  }
  const singletons=['source.passport','person.count','observation.person_count','observation.person_days'];
  for(const mid of singletons) if(byId.get(mid).rows!==null) sameSet(keys(byId.get(mid).rows),[canonical({})],mid);
  if(byId.get('source.capabilities').rows!==null) sameSet(keys(byId.get('source.capabilities').rows),profile.prerequisite_probes.map(p=>canonical({probe_id:p.id})),'capabilities');
  if(byId.get('execution.output_status').rows!==null) sameSet(keys(byId.get('execution.output_status').rows),profile.required_outputs.map(metric_id=>canonical({metric_id})),'output ledger');
  if(byId.get('execution.timing').rows!==null) sameSet(keys(byId.get('execution.timing').rows),profile.required_outputs.flatMap(metric_id=>manifest.timing_phases.map(phase=>canonical({metric_id,phase}))),'timing');
  const months=ps.filter(p=>p.period_kind==='month').map(p=>canonical({month:p.period_start.slice(0,7)+'-01'}));
  if(byId.get('observation.monthly_person_count').rows!==null) sameSet(keys(byId.get('observation.monthly_person_count').rows),months,'monthly observed people');
  for(const d of base) {
    const records=lookup('measurement.record_count',d)?.values?.count;
    for(const mid of ['measurement.representation_count','measurement.numeric_eligibility_count','measurement.unit_count','measurement.operator_count']) {
      const rows=byId.get(mid).rows?.filter(r=>Object.entries(d).every(([k,v])=>r.dimensions[k]===v));
      if(records!==undefined && rows && rows.every(r=>r.values!==null)) ensure(rows.reduce((s,r)=>s+BigInt(r.values.count),0n)===BigInt(records),`Counts do not reconcile: ${mid}`);
    }
    const tested=lookup('measurement.person_count',d),den=tested?.denominator;
    if(tested?.values && den?.value!==null && den) ensure(BigInt(tested.values.count)<=BigInt(den.value),'Tested people exceed observed denominator');
  }
  for(const concept of manifest.request.measurement_concept_ids) {
    const window=base.find(d=>d.measurement_concept_id===concept&&d.period_kind==='window');
    const rows=byId.get('measurement.numeric_summary').rows?.filter(r=>r.dimensions.measurement_concept_id===concept);
    const eligible=lookup('measurement.numeric_eligibility_count',{...window,eligibility_reason:'eligible'})?.values?.count;
    if(rows&&eligible!==undefined&&rows.every(r=>r.values!==null)) ensure(rows.reduce((n,r)=>n+BigInt(r.values.n),0n)===BigInt(eligible),'Numeric n does not reconcile to eligible records');
    const records=lookup('measurement.record_count',window)?.values?.count;
    const monthly=base.filter(d=>d.measurement_concept_id===concept&&d.period_kind==='month').map(d=>lookup('measurement.record_count',d)?.values?.count);
    if(records!==undefined&&monthly.every(v=>v!==undefined)) ensure(monthly.reduce((n,v)=>n+BigInt(v),0n)===BigInt(records),'Monthly records do not reconcile to window');
  }
  if(manifest.publication==='complete') for(const row of byId.get('source.capabilities').rows??[]) {
    const probe=profile.prerequisite_probes.find(p=>p.id===row.dimensions.probe_id);
    ensure(!probe.required||row.values?.availability==='available','Complete alpha lacks a required capability');
  }
  return {manifest,documents,terminology};
}
export async function validateBundleDirectory(directory) {
  const root=await realpath(directory);
  const read=async path=>{
    const target=resolve(root,path);ensure(target.startsWith(root+sep),'Bundle path escapes root');
    const actual=await realpath(target);ensure(actual===target,'Symlinked artifact paths are not accepted');
    const stat=await lstat(target);ensure(stat.isFile()&&stat.size<=10*1024*1024,'Invalid/oversize artifact');return readFile(target);
  };
  const manifestBytes=await read('manifest.json');const manifest=JSON.parse(manifestBytes);validateDocument('bundle',manifest);
  const documents=new Map();
  for(const p of manifest.outputs) {
    const bytes=await read(p.path);ensure(digest(bytes)===p.sha256&&String(bytes.length)===p.bytes,'Partition integrity mismatch');
    documents.set(p.metric_id,JSON.parse(bytes));
  }
  const bytes=await read(manifest.terminology.path);ensure(digest(bytes)===manifest.terminology.sha256&&String(bytes.length)===manifest.terminology.bytes,'Terminology integrity mismatch');
  return {...validateBundleDocuments(manifest,documents,JSON.parse(bytes)),manifest_sha256:digest(manifestBytes)};
}
