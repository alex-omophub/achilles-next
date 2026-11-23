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
export interface ReportRow {
  row_key: string;
  row_kind: string;
  state: string;
  reason_code: string | null;
  dimensions: ReportFields;
  values: ReportFields | null;
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
export async function readReport(base: URL, metricId: string, cursor: string | null, signal: AbortSignal,
    fetchImpl = fetch): Promise<ReportPage> {
  check(metricId.length <= 128 && /^(core|observed)\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/.test(metricId));
  const url = new URL(`reports/${metricId}.json`, base);
  if (cursor !== null) url.searchParams.set('cursor', cursor);
  const page = await request(url, signal, fetchImpl);
  const source = context(page);
  const dataset = page.dataset;
  const selection = page.selection;
  check(page.transformations === 'none' && record(dataset) && record(selection)
    && dataset.metric_id === metricId && selection.metric_id === metricId
    && typeof dataset.version === 'string' && dataset.version === selection.metric_version
    && typeof dataset.population === 'string' && dataset.population === selection.population
    && typeof dataset.grain === 'string' && typeof dataset.state === 'string' && reasonCode(dataset.reason_code)
    && typeof selection.row_kind === 'string' && typeof page.state === 'string' && reasonCode(page.reason_code)
    && Array.isArray(page.rows) && page.rows.length <= 12);
  const rowKind = selection.row_kind;
  const available = page.state === 'available';
  check(available ? page.rows.length > 0 && dataset.state !== 'suppressed' && dataset.state !== 'unsupported'
    : page.rows.length === 0 && page.complete === true);
  check((page.complete === true && page.cursor === null) || (page.complete === false && typeof page.cursor === 'string'
    && page.cursor.length > 0));
  const rows = page.rows.map((row: unknown): ReportRow => {
    check(record(row) && typeof row.row_key === 'string' && row.row_kind === rowKind && typeof row.state === 'string'
      && reasonCode(row.reason_code) && reportFields(row.dimensions));
    const visible = ['computed', 'empty_source', 'empty_population'].includes(row.state);
    const values = row.values;
    if (visible) check(reportFields(values));
    else check(values === null && ['suppressed', 'unsupported', 'unavailable'].includes(row.state));
    return {row_key: row.row_key, row_kind: rowKind, state: row.state, reason_code: row.reason_code,
      dimensions: row.dimensions, values: values as ReportFields | null};
  });
  return {context: source, metric_id: metricId, version: dataset.version, grain: dataset.grain, population: dataset.population,
    state: page.state, reason: page.reason_code, datasetState: dataset.state, datasetReason: dataset.reason_code,
    rowKind, rows, cursor: page.cursor as string | null};
}
