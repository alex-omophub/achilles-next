import {readFile, readdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {describe, it, expect} from 'vitest';
import {renderToStaticMarkup} from 'react-dom/server';
import {canonical, sha256} from '../../contracts/src/index.mjs';
import {openCountBundle, type BundleFile} from '../src/file-provider';
import {CountView} from '../src/CountView';

const base = process.env.OBSERVATION_TEST_BUNDLES;
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
describe.runIf(!!base)('actual PostgreSQL observation bundles', () => {
  it('preserves all 15 independent oracle cases through the provider', async () => {
    const oracle = JSON.parse(await readFile(new URL('../../../tests/fixtures/analysis/alpha-oracle.json', import.meta.url), 'utf8'));
    for (const c of oracle.cases) for (const version of c.schema_versions) {
      const s = await input(`${c.id}-${version}`), r = await openCountBundle(s.files, signal());
      expect(r.count).toBe(c.expected.person_count);
      expect(r.observation?.available).toBe(true);
      if (!r.observation?.available) throw new Error('Missing observation results');
      expect(r.observation.people).toBe(c.expected.observed_people); expect(r.observation.personDays).toBe(c.expected.person_days);
      expect(Object.fromEntries(r.observation.months.map(m => [m.month, m.count]))).toEqual(c.expected.observed_people_by_month);
    }
  });
  it.each(['0001-01-01', '9999-12-31'])('preserves Gregorian calendar boundary %s', async date => {
    const s = await input(`calendar-${date}`), r = await openCountBundle(s.files, signal());
    expect(r.observation).toMatchObject({available: true, people: '0', personDays: '0', months: [{month: date.slice(0, 7) + '-01', count: '0'}]});
  });
  it('renders observation grain, exact values and clinical interpretation separately', async () => {
    const s = await input('tiny_a_2020-5.5'), r = await openCountBundle(s.files, signal());
    const html = renderToStaticMarkup(<CountView result={r}/>);
    for (const text of ['All-source people', 'Observed people in window', 'Unique observed person-days', 'Exact monthly values', 'Monthly people are not additive', 'does not establish claims enrollment', '2020-01-01', '2020-12-31']) expect(html).toContain(text);
    expect(r.observation).toMatchObject({people: '3', personDays: '24'});
  });
  it('keeps empty observation distinct from empty source', async () => {
    for (const [name, state, all] of [['empty-observation', 'empty_population', '2'], ['empty-source', 'empty_source', '0']]) {
      const s = await input(name), r = await openCountBundle(s.files, signal());
      expect(r.count).toBe(all); expect(r.observation).toMatchObject({available: true, state, people: '0', personDays: '0'});
    }
  });
  it.each(['invalid-1','invalid-2','invalid-3','invalid-4','invalid-5','denied-observation','missing-column','wrong-date-type'])('shows %s without fabricated observation values', async name => {
    const s = await input(name), r = await openCountBundle(s.files, signal());
    expect(r.count).toBe('2'); expect(r.observation).toMatchObject({available: false});
    const html = renderToStaticMarkup(<CountView result={r}/>);
    expect(html).toContain('Observation opportunity unavailable'); expect(html).not.toContain('Unique observed person-days');
  });
  it.each(['missing-month','wrong-denominator','excess-people','false-zero'])('rejects rehashed semantic corruption: %s', async kind => {
    const s = await input('tiny_a_2020-5.5');
    await s.mutate(kind === 'excess-people' ? 'observation.person_count' : 'observation.monthly_person_count', d => {
      if (kind === 'missing-month') d.rows.pop();
      if (kind === 'wrong-denominator') d.rows[0].denominator.metric_id = 'observation.person_count';
      if (kind === 'excess-people') d.rows[0].values.count = '5';
      if (kind === 'false-zero') d.rows[0].values.count = '0';
    });
    await expect(openCountBundle(s.files, signal())).rejects.toThrow('Observation results:');
  });
  it('retains huge exact values and omits unsafe chart coordinates', async () => {
    const s = await input('tiny_a_january_partial-5.5'), huge = '9007199254740993';
    await s.mutate('person.count', d => {d.rows[0].values.count = huge;});
    for (const id of ['observation.person_count','observation.monthly_person_count','observation.person_days']) {
      await s.mutate(id, d => {
        d.rows[0].values.count = id.endsWith('person_days') ? String(BigInt(huge) * 20n) : huge;
        if (d.rows[0].denominator) d.rows[0].denominator.value = huge;
      });
    }
    const r = await openCountBundle(s.files, signal());
    expect(r.observation).toMatchObject({people: huge});
    const html = renderToStaticMarkup(<CountView result={r}/>);
    expect(html).toContain(huge); expect(html).toContain('Counts exceed safe chart coordinates');
  });
});
