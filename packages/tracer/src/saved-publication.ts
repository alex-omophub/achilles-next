import {canonical, sha256} from '../../contracts/src/index.mjs';

// Only the fields used for display cross this boundary. The native provider
// owns page verification, selection semantics and authorization.
const contextKeys = ['contract_version', 'source_id', 'release_id', 'publication_id', 'access_scope_id',
  'profile_id', 'profile_sha256', 'profile_revision', 'authorization_epoch', 'instance_id'] as const;
type Context = Record<typeof contextKeys[number], string>;
export interface CatalogueMetric {
  metric_id: string;
  version: string;
  state: string;
  rows: string;
}
export interface CataloguePage {
  context: Context;
  metrics: CatalogueMetric[];
  cursor: string | null;
}
export interface PopulationResult {
  context: Context;
  state: string;
  reason: string | null;
  count: string | null;
}
function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
export class PublicationReadError extends Error {}
function check(condition: unknown): asserts condition {
  if (!condition) throw new PublicationReadError('The saved publication returned an invalid response.');
}
function integer(value: unknown): value is string {
  return typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value);
}
function context(envelope: Record<string, unknown>): Context {
  const item = envelope.context;
  check(envelope.generation_requested === false && record(item));
  for (const key of contextKeys) check(typeof item[key] === 'string' && item[key].length > 0);
  return item as Context;
}
export function assertSamePublication(a: Context, b: Context) {
  if (!contextKeys.every(key => a[key] === b[key]))
    throw new PublicationReadError('The publication or access scope changed. Reopen the viewer from R.');
}
async function request(url: URL, signal: AbortSignal, fetchImpl: typeof fetch) {
  const response = await fetchImpl(url, {signal, cache: 'no-store', redirect: 'error', mode: 'same-origin'});
  if (!response.ok) {
    if (response.status === 403) throw new PublicationReadError('Access to this publication was denied. Reopen it from an authorized R session.');
    if (response.status === 422) throw new PublicationReadError('The saved publication could not be verified. Reopen an approved export.');
    throw new PublicationReadError('The local results server could not complete the read. Reopen the viewer from R.');
  }
  // httpuv supplies a Content-Length and enforces the same native response
  // limit. Enforce it while reading too, including when no length is reported.
  const maxBytes = 1024 * 1024;
  check(Number(response.headers.get('Content-Length')) <= maxBytes && response.body);
  const reader = response.body.getReader();
  const decoder = new TextDecoder('utf-8', {fatal: true});
  let text = '', bytes = 0;
  try {
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      bytes += chunk.value.length;
      check(bytes <= maxBytes);
      text += decoder.decode(chunk.value, {stream: true});
    }
    text += decoder.decode();
  } catch (error) {
    await reader.cancel();
    throw error;
  } finally {
    reader.releaseLock();
  }
  signal.throwIfAborted();
  const body: unknown = JSON.parse(text);
  check(record(body));
  return body;
}
export async function readCatalogue(base: URL, cursor: string | null, signal: AbortSignal, fetchImpl = fetch): Promise<CataloguePage> {
  const url = new URL('catalogue.json', base);
  if (cursor !== null) url.searchParams.set('cursor', cursor);
  const page = await request(url, signal, fetchImpl);
  const source = context(page);
  check(page.state === 'available' && Array.isArray(page.metrics) && page.metrics.length <= 12);
  check((page.complete === true && page.cursor === null)
    || (page.complete === false && page.metrics.length > 0 && typeof page.cursor === 'string' && page.cursor.length > 0));
  const metrics = page.metrics.map((item: unknown) => {
    check(record(item) && typeof item.metric_id === 'string' && typeof item.version === 'string'
      && typeof item.state === 'string' && integer(item.rows));
    return {metric_id: item.metric_id, version: item.version, state: item.state, rows: item.rows};
  });
  return {context: source, metrics, cursor: page.cursor as string | null};
}
export async function readPeople(base: URL, signal: AbortSignal, fetchImpl = fetch): Promise<PopulationResult> {
  const page = await request(new URL('people.json', base), signal, fetchImpl);
  const source = context(page);
  check(record(page.dataset) && page.dataset.metric_id === 'core.person.count' && typeof page.dataset.state === 'string'
    && page.transformations === 'none' && page.complete === true && page.cursor === null && Array.isArray(page.rows));
  let state = page.state, reason = page.reason_code, count = null;
  if (state === 'available') {
    check(page.rows.length === 1);
    const row: unknown = page.rows[0];
    check(record(row) && row.row_kind === 'counts');
    state = row.state;
    reason = row.reason_code;
    if (state === 'computed' || state === 'empty_source' || state === 'empty_population') {
      check(record(row.values) && integer(row.values.person_count));
      count = row.values.person_count;
    } else {
      check(row.values === null);
    }
  } else {
    check(page.rows.length === 0);
    if (state === 'not_saved' && page.dataset.state !== 'computed') {
      state = page.dataset.state;
      reason = page.dataset.reason_code;
    }
  }
  check(typeof state === 'string' && (reason === null || typeof reason === 'string'));
  return {context: source, state, reason, count};
}

