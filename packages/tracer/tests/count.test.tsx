import {readFile, readdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {renderToStaticMarkup} from 'react-dom/server';
import {describe, it, expect} from 'vitest';
import {canonical, sha256} from '../../contracts/src/index.mjs';
import {openCountBundle, selectedBundleFiles, type BundleFile} from '../src/file-provider';
import {CountView} from '../src/CountView';

const root = resolve(import.meta.dirname, '../../..');
const signal = () => new AbortController().signal;
function file(bytes: Uint8Array): BundleFile {
  return {size: bytes.length, arrayBuffer: async () => bytes.slice().buffer as ArrayBuffer};
}
async function filesAt(path: string): Promise<Map<string, BundleFile>> {
  const names = ['manifest.json', 'terminology.json', ...(await readdir(resolve(path, 'results'))).map(n => `results/${n}`)];
  return new Map(await Promise.all(names.map(async name => [name, file(await readFile(resolve(path, name)))] as const)));
}
// Clearly synthetic test input. Production generation never reads these answers.
async function sample(count = '9007199254740993', state = 'computed') {
  const path = resolve(root, 'tests/fixtures/contracts/complete');
  const manifest = JSON.parse(await readFile(resolve(path, 'manifest.json'), 'utf8'));
  manifest.publication = 'partial'; manifest.eligible_for_current_pointer = false;
  manifest.generator.name = 'AchillesNext-count-tracer';
  manifest.source.snapshot = {state: 'unknown', id: null, reason: 'Synthetic test', immutable: false, assertion_id: null, basis: null};
  manifest.reproducibility.consistent_snapshot = false; manifest.reproducibility.limitation = 'Synthetic test; no reusable snapshot';
  manifest.disclosure.applied = false; manifest.disclosure.approval_id = null;
  const files = new Map<string, BundleFile>();
  const put = (name: string, doc: unknown) => {const bytes = new TextEncoder().encode(canonical(doc)); files.set(name, file(bytes)); return bytes;};
  for (const p of manifest.outputs) {
    const doc = JSON.parse(await readFile(resolve(path, p.path), 'utf8'));
    if (p.metric_id === 'source.passport') doc.rows[0].values.source_snapshot_id = null;
    else if (p.metric_id === 'person.count') {
      doc.state = state; doc.reason = state === 'computed' ? null : 'Accessible source is empty';
      doc.rows[0].state = state; doc.rows[0].reason = doc.reason; doc.rows[0].values.count = count;
    } else {doc.state = 'unsupported'; doc.reason = 'Not implemented in synthetic tracer test'; doc.rows = null;}
    p.state = doc.state; p.reason = doc.reason; p.rows = String(doc.rows?.length ?? 0);
    const bytes = put(p.path, doc); p.sha256 = await sha256(bytes); p.bytes = String(bytes.length);
  }
  const term = JSON.parse(await readFile(resolve(path, 'terminology.json'), 'utf8')); term.concepts = [];
  const termBytes = put('terminology.json', term); manifest.terminology.sha256 = await sha256(termBytes); manifest.terminology.bytes = String(termBytes.length);
  put('manifest.json', manifest);
  return {files, manifest, put};
}

describe('count tracer file/provider/view boundary', () => {
  it('keeps an exact count above Number safe range through bytes and React', async () => {
    const {files} = await sample(); const result = await openCountBundle(files, signal());
    expect(result.count).toBe('9007199254740993');
    const html = renderToStaticMarkup(<CountView result={result}/>);
    expect(html).toContain('9007199254740993'); expect(html).toContain('Partial development result');
    expect(html).toContain('fixture:tiny_a'); expect(html).toContain('person.count');
    const bytes = await result.provider.getResult(result.context, 'person.count', {signal: signal(), requestId: 'read'});
    bytes.fill(0); // callers cannot mutate retained provider bytes
    expect((await result.provider.getResult(result.context, 'person.count', {signal: signal(), requestId: 'again'}))[0]).toBe(123);
  });
  it('shows true empty source as exact zero with an explicit state', async () => {
    const {files} = await sample('0', 'empty_source'); const result = await openCountBundle(files, signal());
    expect(result.state).toBe('empty_source'); expect(renderToStaticMarkup(<CountView result={result}/>)).toContain('Empty source');
  });
  it('rejects a forged complete pointer, even with otherwise well-formed documents', async () => {
    const s = await sample(); s.manifest.publication = 'complete'; s.manifest.eligible_for_current_pointer = true; s.put('manifest.json', s.manifest);
    await expect(openCountBundle(s.files, signal())).rejects.toThrow('Complete bundle has incomplete outputs or unapplied disclosure policy');
  });
  it('rejects tampering, missing files, unsafe numeric values and impossible count states', async () => {
    const tampered = await sample(); tampered.put('results/person.count.json', {});
    await expect(openCountBundle(tampered.files, signal())).rejects.toThrow('integrity');
    const missing = await sample(); missing.files.delete('results/person.count.json');
    await expect(openCountBundle(missing.files, signal())).rejects.toThrow('missing');
    const unsafe = await sample(9007199254740992 as unknown as string);
    await expect(openCountBundle(unsafe.files, signal())).rejects.toThrow('typed fields');
    const wrongZero = await sample('0');
    await expect(openCountBundle(wrongZero.files, signal())).rejects.toThrow('state or grain');
  });
  it('rejects source/context substitution and cancelled reads', async () => {
    const s = await sample(); s.manifest.request.source_id = 'another-source'; s.manifest.request_sha256 = await sha256(canonical(s.manifest.request)); s.put('manifest.json', s.manifest);
    await expect(openCountBundle(s.files, signal())).rejects.toThrow('identity mismatch');
    const good = await sample(); const result = await openCountBundle(good.files, signal());
    await expect(result.provider.getManifest({...result.context, source_id: 'other'}, {signal: signal(), requestId: 'wrong'})).rejects.toThrow('CONTEXT');
    const aborted = new AbortController(); aborted.abort();
    await expect(result.provider.getManifest(result.context, {signal: aborted.signal, requestId: 'abort'})).rejects.toThrow();
  });
  it('rejects ambiguous folder paths', () => {
    expect(() => selectedBundleFiles([{name: 'manifest.json', webkitRelativePath: 'bundle/../manifest.json', ...file(new Uint8Array())}])).toThrow();
    expect(() => selectedBundleFiles([{name: 'manifest.json', webkitRelativePath: '/manifest.json', ...file(new Uint8Array())}])).toThrow();
  });
  it.runIf(!!process.env.TRACER_TEST_BUNDLES)('opens actual R-generated counts for both sources on all three versions', async () => {
    const path = process.env.TRACER_TEST_BUNDLES!;
    for (const version of ['5.3', '5.4', '5.5']) for (const source of ['a', 'b']) {
      const files = await filesAt(resolve(path, `${source}-${version}`));
      const result = await openCountBundle(files, signal());
      expect(result.count).toBe(source === 'a' ? '4' : '2');
      expect(result.manifest.source.declared_cdm_version).toBe(version);
      expect(result.manifest.source.source_id).toBe(`fixture:tiny_${source}`);
    }
    expect((await openCountBundle(await filesAt(resolve(path, 'empty')), signal())).state).toBe('empty_source');
  });
});
