import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';
import {renderToStaticMarkup} from 'react-dom/server';
import {expect, it} from 'vitest';
import {openServedCountBundle} from '../src/file-provider';
import {CountView} from '../src/CountView';
import {ResultError} from '../src/ViewerApp';

const base = new URL('http://127.0.0.1:4000/nested/results-view/api/');
const signal = () => new AbortController().signal;
it.each(['missing', 'invalid', 'incompatible'] as const)('keeps %s explicit and renders an actionable error without a count', async state => {
  const fetcher = async () => new Response(JSON.stringify({state, message: 'Selected results cannot be opened'}));
  await expect(openServedCountBundle(base, signal(), fetcher as typeof fetch)).rejects.toMatchObject({state});
  const html = renderToStaticMarkup(<ResultError state={state} message="Selected results cannot be opened"/>);
  expect(html).toContain(`data-state="${state}"`); expect(html).not.toContain('Exact person count');
  if (state === 'incompatible') expect(html).toContain('measurement reference/weighted bundle');
});
it('names both measurement strategies when served status has no recovery message', async () => {
  const fetcher = async () => new Response(JSON.stringify({state: 'incompatible'}));
  await expect(openServedCountBundle(base, signal(), fetcher as typeof fetch)).rejects.toThrow('measurement reference/weighted bundle');
});
it('distinguishes malformed manifest bytes from an unreachable local server', async () => {
  let count = 0;
  const malformed = async () => new Response(count++ === 0 ? '{"state":"ready"}' : 'null');
  await expect(openServedCountBundle(base, signal(), malformed as typeof fetch)).rejects.toMatchObject({state: 'invalid'});
  const down = async () => {throw new TypeError('network unavailable');};
  await expect(openServedCountBundle(base, signal(), down as typeof fetch)).rejects.toMatchObject({state: 'unavailable'});
});
it.runIf(!!process.env.TRACER_TEST_BUNDLES)('serves the actual R bundle on a non-root base through the common verifier', async () => {
  const folder = resolve(process.env.TRACER_TEST_BUNDLES!, 'a-5.5');
  const reads: string[] = [];
  const fetcher = async (input: string | URL | Request) => {
    const url = new URL(String(input));
    expect(url.href.startsWith(base.href)).toBe(true);
    const path = url.pathname.slice(base.pathname.length); reads.push(path);
    return new Response(path === 'status.json' ? '{"state":"ready"}' : await readFile(resolve(folder, path)));
  };
  const result = await openServedCountBundle(base, signal(), fetcher as typeof fetch);
  expect(result.count).toBe('4'); expect(reads).toHaveLength(18);
  expect(renderToStaticMarkup(<CountView result={result}/>)).toContain('fixture:tiny_a');
});

it('runs precompiled validators through native ESM CommonJS interop', () => {
  const script = `
    import {readFileSync} from 'node:fs';
    import {bundle, result, terminology} from './src/generated-validation.mjs';
    const read = path => JSON.parse(readFileSync('../../tests/fixtures/contracts/complete/' + path));
    const manifest = read('manifest.json');
    if (!bundle(manifest) || !result(read('results/person.count.json')) || !terminology(read('terminology.json')))
      throw new Error('Native ESM validator rejected a valid fixture');
    manifest.request.window.start = '2024-02-30';
    if (bundle(manifest)) throw new Error('Invalid calendar date accepted');
  `;
  execFileSync(process.execPath, ['--input-type=module', '-e', script]);
});
