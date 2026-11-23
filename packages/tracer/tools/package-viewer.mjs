// Build first; copy immutable release assets into the R package, with provenance.
import {readFile, writeFile, readdir, mkdir, rm} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {resolve, relative, join} from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const root = fileURLToPath(new URL('../../../', import.meta.url));
const project = resolve(root, 'packages/tracer');
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
const licenses = notices.sort().join('\n\n---\n\n') + '\n';
const inputs = [
  ...(await walk(resolve(project, 'src'))).filter(p => !p.endsWith('generated-validation.mjs')),
  ...await walk(resolve(project, 'tools')),
  ...['package.json', 'package-lock.json', 'index.html', 'tsconfig.json', 'vite.config.ts', 'vite.embed.config.ts'].map(p => join(project, p)),
  ...['inst/analysis/alpha-measurement-v1.json', 'inst/contracts/v1/contract.schema.json', 'inst/contracts/v1.1/contract.schema.json',
    'packages/contracts/src/directory.mjs',
    'packages/contracts/src/semantics.mjs', 'packages/contracts/src/index.mjs', 'packages/contracts/src/http-provider.mjs'].map(p => resolve(root, p)),
];
const source_sha256 = {};
for (const path of inputs.sort()) source_sha256[relative(root, path)] = hash(await readFile(path));
async function install(name, scope, artifacts) {
  const out = resolve(root, 'inst', name);
  const lock = name + '-lock.json';
  const generator = 'achilles-next-package-' + name;
  try {
    const existing = JSON.parse(await readFile(join(out, lock), 'utf8'));
    if (existing.generated_by !== generator) throw new Error('Unrecognized output directory: ' + name);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    // Never replace a nonempty directory unless it has this tool's ownership lock.
    try {if ((await readdir(out)).length) throw new Error('Missing ownership lock: ' + name);}
    catch (missing) {if (missing.code !== 'ENOENT') throw missing;}
  }
  await rm(out, {recursive: true, force: true});
  await mkdir(out, {recursive: true});
  for (const [file, source] of artifacts) {
    const target = join(out, file);
    await mkdir(resolve(target, '..'), {recursive: true});
    await writeFile(target, await readFile(source));
  }
  await writeFile(join(out, 'DEPENDENCY-LICENSES.txt'), licenses);
  const files = {};
  for (const path of await walk(out)) files[relative(out, path)] = hash(await readFile(path));
  await writeFile(join(out, lock), JSON.stringify({format_version: 1,
    generated_by: generator, scope, source_sha256, files}, null, 2) + '\n');
  console.log(`Packaged ${Object.keys(files).length} ${name} files with source and asset hashes.`);
}
async function artifacts(folder) {
  const dist = resolve(project, folder);
  return (await walk(dist)).map(path => [relative(dist, path), path]);
}
await install('viewer', 'v1-tracers-and-v2-core-reports', await artifacts('dist'));
// The mount injects its CSS into each shadow root. The detached stylesheet
// emitted for users of the React source entry would style the host document.
const embed = (await artifacts('build/embed')).filter(([file]) => file !== 'workspace.css');
const declarations = resolve(project, 'build/declarations/packages/tracer/src');
embed.push(['publication-workspace.d.mts', join(declarations, 'mount-publication.d.ts')],
  ['saved-publication.d.ts', join(declarations, 'saved-publication.d.ts')]);
await install('embed', 'v2-core-publication-workspace', embed);
