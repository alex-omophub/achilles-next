// Node-only producer/fixture validator. Schema registry is local and offline.
import Ajv2020 from 'ajv/dist/2020.js';
import { readFile, lstat, realpath } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, sep } from 'node:path';
import { createHash } from 'node:crypto';
import { canonical } from './index.mjs';
import {ensure, validateResult, periods, validateBundleDocuments as validatePortableBundle} from './semantics.mjs';
export {ensure, validateResult, periods} from './semantics.mjs';
const AVAILABLE = new Set(['computed','empty_source','empty_population']);
function reason(state,value) {ensure(state==='computed' ? value===null : typeof value==='string' && value.length>0,'State/reason mismatch');}
export const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
export const profile = JSON.parse(await readFile(resolve(ROOT, 'inst/analysis/alpha-measurement-v1.json'), 'utf8'));
const schema = JSON.parse(await readFile(resolve(ROOT, 'inst/contracts/v1/contract.schema.json'), 'utf8'));
const digest = data => createHash('sha256').update(data).digest('hex');
const schemaLock=JSON.parse(await readFile(resolve(ROOT,'inst/contracts/v1/schema-lock.json'),'utf8'));
for(const [name,hash] of Object.entries(schemaLock.sha256)) ensure(digest(await readFile(resolve(ROOT,'inst/contracts/v1',name)))===hash,`Schema lock mismatch: ${name}`);
// Stop after the first error in each branch: collecting every error for all
// nonmatching metric/state unions rescans large, otherwise valid row arrays.
const ajv = new Ajv2020({allErrors: false, strict: true, coerceTypes: false, removeAdditional: false, useDefaults: false});
ajv.addFormat('date', value => /^\d{4}-\d{2}-\d{2}$/.test(value) && value.slice(0,4) !== '0000' &&
  !Number.isNaN(Date.parse(`${value}T00:00:00.000Z`)) && new Date(`${value}T00:00:00.000Z`).toISOString().slice(0,10) === value);
ajv.addFormat('date-time', value => /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value) &&
  value.slice(0,4) !== '0000' && !Number.isNaN(Date.parse(value)) && new Date(value).toISOString() === value);
ajv.addSchema(schema);
const validators = new Map();
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
  return validatePortableBundle(manifest, documents, terminology, {profile, validateDocument});
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
