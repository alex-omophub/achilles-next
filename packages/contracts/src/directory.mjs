// One bounded, ordinary-file inventory for producer and installed validation.
import {readFile, lstat, realpath, readdir} from 'node:fs/promises';
import {resolve, sep} from 'node:path';
import {createHash} from 'node:crypto';
import {ensure} from './semantics.mjs';
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
export async function validateDirectory(directory, validateDocument, validateDocuments) {
  const root = await realpath(directory);
  let total = 0;
  const read = async path => {
    ensure(/^(manifest|terminology)\.json$|^results\/[a-z][a-z0-9._-]*\.json$/.test(path) && !path.includes('..'), 'Unsafe artifact path');
    const target = resolve(root,path);
    ensure(target.startsWith(root+sep) && await realpath(target) === target, 'Symlinked artifact paths are not accepted');
    const stat = await lstat(target);
    total += stat.size;
    ensure(stat.isFile() && stat.size <= 10*1024*1024 && total <= 64*1024*1024, 'Invalid/oversize bundle');
    const bytes = await readFile(target);
    ensure(bytes.length === stat.size, 'Artifact changed while reading');
    return bytes;
  };
  const manifestBytes = await read('manifest.json');
  const manifest = JSON.parse(manifestBytes); validateDocument('bundle',manifest);
  const documents = new Map();
  for (const p of manifest.outputs) {
    const bytes = await read(p.path);
    ensure(digest(bytes) === p.sha256 && String(bytes.length) === p.bytes, 'Partition integrity mismatch');
    documents.set(p.metric_id,JSON.parse(bytes));
  }
  const bytes = await read(manifest.terminology.path);
  ensure(digest(bytes) === manifest.terminology.sha256 && String(bytes.length) === manifest.terminology.bytes, 'Terminology integrity mismatch');
  // Extra files must never hitchhike into a distributable release or a copy.
  const inventory = [];
  async function walk(dir, prefix='') {
    for (const entry of await readdir(dir,{withFileTypes:true})) {
      const path = prefix+entry.name;
      if (entry.isDirectory() && path === 'results') await walk(resolve(dir,entry.name),path+'/');
      else {ensure(entry.isFile(),'Unexpected directory or symlink'); inventory.push(path);}
    }
  }
  await walk(root);
  const expected = ['manifest.json',manifest.terminology.path,...manifest.outputs.map(p=>p.path)].sort();
  ensure(JSON.stringify(inventory.sort()) === JSON.stringify(expected), 'Unexpected or missing bundle files');
  return {...validateDocuments(manifest,documents,JSON.parse(bytes)), manifest_sha256:digest(manifestBytes)};
}
