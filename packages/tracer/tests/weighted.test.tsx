import {readFile, readdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {it, expect} from 'vitest';
import {canonical, sha256} from '../../contracts/src/index.mjs';
import {openCountBundle, openServedCountBundle, type BundleFile} from '../src/file-provider';
const root = process.env.WEIGHTED_TEST_BUNDLES;
const reference = process.env.MEASUREMENT_TEST_BUNDLES;
const signal = () => new AbortController().signal;
async function filesAt(root: string, name: string) {
  const folder = resolve(root, name), files = new Map<string, BundleFile>();
  for (const p of ['manifest.json', 'terminology.json', ...(await readdir(resolve(folder, 'results'))).map(n => `results/${n}`)]) {
    const bytes = await readFile(resolve(folder, p));
    files.set(p, {size: bytes.length, arrayBuffer: async () => bytes.slice().buffer as ArrayBuffer});
  }
  return files;
}
it.runIf(!!root && !!reference)('all weighted generated bundles preserve reference metric payloads and typed failure states', async () => {
  for (const name of await readdir(root!)) {
    const r = await openCountBundle(await filesAt(root!, name), signal());
    const ref = await openCountBundle(await filesAt(reference!, name), signal());
    expect(r.manifest.generator.name).toBe('AchillesNext-measurement-weighted');
    expect(r.manifest.profile).toEqual(ref.manifest.profile);
    expect(r.manifest.request_sha256).toBe(ref.manifest.request_sha256);
    expect(r.count).toBe(ref.count); expect(r.observation).toEqual(ref.observation);
    for (const [id, d] of r.measurement!.documents) {
      if (id === 'source.passport') continue; // Run identity is deliberately different.
      const expected = ref.measurement!.documents.get(id)!;
      expect({state: d.state, reason: d.reason, rows: d.rows}).toEqual({state: expected.state, reason: expected.reason, rows: expected.rows});
    }
    expect(r.manifest.publication).toBe('partial'); expect(r.manifest.eligible_for_current_pointer).toBe(false);
  }
}, 15000);
it.runIf(!!root)('weighted output opens through the same non-root served provider', async () => {
  const files = await filesAt(root!, 'tiny_a_2020-5.5');
  const base = new URL('http://127.0.0.1:1234/nested/results/api/');
  const fetcher = async (input: RequestInfo | URL) => {
    const path = new URL(String(input)).pathname.replace('/nested/results/api/', '');
    if (path === 'status.json') return new Response(JSON.stringify({state: 'ready'}));
    const f = files.get(path); return f ? new Response(await f.arrayBuffer()) : new Response('', {status: 404});
  };
  const r = await openServedCountBundle(base, signal(), fetcher as typeof fetch);
  expect(r.measurement?.documents.get('measurement.numeric_summary')?.rows?.[0].values).toMatchObject({n: '6', sum: '100.5', p50: '1'});
});
it.runIf(!!root)('weighted generator cannot forge unsupported implemented outputs', async () => {
  const files = await filesAt(root!, 'tiny_a_2020-5.5');
  const read = async (p: string) => JSON.parse(new TextDecoder().decode(await files.get(p)!.arrayBuffer()));
  const m = await read('manifest.json'), p = m.outputs.find((p: {metric_id: string}) => p.metric_id === 'measurement.numeric_summary');
  const doc = await read(p.path); Object.assign(doc, {state: 'unsupported', reason: 'Not implemented', rows: null});
  const put = (path: string, value: unknown) => {const bytes = new TextEncoder().encode(canonical(value)); files.set(path, {size: bytes.length, arrayBuffer: async () => bytes.slice().buffer}); return bytes;};
  const bytes = put(p.path, doc); Object.assign(p, {sha256: await sha256(bytes), bytes: String(bytes.length), rows: '0', state: doc.state, reason: doc.reason}); put('manifest.json', m);
  await expect(openCountBundle(files, signal())).rejects.toThrow('Implemented measurement output cannot be unsupported');
});