// Saved numerical values and identifiers arrive as strings, including inside
// metadata objects. Keep that representation all the way to the report table.
export type ReportValue = string | boolean | null | readonly ReportValue[] | ReportFields;
export interface ReportFields { readonly [key: string]: ReportValue }
export interface DenominatorReference {
  measure: string;
  metric_id: string;
  row_key: string;
  field: string;
  value: string;
}
export interface ReportRow {
  row_key: string;
  row_kind: string;
  state: string;
  reason_code: string | null;
  dimensions: ReportFields;
  values: ReportFields | null;
  denominator_refs?: DenominatorReference[];
}
interface ReportDependency {metric_id: string; metric_version: string; row: ReportRow}
export type ConceptTag = {kind: 'id'; value: string} | {kind: 'all' | 'null' | 'schema_absent'};
export type SavedFilters = Readonly<Record<string, string | ConceptTag>>;
export interface ReportCapability {
  concept: string;
  time: string;
  unit: string;
  operator: string;
  period_kinds: string[];
  period_bounds: {full_scope: string; calendar: string};
}
export interface ReportPage {
  context: Context;
  metric_id: string;
  version: string;
  grain: string;
  population: string;
  state: string;
  reason: string | null;
  datasetState: string;
  datasetReason: string | null;
  rowKind: string;
  rows: ReportRow[];
  capability?: ReportCapability;
  evidence?: {definitionSha256: string; dependencies: ReportDependency[]};
  cursor: string | null;
}
function reportValue(value: unknown): value is ReportValue {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return true;
  if (Array.isArray(value)) return value.every(reportValue);
  return record(value) && Object.values(value).every(reportValue);
}
function reportFields(value: unknown): value is ReportFields {
  return record(value) && Object.values(value).every(reportValue);
}
function reasonCode(value: unknown): value is string | null {
  return value === null || (typeof value === 'string' && value.length > 0);
}
function digest(value: unknown): value is string {
  return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
}
function readRow(row: unknown): ReportRow {
  check(record(row) && digest(row.row_key) && typeof row.row_kind === 'string' && typeof row.state === 'string'
    && reasonCode(row.reason_code) && reportFields(row.dimensions) && Array.isArray(row.denominator_refs));
  const values = row.values;
  if (['computed', 'empty_source', 'empty_population'].includes(row.state)) check(reportFields(values));
  else check(values === null && row.denominator_refs.length === 0 && ['suppressed', 'unsupported', 'unavailable'].includes(row.state));
  const refs = row.denominator_refs.map((ref: unknown): DenominatorReference => {
    check(record(ref) && typeof ref.measure === 'string' && typeof ref.metric_id === 'string' && digest(ref.row_key)
      && typeof ref.field === 'string' && integer(ref.value));
    return {measure: ref.measure, metric_id: ref.metric_id, row_key: ref.row_key, field: ref.field, value: ref.value};
  });
  return {row_key: row.row_key, row_kind: row.row_kind, state: row.state, reason_code: row.reason_code,
    dimensions: row.dimensions, values: values as ReportFields | null, denominator_refs: refs};
}
export async function readReport(base: URL, metricId: string, cursor: string | null, signal: AbortSignal,
    fetchImpl = fetch): Promise<ReportPage> {
  return selectReport(base, metricId, {}, cursor, signal, fetchImpl);
}
function reportCapability(item: unknown, metricId: string, version: string, population: string, rowKind: string): ReportCapability | undefined {
  if (item === undefined) return undefined;
  check(record(item) && item.metric_id === metricId && item.metric_version === version && item.population === population
    && Array.isArray(item.row_kinds) && item.row_kinds.includes(rowKind) && typeof item.concept === 'string'
    && typeof item.time === 'string' && typeof item.unit === 'string' && typeof item.operator === 'string'
    && Array.isArray(item.period_kinds) && item.period_kinds.every(kind => typeof kind === 'string')
    && record(item.period_bounds) && typeof item.period_bounds.full_scope === 'string' && typeof item.period_bounds.calendar === 'string');
  return {concept: item.concept, time: item.time, unit: item.unit, operator: item.operator, period_kinds: item.period_kinds,
    period_bounds: {full_scope: item.period_bounds.full_scope, calendar: item.period_bounds.calendar}};
}
export async function selectReport(base: URL, metricId: string, filters: SavedFilters, cursor: string | null,
    signal: AbortSignal, fetchImpl = fetch): Promise<ReportPage> {
  const page = await request(reportUrl(base, 'reports', metricId, filters, cursor), signal, fetchImpl);
  return parseReport(page, metricId, filters);
}
function reportUrl(base: URL, kind: 'reports' | 'evidence', metricId: string, filters: SavedFilters, cursor: string | null) {
  check(metricId.length <= 128 && /^(core|observed)\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/.test(metricId));
  const url = new URL(`${kind}/${metricId}.json`, base);
  if (Object.keys(filters).length) url.searchParams.set('filters', canonical(filters));
  if (cursor !== null) url.searchParams.set('cursor', cursor);
  return url;
}
function parseReport(page: Record<string, unknown>, metricId: string, filters: SavedFilters): ReportPage {
  const source = context(page);
  const dataset = page.dataset;
  const selection = page.selection;
  check(page.transformations === 'none' && record(dataset) && record(selection)
    && dataset.metric_id === metricId && selection.metric_id === metricId
    && typeof dataset.version === 'string' && dataset.version === selection.metric_version
    && typeof dataset.population === 'string' && dataset.population === selection.population
    && typeof dataset.grain === 'string' && typeof dataset.state === 'string' && reasonCode(dataset.reason_code)
    && typeof selection.row_kind === 'string' && typeof page.state === 'string' && reasonCode(page.reason_code)
    && digest(dataset.definition_sha256) && Array.isArray(page.dependencies)
    && Array.isArray(page.rows) && page.rows.length <= 12);
  // A page, including a continuation, must answer the exact requested selection.
  check(record(selection.filters) && canonical(selection.filters) === canonical(filters));
  const capability = reportCapability(page.capability, metricId, dataset.version, dataset.population, selection.row_kind);
  const rowKind = selection.row_kind;
  const available = page.state === 'available';
  check(available ? page.rows.length > 0 && dataset.state !== 'suppressed' && dataset.state !== 'unsupported'
    : page.rows.length === 0 && page.dependencies.length === 0 && page.complete === true);
  check((page.complete === true && page.cursor === null) || (page.complete === false && typeof page.cursor === 'string'
    && page.cursor.length > 0));
  const rows = page.rows.map(readRow);
  check(rows.every(row => row.row_kind === rowKind));
  const dependencies = page.dependencies.map((dep: unknown): ReportDependency => {
    check(record(dep) && typeof dep.metric_id === 'string' && typeof dep.metric_version === 'string');
    return {metric_id: dep.metric_id, metric_version: dep.metric_version, row: readRow(dep.row)};
  });
  const linkedRows = new Map<string, ReportRow>();
  for (const item of [...rows.map(row => ({metric_id: metricId, row})), ...dependencies]) {
    const key = item.metric_id + '|' + item.row.row_key;
    check(!linkedRows.has(key));
    linkedRows.set(key, item.row);
  }
  for (const row of linkedRows.values()) {
    for (const ref of row.denominator_refs ?? []) {
      const values = linkedRows.get(ref.metric_id + '|' + ref.row_key)?.values;
      check(values && Object.hasOwn(values, ref.field) && values[ref.field] === ref.value);
    }
  }
  return {context: source, metric_id: metricId, version: dataset.version, grain: dataset.grain, population: dataset.population,
    state: page.state, reason: page.reason_code, datasetState: dataset.state, datasetReason: dataset.reason_code,
    rowKind, rows, capability, evidence: {definitionSha256: dataset.definition_sha256, dependencies}, cursor: page.cursor as string | null};
}

