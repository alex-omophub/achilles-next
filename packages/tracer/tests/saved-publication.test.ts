import {describe, expect, it} from 'vitest';
import {assertSamePublication, readCatalogue, readPeople, readReport, selectReport, searchConcepts, lookupConcept} from '../src/saved-publication';

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
    state: 'computed', reason_code: null, definition_sha256: 'd'.repeat(64)};
  const selection = {metric_id: metric, metric_version: '1.0.0', population: dataset.population, row_kind: 'counts', filters: {}};
  const report = {context, generation_requested: false, transformations: 'none', complete: true, cursor: null,
    state: 'available', reason_code: null, dataset, selection, dependencies: []};
  const first = {row_key: 'a'.repeat(64), row_kind: 'counts', state: 'computed', reason_code: null,
    dimensions: {concept_tag: {kind: 'id', value: '9007199254740993'},
      setting_kind: 'place_of_service', setting_concept_tag: {kind: 'id', value: '234'}},
    values: {record_count: '9007199254740993', person_count: '0'}, denominator_refs: []};
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
  it('keeps exact verified denominator evidence and rejects absent or inconsistent targets', async () => {
    const ref = {measure: 'person_count', metric_id: 'core.person.count', row_key: 'b'.repeat(64),
      field: 'person_count', value: '9007199254740993'};
    const target = {metric_id: ref.metric_id, metric_version: '1.0.0', row: {...first, row_key: ref.row_key,
      dimensions: {}, values: {person_count: ref.value}}};
    const body = {...report, rows: [{...first, denominator_refs: [ref]}], dependencies: [target]};
    const result = await readReport(base, metric, null, signal(), reply(body));
    expect(result.rows[0].denominator_refs).toEqual([ref]);
    expect(result.evidence).toEqual({definitionSha256: dataset.definition_sha256, dependencies: [target]});
    for (const invalid of [[], [target, target], [{...target, row: {...target.row, values: {person_count: '0'}}}]]) {
      await expect(readReport(base, metric, null, signal(), reply({...body, dependencies: invalid}))).rejects.toThrow(invalidResponse);
    }
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
  it('binds filter capabilities to the metric version, population and selected row kind', async () => {
    const capability = {metric_id: metric, metric_version: dataset.version, population: dataset.population, row_kinds: ['counts'],
      concept: 'exact_saved_tag', time: 'not_saved', unit: 'not_saved', operator: 'not_saved', period_kinds: [],
      period_bounds: {full_scope: 'not_saved', calendar: 'not_saved'}};
    const read = (value: unknown) => readReport(base, metric, null, signal(), reply({...report, rows: [first], capability: value}));
    expect((await read(capability)).capability?.concept).toBe('exact_saved_tag');
    for (const change of [{metric_id: 'core.person.count'}, {metric_version: '2'}, {population: 'other'}, {row_kinds: ['summary']}]) {
      await expect(read({...capability, ...change})).rejects.toThrow(invalidResponse);
    }
  });
  it('binds the response to exact saved filters and keeps a native unsupported-state reason', async () => {
    const filters = {period_kind: 'calendar_month', period_start: '2020-01-01', period_end: '2020-01-31'};
    const response = {...report, rows: [], state: 'additional_batch_job_required', reason_code: 'selection.dimensions_not_saved',
      selection: {...selection, filters}};
    const selected = await selectReport(base, metric, filters, null, signal(), async input => {
      expect(JSON.parse(new URL(String(input)).searchParams.get('filters')!)).toEqual(filters);
      return Response.json(response);
    });
    expect(selected).toMatchObject({state: 'additional_batch_job_required', reason: 'selection.dimensions_not_saved', rows: []});
    await expect(selectReport(base, metric, filters, null, signal(), reply({...response, selection}))).rejects.toThrow(invalidResponse);
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

describe('saved terminology transport', () => {
  const missing = {state: 'unavailable', reason_code: 'terminology.name_index_not_saved', context, generation_requested: false,
    concepts: [], searched: false, complete: true, cursor: null};
  it('preserves the search text and returns an explicit missing index', async () => {
    const query = 'A+B & C';
    const page = await searchConcepts(base, query, null, signal(), async input => {
      const url = new URL(String(input));
      expect(url.pathname).toBe('/nested/view/api/concepts/search.json');
      expect([...url.searchParams]).toEqual([['q', query]]);
      return Response.json({...missing, query});
    });
    expect(page).toMatchObject({state: 'unavailable', reason: 'terminology.name_index_not_saved', concepts: []});
    await expect(searchConcepts(base, query, null, signal(), reply({...missing, query: 'another prefix'})))
      .rejects.toThrow('The saved publication returned an invalid response.');
  });
  it('keeps exact identifiers and distinguishes a saved ID without a label from an absent ID', async () => {
    const id = '9007199254740993';
    const item = {concept_tag: {kind: 'id', value: id}, label: null, label_state: 'unavailable',
      state: 'available', reason_code: null, label_reason_code: 'terminology.id_not_in_snapshot'};
    const envelope = {state: 'available', reason_code: null, context, generation_requested: false, complete: true, cursor: null};
    const lookup = (value: unknown) => lookupConcept(base, id, signal(), async input => {
      expect(new URL(String(input)).searchParams.get('id')).toBe(id);
      return Response.json({...envelope, concepts: [value]});
    });
    expect((await lookup(item)).concepts[0]).toMatchObject({id, state: 'available', label: null, reason: item.label_reason_code});
    expect((await lookup({...item, state: 'not_saved', reason_code: 'concept.not_saved'})).concepts[0])
      .toMatchObject({id, state: 'not_saved', label: null, reason: 'concept.not_saved'});
    await expect(lookup({...item, concept_tag: {kind: 'id', value: '0'}}))
      .rejects.toThrow('The saved publication returned an invalid response.');
  });
});
