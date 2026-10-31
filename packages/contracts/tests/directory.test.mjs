import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {validateBundleDirectory,ROOT} from '../src/validator.mjs';
import {validateInventory} from '../src/directory.mjs';
import {canonical} from '../src/index.mjs';
const source = await validateBundleDirectory(resolve(ROOT,'tests/fixtures/contracts/complete'));
const hash = b=>createHash('sha256').update(b).digest('hex');
for(const artifact of ['manifest','result','terminology']) test(`reject malformed UTF-8 in ${artifact}, even with matching checksums`,async()=>{
  const root=await mkdtemp(resolve(tmpdir(),'achilles-encoding-'));
  try {
    await mkdir(resolve(root,'results'));
    const b=structuredClone(source), marker='invalid-\ufffd';
    if(artifact==='manifest') b.manifest.generator.version=marker;
    if(artifact==='terminology') b.terminology.concepts[0].concept_name=marker;
    if(artifact==='result') {
      const d=b.documents.get('measurement.numeric_summary'); Object.assign(d,{state:'suppressed',reason:marker,rows:null});
      Object.assign(b.documents.get('execution.output_status').rows.find(r=>r.dimensions.metric_id===d.metric_id).values,{state:d.state,reason:d.reason});
    }
    const bytes=(doc,bad)=>{
      const data=Buffer.from(canonical(doc));
      if(!bad) return data;
      const i=data.indexOf(Buffer.from('\ufffd')); assert.ok(i>=0);
      return Buffer.concat([data.subarray(0,i),Buffer.from([0xff]),data.subarray(i+3)]);
    };
    for(const p of b.manifest.outputs) {
      const d=b.documents.get(p.metric_id),data=bytes(d,artifact==='result'&&p.metric_id==='measurement.numeric_summary');
      Object.assign(p,{state:d.state,reason:d.reason,rows:String(d.rows?.length??0),sha256:hash(data),bytes:String(data.length)});
      await writeFile(resolve(root,p.path),data);
    }
    const term=bytes(b.terminology,artifact==='terminology');
    Object.assign(b.manifest.terminology,{sha256:hash(term),bytes:String(term.length)});
    await writeFile(resolve(root,'terminology.json'),term);
    await writeFile(resolve(root,'manifest.json'),bytes(b.manifest,artifact==='manifest'));
    await assert.rejects(()=>validateBundleDirectory(root),{code:'ERR_ENCODING_INVALID_ENCODED_DATA'});
    const validator=resolve(ROOT,'inst/validation/validate.mjs');
    const control=spawnSync(process.execPath,[validator,resolve(ROOT,'tests/fixtures/contracts/complete')],{encoding:'utf8'});
    assert.equal(control.status,0,'Installed validator must accept the known-good fixture: '+control.stdout+control.stderr);
    const installed=spawnSync(process.execPath,[validator,root],{encoding:'utf8'});
    assert.equal(installed.status,1,installed.stdout+installed.stderr);
  } finally {await rm(root,{recursive:true,force:true});}
});
test('inventory stops and closes the iterator on the first undeclared entry',async()=>{
  let read=0,closed=false;
  const open=async()=>({async *[Symbol.asyncIterator]() {
    try {for(let i=0;i<1_000_000;i++) {read++;yield {name:`extra-${i}`,isDirectory:()=>false,isFile:()=>true};}}
    finally {closed=true;}
  }});
  await assert.rejects(()=>validateInventory('/bundle',['manifest.json'],open),/Unexpected bundle entry/);
  assert.equal(read,1);assert.equal(closed,true);
});