export interface SavedConcept {
  id: string;
  label: string | null;
  labelState: string;
  state: string;
  reason: string | null;
}
export interface ConceptPage {
  context: Context;
  state: string;
  reason: string | null;
  cursor: string | null;
  concepts: SavedConcept[];
}
function conceptPage(body: Record<string, unknown>, exactId?: string): ConceptPage {
  const source = context(body);
  check((body.state === 'available' || body.state === 'unavailable') && reasonCode(body.reason_code)
    && Array.isArray(body.concepts) && body.concepts.length <= (exactId === undefined ? 12 : 1)
    && ((body.complete === true && body.cursor === null) || (body.complete === false && body.concepts.length > 0
      && typeof body.cursor === 'string' && body.cursor.length > 0)));
  const concepts = body.concepts.map((item: unknown): SavedConcept => {
    check(record(item) && record(item.concept_tag) && item.concept_tag.kind === 'id' && typeof item.concept_tag.value === 'string'
      && (exactId === undefined || item.concept_tag.value === exactId)
      && (item.label_state === 'available' ? typeof item.label === 'string' : item.label_state === 'unavailable' && item.label === null));
    const state = exactId === undefined ? 'available' : item.state;
    const reason = item.reason_code ?? item.label_reason_code ?? null;
    check((state === 'available' || state === 'not_saved') && reasonCode(reason));
    return {id: item.concept_tag.value, label: item.label as string | null, labelState: item.label_state as string, state, reason};
  });
  if (body.state === 'unavailable') check(concepts.length === 0 && body.complete === true);
  return {context: source, state: body.state, reason: body.reason_code, cursor: body.cursor as string | null, concepts};
}
export async function searchConcepts(base: URL, query: string, cursor: string | null, signal: AbortSignal,
    fetchImpl = fetch): Promise<ConceptPage> {
  const url = new URL('concepts/search.json', base);
  url.searchParams.set('q', query);
  if (cursor !== null) url.searchParams.set('cursor', cursor);
  const body = await request(url, signal, fetchImpl);
  check(body.query === query && ((body.state === 'available' && body.searched === true)
    || (body.state === 'unavailable' && body.searched === false)));
  return conceptPage(body);
}
export async function lookupConcept(base: URL, id: string, signal: AbortSignal, fetchImpl = fetch): Promise<ConceptPage> {
  const url = new URL('concepts/lookup.json', base);
  url.searchParams.set('id', id);
  const body = await request(url, signal, fetchImpl);
  const page = conceptPage(body, id);
  check(page.state === 'available' && page.concepts.length === 1 && page.cursor === null);
  return page;
}

