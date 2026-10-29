// Build first; copy immutable release assets into the R package, with provenance.
import {readFile, writeFile, readdir, mkdir, rm} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {resolve, relative, join} from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const root = fileURLToPath(new URL('../../../', import.meta.url));
const project = resolve(root, 'packages/tracer');
const out = resolve(root, 'inst/viewer');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
async function walk(dir) {
  const paths = [];
  for (const entry of await readdir(dir, {withFileTypes: true})) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) paths.push(...await walk(path));
    else if (entry.isFile()) paths.push(path);
    else throw new Error('Release assets cannot contain symlinks');
  }
  return paths.sort();
}
try {
  const existing = JSON.parse(await readFile(join(out, 'viewer-lock.json'), 'utf8'));
  if (existing.generated_by !== 'achilles-next-package-viewer') throw new Error('Unrecognized output directory');
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
  // Never remove an existing, unowned directory just because its lock is absent.
  try {if ((await readdir(out)).length) throw new Error('Output directory has no viewer ownership lock');}
  catch (missing) {if (missing.code !== 'ENOENT') throw missing;}
}
await rm(out, {recursive: true, force: true});
await mkdir(out, {recursive: true});
for (const path of await walk(resolve(project, 'dist'))) {
  const target = join(out, relative(resolve(project, 'dist'), path));
  await mkdir(resolve(target, '..'), {recursive: true});
  await writeFile(target, await readFile(path));
}
const installed = execFileSync('npm', ['ls', '--omit=dev', '--all', '--parseable'], {cwd: project, encoding: 'utf8'}).trim().split('\n').slice(1);
const notices = [];
for (const dir of installed) {
  const pkg = JSON.parse(await readFile(join(dir, 'package.json'), 'utf8'));
  const name = (await readdir(dir)).find(n => /^licen[cs]e(\.(txt|md))?$/i.test(n));
  if (!name) throw new Error(`Missing distribution license for ${pkg.name}`);
  const extra = (await readdir(dir)).filter(n => /^notice(\.(txt|md))?$/i.test(n)).sort();
  const texts = await Promise.all([name, ...extra].map(n => readFile(join(dir, n), 'utf8')));
  notices.push(`${pkg.name}@${pkg.version}\n${texts.join('\n').replace(/\r\n?/g, '\n').replace(/[ \t]+$/gm, '').trimEnd()}`);
}
await writeFile(join(out, 'DEPENDENCY-LICENSES.txt'), notices.sort().join('\n\n---\n\n') + '\n');
const inputs = [
  ...(await walk(resolve(project, 'src'))).filter(p => !p.endsWith('generated-validation.mjs')),
  ...await walk(resolve(project, 'tools')),
  ...['package.json', 'package-lock.json', 'index.html', 'tsconfig.json', 'vite.config.ts'].map(p => join(project, p)),
  ...['inst/analysis/alpha-measurement-v1.json', 'inst/contracts/v1/contract.schema.json',
    'packages/contracts/src/index.mjs', 'packages/contracts/src/http-provider.mjs'].map(p => resolve(root, p)),
];
const source_sha256 = {};
for (const path of inputs.sort()) source_sha256[relative(root, path)] = hash(await readFile(path));
const files = {};
for (const path of await walk(out)) files[relative(out, path)] = hash(await readFile(path));
await writeFile(join(out, 'viewer-lock.json'), JSON.stringify({format_version: 1,
  generated_by: 'achilles-next-package-viewer', scope: 'partial-count-observation-tracer', source_sha256, files}, null, 2) + '\n');
console.log(`Packaged ${Object.keys(files).length} prebuilt viewer files with source and asset hashes.`);
