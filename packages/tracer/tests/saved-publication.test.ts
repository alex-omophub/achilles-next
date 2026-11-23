import {describe, expect, it} from 'vitest';
import {assertSamePublication, readCatalogue, readPeople, readReport} from '../src/saved-publication';

const base = new URL('http://127.0.0.1:12345/nested/view/api/');
const context = {
  contract_version: '2.0.0', source_id: 'fixture', release_id: 'release', publication_id: 'publication',
  access_scope_id: 'test', profile_id: 'core-characterization-v2', profile_sha256: 'a'.repeat(64),
  profile_revision: '2.0.0', authorization_epoch: '1', instance_id: 'first',
};
const signal = () => new AbortController().signal;
const reply = (body: unknown): typeof fetch => async () => Response.json(body);
const people = {
  context, generation_requested: false, state: 'available', reason_code: null, complete: true,
  cursor: null, transformations: 'none', dataset: {metric_id: 'core.person.count', state: 'computed'},
};
const row = (value: unknown) => ({row_kind: 'counts', state: 'computed', reason_code: null, values: {person_count: value}});

describe('saved publication browser reads', () => {
  it('preserves count strings beyond JavaScript integer precision and rejects a numeric representation', async () => {
    const exact = '9007199254740993';
    const read = (value: unknown) => readPeople(base, signal(), reply({...people, rows: [row(value)]}));
    expect((await read(exact)).count).toBe(exact);
    await expect(read(Number(exact))).rejects.toThrow();
  });
  it('preserves suppression and true empty-source zero as distinct outcomes', async () => {
    const hidden = await readPeople(base, signal(), reply({...people,
      state: 'suppressed', reason_code: 'policy.redacted', rows: [],
      dataset: {...people.dataset, state: 'suppressed', reason_code: 'policy.redacted'}}));
    expect(hidden).toMatchObject({state: 'suppressed', count: null});
    const zero = await readPeople(base, signal(), reply({...people,
      dataset: {...people.dataset, state: 'empty_source', reason_code: 'fixture.empty_source'},
      rows: [{...row('0'), state: 'empty_source', reason_code: 'fixture.empty_source'}]}));
    expect(zero).toMatchObject({state: 'empty_source', count: '0', reason: 'fixture.empty_source'});
  });
  it('delivers the opaque cursor unchanged under the selected viewer prefix', async () => {
    // Issued and accepted by listMetrics on the synthetic saved-result fixture.
    const cursor = [
      'eyJjb250ZXh0X3NoYTI1NiI6IjQwZTVmYmUyOWZjYTczYzUxYTcxNWRhZDY5ZWQyMmQ3M2UyODUyNmRhZmQ0MWJk',
      'ZDI2OTU2YzRjYzdkYTVlOWYiLCJnZW5lcmF0aW9uIjowLCJsYXN0X2tleSI6ImNvcmUuZGVhdGguZmlyc3RfYWdl',
      'X3N1bW1hcnkiLCJzZWxlY3Rpb25fc2hhMjU2IjoiOTMwZGZhZGZlOTkxMjAwMzg5YjgwY2M2MTE2ZWI2ZjU1YzM5',
      'ZDk1ZmE3ZjQyMDI1ODFlYmExMWFjNjg0NGMwNSIsInZlcnNpb24iOjF9Cg.88f582cb55385fd1da760f78c8b45',
      '6ee8b67bdcbb9d88f894cc2ca0acd4e3c76',
    ].join('');
    const page = await readCatalogue(base, cursor, signal(), async input => {
      const url = new URL(String(input));
      expect(url.pathname).toBe('/nested/view/api/catalogue.json');
      expect(url.searchParams.get('cursor')).toBe(cursor);
      return Response.json({context, generation_requested: false, state: 'available',
        metrics: [{metric_id: 'core.person.count', version: '1.0.0', rows: '1', state: 'computed'}],
        cursor: null, complete: true});
    });
    expect(page.metrics).toHaveLength(1);
    expect(() => assertSamePublication(page.context, {...context, authorization_epoch: '2'})).toThrow();
  });
  it('fails a response exceeding the byte budget even without a declared length', async () => {
    const huge: typeof fetch = async () => new Response(' '.repeat(1024 * 1024 + 1));
    await expect(readPeople(base, signal(), huge)).rejects.toThrow();
  });
});