export async function readPageEvidence(base: URL, metricId: string, filters: SavedFilters, cursor: string | null,
    signal: AbortSignal, fetchImpl = fetch): Promise<unknown> {
  return request(reportUrl(base, 'evidence', metricId, filters, cursor), signal, fetchImpl);
}
function boundedJson(value: unknown, downloading = false) {
  const text = JSON.stringify(value, downloading ? (key, item) => {
    check(key !== 'cursor' && key !== 'authorization_epoch' && key !== 'instance_id');
    return item;
  } : undefined);
  check(typeof text === 'string' && text.length <= 1048576 && new TextEncoder().encode(text).length <= 1048576);
  return text;
}
export async function pageEvidenceJson(envelope: unknown, displayed: ReportPage, filters: SavedFilters, number: number) {
  // Snapshot host-provided JSON before asynchronous digest verification. The
  // installed transport also limits bytes while streaming the HTTP response.
  const data: unknown = JSON.parse(boundedJson(envelope));
  check(record(data) && data.kind === 'selected_page_evidence' && data.format_version === '1.0.0'
    && data.generation_requested === false && Number.isSafeInteger(number) && number > 0 && record(data.page));
  const report = parseReport(data.page, displayed.metric_id, filters);
  assertSamePublication(displayed.context, report.context);
  check(report.evidence && canonical(report) === canonical(displayed));
  const def = data.definition;
  check(record(def) && def.id === report.metric_id && def.version === report.version && def.grain === report.grain
    && def.population === report.population && typeof def.calculation === 'string' && typeof def.precision === 'string'
    && await sha256(canonical(def) + '\n') === report.evidence.definitionSha256);
  const prov = data.provenance;
  check(record(prov) && digest(prov.root_sha256) && digest(prov.policy_sha256) && typeof prov.approval_id === 'string'
    && typeof prov.generated_at === 'string' && typeof prov.scope_kind === 'string' && record(prov.source_schema)
    && digest(prov.source_schema.sha256) && typeof prov.source_schema.declared_cdm_version === 'string'
    && record(prov.source_consistency) && typeof prov.source_consistency.within_run === 'string'
    && prov.source_consistency.reusable === false && reasonCode(prov.source_consistency.reason_code));
  const limitations = data.limitations;
  check(record(limitations) && limitations.selection === 'current_page_only'
    && reportFields(limitations.precision) && reportFields(limitations.availability));
  const dataset = data.page.dataset;
  check(record(dataset));
  const safeContext = Object.fromEntries(contextKeys.filter(key => key !== 'authorization_epoch' && key !== 'instance_id')
    .map(key => [key, report.context[key]]));
  const safeDataset = Object.fromEntries(['metric_id','version','population','grain','row_schema_id','definition_sha256',
    'state','reason_code','required','conditional_support','rows','completeness'].filter(key => Object.hasOwn(dataset, key)).map(key => [key, dataset[key]]));
  const publicEvidence = {
    format_version: data.format_version, kind: data.kind, generation_requested: false,
    page: {number, complete: report.cursor === null, context: safeContext, dataset: safeDataset,
      selection: {metric_id: report.metric_id, metric_version: report.version, population: report.population, row_kind: report.rowKind, filters},
      state: report.state, reason_code: report.reason, transformations: 'none', rows: report.rows, dependencies: report.evidence.dependencies},
    definition: def,
    provenance: {root_sha256: prov.root_sha256, scope_kind: prov.scope_kind, generated_at: prov.generated_at,
      source_schema: {declared_cdm_version: prov.source_schema.declared_cdm_version, sha256: prov.source_schema.sha256},
      source_consistency: {within_run: prov.source_consistency.within_run, reusable: false, reason_code: prov.source_consistency.reason_code},
      approval_id: prov.approval_id, policy_sha256: prov.policy_sha256},
    limitations: {selection: limitations.selection, precision: limitations.precision, availability: limitations.availability},
  };
  return boundedJson(publicEvidence, true);
}
