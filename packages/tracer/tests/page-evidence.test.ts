import {expect, it} from 'vitest';
import {canonical, sha256} from '../../contracts/src/index.mjs';
import {pageEvidenceJson, readPageEvidence, selectReport} from '../src/saved-publication';

const metric = 'core.condition.capture_count';
const filters = {concept_tag: {kind: 'id', value: '9007199254740993'}} as const;
const base = new URL('http://127.0.0.1:3001/scope/api/');
const signal = new AbortController().signal;
const context = {source_id: 'source', release_id: 'release', publication_id: 'publication', access_scope_id: 'approved',
  profile_id: 'core-characterization-v2', profile_sha256: 'a'.repeat(64), profile_revision: '2.0.0',
  contract_version: '2.1.0', authorization_epoch: 'private-auth-epoch', instance_id: 'private-instance'};
async function fixture() {
  const definition = {id: metric, version: '1.0.0', grain: 'concept/period', population: 'all_recorded_rows',
    calculation: 'Count saved rows.', precision: 'contract:exact-values'};
  const dataset = {metric_id: metric, version: definition.version, grain: definition.grain, population: definition.population,
    state: 'computed', reason_code: null, definition_sha256: await sha256(canonical(definition) + '\n')};
  const selection = {metric_id: metric, metric_version: dataset.version, row_kind: 'counts', population: dataset.population, filters};
  const denominator = {metric_id: 'core.person.count', metric_version: '1.0.0', row: {row_key: 'd'.repeat(64), row_kind: 'counts',
    state: 'computed', reason_code: null, dimensions: {}, values: {person_count: '9007199254740993'}, denominator_refs: []}};
  const ref = {measure: 'person_count', field: 'person_count', metric_id: denominator.metric_id,
    row_key: denominator.row.row_key, value: denominator.row.values.person_count};
  const row = {row_key: 'e'.repeat(64), row_kind: 'counts', state: 'empty_population', reason_code: 'fixture.empty',
    dimensions: {...filters, period_kind: 'calendar_month', period_start: '2020-01-01', period_end: '2020-01-31'},
    values: {person_count: '0', record_count: '0'}, denominator_refs: [ref]};
  const page = {state: 'available', reason_code: null, dataset, selection, context, generation_requested: false,
    transformations: 'none', complete: false, cursor: 'private-next-cursor', rows: [row], dependencies: [denominator]};
  const evidence = {kind: 'selected_page_evidence', format_version: '1.0.0', generation_requested: false,
    page, definition, provenance: {root_sha256: 'b'.repeat(64), policy_sha256: 'c'.repeat(64), approval_id: 'approval',
      generated_at: '2026-01-01T00:00:00Z', scope_kind: 'restricted', source_schema: {sha256: 'a'.repeat(64), declared_cdm_version: '5.3'},
      source_consistency: {within_run: 'unknown', reusable: false, reason_code: 'source.reuse_not_asserted'}},
    limitations: {selection: 'current_page_only', precision: {counts: 'Exact integers'}, availability: {empty: 'Explicit state'}}};
  const shown = await selectReport(base, metric, filters, 'private-start-cursor', signal, async () => Response.json(page));
  return {page, shown, evidence};
}

it('reauthorizes the exact report selection and exports only its bounded page and linked evidence', async () => {
  const {page, shown, evidence} = await fixture();
  const raw = await readPageEvidence(base, metric, filters, 'private-start-cursor', signal, async (url, init) => {
    const request = new URL(String(url));
    expect(request.pathname).toBe('/scope/api/evidence/' + metric + '.json');
    expect(JSON.parse(request.searchParams.get('filters')!)).toEqual(filters);
    expect(request.searchParams.get('cursor')).toBe('private-start-cursor');
    expect(init).toMatchObject({signal, cache: 'no-store', mode: 'same-origin', redirect: 'error'});
    return Response.json(evidence);
  });
  const json = await pageEvidenceJson(raw, shown, filters, 2);
  const result = JSON.parse(json);
  expect(result.page).toMatchObject({number: 2, complete: false, rows: page.rows, dependencies: page.dependencies, selection: page.selection});
  expect(result).toMatchObject({definition: evidence.definition, provenance: evidence.provenance, limitations: evidence.limitations});
  for (const key of ['cursor','authorization_epoch','instance_id','private-start','private-next','private-instance','private-auth'])
    expect(json).not.toContain(key);
});

it('rejects a changed context, filter, row, dependency, definition or cursor before downloading', async () => {
  const {page, shown, evidence} = await fixture();
  for (const change of [
    {context: {...page.context, authorization_epoch: 'changed'}},
    {selection: {...page.selection, filters: {}}},
    {rows: [{...page.rows[0], state: 'computed', reason_code: null}]},
    {dependencies: []},
    {cursor: 'different'},
  ]) await expect(pageEvidenceJson({...evidence, page: {...page, ...change}}, shown, filters, 2)).rejects.toThrow();
  await expect(pageEvidenceJson({...evidence, definition: {...evidence.definition, calculation: 'Changed'}}, shown, filters, 2)).rejects.toThrow();
});
it('rejects an oversized host envelope and nested session metadata', async () => {
  const {shown, evidence} = await fixture();
  await expect(pageEvidenceJson({...evidence, extra: 'x'.repeat(1048576)}, shown, filters, 1)).rejects.toThrow();
  await expect(pageEvidenceJson({...evidence, limitations: {...evidence.limitations,
    precision: {cursor: 'host-secret'}}}, shown, filters, 1)).rejects.toThrow();
});