describe('saved report transport', () => {
  const invalidResponse = 'The saved publication returned an invalid response.';
  const metric = 'core.visit.care_setting_count';
  const dataset = {metric_id: metric, version: '1.0.0', grain: 'concept/setting_kind/setting_concept_tag/full scope', population: 'all_recorded_rows',
    state: 'computed', reason_code: null};
  const selection = {metric_id: metric, metric_version: '1.0.0', population: dataset.population, row_kind: 'counts'};
  const report = {context, generation_requested: false, transformations: 'none', complete: true, cursor: null,
    state: 'available', reason_code: null, dataset, selection};
  const first = {row_key: 'a'.repeat(64), row_kind: 'counts', state: 'computed', reason_code: null,
    dimensions: {concept_tag: {kind: 'id', value: '9007199254740993'},
      setting_kind: 'place_of_service', setting_concept_tag: {kind: 'id', value: '234'}},
    values: {record_count: '9007199254740993', person_count: '0'}};
  it('requests only the selected saved metric and preserves typed tags and exact measures', async () => {
    const page = await readReport(base, metric, null, signal(), async input => {
      expect(String(input)).toBe(base.href + 'reports/core.visit.care_setting_count.json');
      return Response.json({...report, rows: [first]});
    });
    expect(page.rows[0]).toEqual(first);
    expect(page).toMatchObject({metric_id: metric, grain: dataset.grain, state: 'available', datasetState: 'computed'});
  });
  it('keeps a row-level reason even when the dataset was computed', async () => {
    const omitted = {...first, dimensions: {...first.dimensions, setting_concept_tag: {kind: 'schema_absent'}},
      state: 'unavailable', reason_code: 'capability.care_site_absent', values: null};
    const page = await readReport(base, metric, null, signal(), reply({...report, rows: [omitted]}));
    expect(page.rows[0]).toEqual(omitted);
    await expect(readReport(base, metric, null, signal(), reply({...report, rows: [{...omitted, values: first.values}]})))
      .rejects.toThrow(invalidResponse);
  });
  it('rejects inconsistent identities, oversized row pages and numeric JSON measures', async () => {
    for (const invalid of [
      {...report, selection: {...selection, metric_id: 'core.person.count'}, rows: [first]},
      {...report, selection: {...selection, metric_version: '2.0.0'}, rows: [first]},
      {...report, selection: {...selection, population: 'observed_rows'}, rows: [first]},
      {...report, dataset: {...dataset, metric_id: 'core.person.count'}, rows: [first]},
      {...report, rows: [{...first, row_kind: 'summary'}]},
      {...report, rows: Array(13).fill(first)},
      {...report, rows: [{...first, values: {person_count: 1}}]},
    ]) await expect(readReport(base, metric, null, signal(), reply(invalid))).rejects.toThrow(invalidResponse);
  });
  it('follows the report continuation returned by the first page', async () => {
    const metricId = 'core.person.gender_count';
    // Issued by the synthetic gender-count provider and verified against its second page.
    const nextCursor = [
      'eyJjb250ZXh0X3NoYTI1NiI6IjM1ZDQ4ODYzZmYzNDE2YzU1ODIxZDk3NGMzMzJhMzc4YTNmMDY0ZmFlYTE3YTA4',
      'MWEzOGQxNTkzMDc4ODMwYzkiLCJnZW5lcmF0aW9uIjowLCJsYXN0X2tleSI6ImNvcmUucGVyc29uLmdlbmRlcl9j',
      'b3VudHxJMTAwMDAwMzoxMTB8RTpjb3VudHMiLCJzZWxlY3Rpb25fc2hhMjU2IjoiOGYwNWFmNmQ5MTUwZGM5Mzg2',
      'NDQwMzdhZmYzOWY1MGNmZTFlNWRlZWZhYWJiYTE3MTgwZTA2YTc0OWExOGI3NSIsInZlcnNpb24iOjF9Cg.9f781',
      '6992ab53056854507dfa49901bc130e8bfe173f20f84d62b90f24776626',
    ].join('');
    const genderDataset = {...dataset, metric_id: metricId, population: 'person_table', grain: 'person/gender_concept_id'};
    const genderSelection = {...selection, metric_id: metricId, population: genderDataset.population};
    const genderRow = {...first, dimensions: {gender_concept_id: '100'}, values: {person_count: '0'}};
    const envelope = {...report, dataset: genderDataset, selection: genderSelection, rows: [genderRow]};
    const firstPage = await readReport(base, metricId, null, signal(), reply({...envelope, complete: false, cursor: nextCursor}));
    expect(firstPage.cursor).toBe(nextCursor);
    const secondPage = await readReport(base, metricId, firstPage.cursor, signal(), async input => {
      const url = new URL(String(input));
      expect(url.pathname).toBe('/nested/view/api/reports/core.person.gender_count.json');
      expect([...url.searchParams]).toEqual([['cursor', nextCursor]]);
      return Response.json({...envelope, rows: [{...genderRow, row_key: 'b'.repeat(64), dimensions: {gender_concept_id: '111'}}]});
    });
    expect(secondPage.cursor).toBeNull();
    expect(secondPage.rows[0].dimensions.gender_concept_id).toBe('111');
  });
});
