// One bounded, ordinary-file inventory for producer and installed validation.
import {readFile, lstat, realpath, opendir} from 'node:fs/promises';
import {resolve, sep} from 'node:path';
import {createHash} from 'node:crypto';
import {ensure} from './semantics.mjs';
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const decode = bytes => JSON.parse(new TextDecoder('utf-8', {fatal:true}).decode(bytes));
// Stream entries with a fixed-size buffer, retaining only the declared paths.
export async function validateInventory(root, expected, openDirectory = opendir) {
  const remaining = new Set(expected);
  ensure(remaining.size === expected.length, 'Duplicate artifact paths');
  let files = 0;
  async function walk(dir, prefix='') {
    for await (const entry of await openDirectory(dir,{bufferSize:32})) {
      const path = prefix+entry.name;
      if (entry.isDirectory() && path === 'results') await walk(resolve(dir,entry.name),path+'/');
      else {
        ensure(entry.isFile() && remaining.delete(path) && ++files <= expected.length, 'Unexpected bundle entry');
      }
    }
  }
  await walk(root);
  ensure(remaining.size === 0, 'Missing bundle files');
}
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
  const manifest = decode(manifestBytes); validateDocument('bundle',manifest);
  const documents = new Map();
  for (const p of manifest.outputs) {
    const bytes = await read(p.path);
    ensure(digest(bytes) === p.sha256 && String(bytes.length) === p.bytes, 'Partition integrity mismatch');
    documents.set(p.metric_id,decode(bytes));
  }
  const bytes = await read(manifest.terminology.path);
  ensure(digest(bytes) === manifest.terminology.sha256 && String(bytes.length) === manifest.terminology.bytes, 'Terminology integrity mismatch');
  // Extra files must never hitchhike into a distributable release or a copy.
  await validateInventory(root,['manifest.json',manifest.terminology.path,...manifest.outputs.map(p=>p.path)]);
  return {...validateDocuments(manifest,documents,decode(bytes)), manifest_sha256:digest(manifestBytes)};
}
