import {readFile, readdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {describe, it, expect} from 'vitest';
import {renderToStaticMarkup} from 'react-dom/server';
import {canonical, sha256} from '../../contracts/src/index.mjs';
import {openCountBundle, type BundleFile} from '../src/file-provider';
import {CountView} from '../src/CountView';
import {measurementIds, savedScope, rawLabel} from '../src/measurement';

const base = process.env.MEASUREMENT_TEST_BUNDLES;
const signal = () => new AbortController().signal;
async function input(name: string) {
  const folder = resolve(base!, name), files = new Map<string, BundleFile>();
  const put = (path: string, bytes: Uint8Array) => files.set(path, {size: bytes.length, arrayBuffer: async () => bytes.slice().buffer as ArrayBuffer});
  for (const p of ['manifest.json', 'terminology.json', ...(await readdir(resolve(folder, 'results'))).map(n => `results/${n}`)]) put(p, await readFile(resolve(folder, p)));
  async function mutate(id: string, change: (doc: any) => void) {
    const manifest = JSON.parse(new TextDecoder().decode(await files.get('manifest.json')!.arrayBuffer()));
    const partition = manifest.outputs.find((p: any) => p.metric_id === id);
    const doc = JSON.parse(new TextDecoder().decode(await files.get(partition.path)!.arrayBuffer())); change(doc);
    const bytes = new TextEncoder().encode(canonical(doc)); put(partition.path, bytes);
    Object.assign(partition, {sha256: await sha256(bytes), bytes: String(bytes.length), rows: String(doc.rows?.length ?? 0), state: doc.state, reason: doc.reason});
    put('manifest.json', new TextEncoder().encode(canonical(manifest)));
  }
  return {files, mutate};
}
const request = {profile_id: 'alpha-measurement-v1', source_id: 'fixture:scope', measurement_concept_ids: [0, 900000001],
  window: {start: '2020-01-01', end: '2020-01-31'}, output_scope: 'restricted', disclosure_policy_id: 'synthetic-unsuppressed-v1'} as const;
it('only projects generated concepts/window without arbitrary joint filters', () => {
  const valid = {concept: '900000001', ...request.window, jointFilter: false};
  expect(savedScope(request, valid)).toEqual({available: true, concept: 900000001});
  expect(savedScope(request, {...valid, concept: '0'})).toEqual({available: true, concept: 0});
  for (const change of [{concept: '900000002'}, {concept: '9e8'}, {start: '2020-01-02'}, {end: '2020-02-01'}, {jointFilter: true}])
    expect(savedScope(request, {...valid, ...change})).toMatchObject({available: false});
});
describe.runIf(!!base)('real PostgreSQL measurement reference bundles', () => {
  it('opens all 15 independent oracle cases without an external terminology provider', async () => {
    const oracle = JSON.parse(await readFile(new URL('../../../tests/fixtures/analysis/alpha-oracle.json', import.meta.url), 'utf8'));
    for (const c of oracle.cases) for (const version of c.schema_versions) {
      const s = await input(`${c.id}-${version}`), r = await openCountBundle(s.files, signal());
      expect(r.count).toBe(c.expected.person_count); expect(r.measurement).toBeDefined();
      const records = r.measurement!.documents.get('measurement.record_count')!;
      expect(records.rows?.filter(row => 'period_kind' in row.dimensions && row.dimensions.period_kind === 'window').map(row => row.values)).toHaveLength(c.request.measurement_concept_ids.length);
      expect(r.measurement!.terminology).toMatchObject({provider_id: 'local-concept-table', vocabulary_release: {id: 'declared:fixture-1'}});
      expect(r.manifest.publication).toBe('partial'); expect(r.manifest.eligible_for_current_pointer).toBe(false);
    }
  });
  it('validates the maximum bounded request with all dense cells', async () => {
    const s = await input('maximum-bounded-request'), r = await openCountBundle(s.files, signal());
    expect(r.manifest.request.measurement_concept_ids).toHaveLength(10);
    expect(r.measurement!.documents.get('measurement.representation_count')?.rows).toHaveLength(9680);
    expect(r.measurement!.documents.get('measurement.numeric_eligibility_count')?.rows).toHaveLength(8470);
    expect(r.observation?.available && r.observation.months).toHaveLength(120);
  });
  it('renders all seven metric families, unknown concepts and local vocabulary context', async () => {
    const s = await input('tiny_a_2020-5.5'), r = await openCountBundle(s.files, signal());
    const html = renderToStaticMarkup(<CountView result={r}/>);
    for (const text of ['Measurement records', 'Distinct tested people', 'Result representations', 'Units as recorded', 'Operators as recorded', 'Numeric eligibility', 'Reference distributions', '100.5 / 6', 'declared:fixture-1', 'Unknown local concept · 999999999', 'including equality', 'Median · p50']) expect(html).toContain(text);
    expect(html).toContain('12 outputs'); // remaining unsupported outputs are explicit
  });
  it('retains precision above safe Number range and keeps units/operators separate', async () => {
    const s = await input('numeric-edges'), r = await openCountBundle(s.files, signal());
    const html = renderToStaticMarkup(<CountView result={r}/>);
    expect(html).toContain('9007199254740995.125 / 4'); expect(html).toContain('9007199254740993.125');
    expect(html).toContain('NULL · no explicit comparator'); expect(html).toContain('0 · no explicit comparator');
    expect(html).toContain('Unknown local concept · -1'); expect(html).toContain('Equals');
    const doc = r.measurement!.documents.get('measurement.numeric_summary'); expect(doc?.rows).toHaveLength(3);
  });
  it('preserves all representations and undefined zero-n statistics', async () => {
    const s = await input('representations'), r = await openCountBundle(s.files, signal());
    const doc = r.measurement!.documents.get('measurement.numeric_summary')!;
    expect(doc.rows?.find(row => 'unit_concept_id' in row.dimensions && row.dimensions.unit_concept_id === 900000103)).toMatchObject({state: 'empty_population', values: {n: '0', sum: null, mean_numerator: null, p50: null}});
    const html = renderToStaticMarkup(<CountView result={r}/>); expect(html).toContain('Statistics are undefined');
    expect(rawLabel(r.measurement!.terminology, 'id:900000001', 'unit')).toContain('invalid unit domain: Measurement');
  });
  it('distinguishes empty source, empty observation and observed people without selected records', async () => {
    for (const [name, state] of [['empty-source', 'empty_source'], ['empty-observation', 'empty_population'], ['unobserved-concept', 'computed']]) {
      const s = await input(name), r = await openCountBundle(s.files, signal());
      expect(r.measurement!.documents.get('measurement.record_count')?.state).toBe(state);
      expect(renderToStaticMarkup(<CountView result={r}/>)).toContain('No observed mapped-unit');
    }
  });
  it.each(['orphan','null-person','conflicting-terms','denied','denied-terminology','float-source','missing-column','unnamed-unit-1','unnamed-unit-2','unnamed-unit-3'])('shows %s as an unavailable measurement report without losing the passport/count', async name => {
    const s = await input(name), r = await openCountBundle(s.files, signal());
    expect(r.count).toBe('1'); const html = renderToStaticMarkup(<CountView result={r}/>);
    expect(html).toContain('Measurement report unavailable'); expect(html).not.toContain('Reference distributions');
  });
  it.each(measurementIds)('rejects a rehashed unsupported implemented partition: %s', async id => {
    const s = await input('tiny_a_2020-5.5');
    await s.mutate(id, doc => Object.assign(doc, {state: 'unsupported', reason: 'Not implemented', rows: null}));
    await expect(openCountBundle(s.files, signal())).rejects.toThrow('Implemented measurement output cannot be unsupported');
  });
  it('rejects an impossible exact sum after hashes and mean metadata have been updated', async () => {
    const s = await input('tiny_a_2020-5.5');
    await s.mutate('measurement.numeric_summary', doc => {doc.rows[0].values.sum = '-1000'; doc.rows[0].values.mean_numerator = '-1000';});
    await expect(openCountBundle(s.files, signal())).rejects.toThrow('Numeric sum outside exact n × min/max bounds');
  });
  it.each(['missing-representation','wrong-denominator','wrong-unit','numeric-n','quantile-order','missing-month','out-of-scope','empty-statistics'])('rejects rehashed semantic corruption: %s', async kind => {
    const s = await input('tiny_a_2020-5.5');
    const id = kind === 'missing-representation' ? 'measurement.representation_count' : kind === 'wrong-denominator' ? 'measurement.person_count' :
      kind === 'missing-month' || kind === 'out-of-scope' ? 'measurement.record_count' : 'measurement.numeric_summary';
    await s.mutate(id, d => {
      if (kind === 'missing-representation' || kind === 'missing-month') d.rows.pop();
      if (kind === 'wrong-denominator') d.rows[0].denominator.metric_id = 'person.count';
      if (kind === 'wrong-unit') d.rows[0].dimensions.unit_concept_id = 999999999;
      if (kind === 'numeric-n') {d.rows[0].values.n = '5'; d.rows[0].values.mean_denominator = '5'; d.rows[0].denominator.value = '5';}
      if (kind === 'quantile-order') d.rows[0].values.p50 = '-10';
      if (kind === 'out-of-scope') d.rows[0].dimensions.measurement_concept_id = 100;
      if (kind === 'empty-statistics') {d.rows[0].values.n = '0'; d.rows[0].state = 'empty_population'; d.rows[0].reason = 'Empty';}
    });
    await expect(openCountBundle(s.files, signal())).rejects.toThrow();
  });
});
