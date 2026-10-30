import {validateResult, validateBundleDocuments} from '../../contracts/src/semantics.mjs';
import {measurementIds, type VerifiedMeasurement} from './measurement';
import {observationIds, verifyObservation, type VerifiedObservation} from './observation';
import {bundle, result, terminology} from './generated-validation.mjs';
import profileText from '../../../inst/analysis/alpha-measurement-v1.json?raw';
import {assertContext, canonical, sha256} from '../../contracts/src/index.mjs';
import type {AccessContext, BundleManifest, MetricId, ReadOptions, ResultProvider,
  ResultDocument, TerminologyDocument} from '../../contracts/src/index.mjs';

const profile = JSON.parse(profileText) as {required_outputs: MetricId[]};
const validators: Record<string, (doc: unknown) => boolean> = {bundle, result, terminology};
function requireValid(test: unknown, message: string): asserts test {
  if (!test) throw new Error(message);
}
function decode(name: string, bytes: Uint8Array): any {
  const doc = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes));
  requireValid(validators[name](doc), `Invalid ${name}: incompatible typed fields.`);
  return doc;
}
export interface BundleFile {size: number; arrayBuffer(): Promise<ArrayBuffer>}
export interface SelectedFile extends BundleFile {name: string; webkitRelativePath: string}
export type OpenErrorState = 'missing' | 'invalid' | 'incompatible' | 'unavailable';
export class BundleOpenError extends Error {
  constructor(public readonly state: OpenErrorState, message: string) {super(message);}
}
export interface VerifiedCount {
  manifest: BundleManifest;
  count: string;
  state: 'computed' | 'empty_source';
  context: AccessContext;
  provider: ResultProvider;
  observation?: VerifiedObservation;
  measurement?: VerifiedMeasurement;
}
/** Map a user-selected folder. No server/filesystem path or workspace access. */
export function selectedBundleFiles(files: Iterable<SelectedFile>): Map<string, BundleFile> {
  const result = new Map<string, BundleFile>();
  let root: string | undefined;
  for (const file of files) {
    const pieces = file.webkitRelativePath.split('/');
    requireValid(pieces.length >= 2 && pieces.every(p => p && p !== '.' && p !== '..' && !/[\\\u0000]/.test(p)), 'Choose one generated bundle folder.');
    root ??= pieces[0];
    requireValid(root === pieces[0], 'Choose one bundle at a time.');
    const path = pieces.slice(1).join('/');
    requireValid(!result.has(path), 'Duplicate selected file path.');
    result.set(path, file);
  }
  return result;
}

/** Same verifier as file selection, with only declared files from an R-selected
 * loopback snapshot. The base URL is relative to the current non-root page. */
export async function openServedCountBundle(base: URL, signal: AbortSignal,
  fetchImpl: typeof fetch = globalThis.fetch): Promise<VerifiedCount> {
  const read = async (path: string) => {
    signal.throwIfAborted();
    let response: Response;
    try {response = await fetchImpl(new URL(path, base), {signal, cache: 'no-store', redirect: 'error'});}
    catch {signal.throwIfAborted(); throw new BundleOpenError('unavailable', 'The local results server could not be reached. Reopen the viewer from R.');}
    if (!response.ok) throw new BundleOpenError(response.status === 404 ? 'missing' : 'unavailable',
      response.status === 404 ? 'A declared result file is missing. Reopen the selected bundle.' : 'The local results server is unavailable. Reopen the viewer from R.');
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length > 10 * 1024 * 1024) throw new BundleOpenError('invalid', 'A result file exceeds the viewer limit.');
    return bytes;
  };
  try {
    const status = JSON.parse(new TextDecoder().decode(await read('status.json')));
    if (status.state !== 'ready') {
      const state: OpenErrorState = ['missing', 'invalid', 'incompatible'].includes(status.state) ? status.state : 'unavailable';
      throw new BundleOpenError(state, typeof status.message === 'string' ? status.message : 'Reopen a supported count-tracer, observation-tracer or measurement reference bundle.');
    }
    const manifestBytes = await read('manifest.json');
    const manifest = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(manifestBytes));
    if (manifest.contract_version !== '1.0.0' || manifest.profile?.id !== 'alpha-measurement-v1' ||
      !['AchillesNext-count-tracer', 'AchillesNext-observation-tracer', 'AchillesNext-measurement-reference'].includes(manifest.generator?.name) || manifest.publication !== 'partial') {
      throw new BundleOpenError('incompatible', 'This viewer supports partial count, observation or measurement reference bundles using contract 1.0.0.');
    }
    requireValid(validators.bundle(manifest), 'Invalid manifest: incompatible typed fields.');
    requireValid(new Set(manifest.outputs.map((p: {path: string}) => p.path)).size === 15, 'Duplicate output path.');
    const paths: string[] = manifest.outputs.map((p: {path: string}) => p.path);
    requireValid(paths.every(path => /^results\/[a-z][a-z0-9._-]*\.json$/.test(path) && !path.includes('..')), 'Invalid result path.');
    const files = new Map<string, BundleFile>();
    const put = (path: string, bytes: Uint8Array) => files.set(path, {size: bytes.length,
      arrayBuffer: async () => bytes.slice().buffer as ArrayBuffer});
    put('manifest.json', manifestBytes);
    let total = manifestBytes.length;
    await Promise.all([...paths, 'terminology.json'].map(async path => {
      const bytes = await read(path); total += bytes.length;
      requireValid(total <= 64 * 1024 * 1024, 'Bundle exceeds the viewer size limit.');
      put(path, bytes);
    }));
    return await openCountBundle(files, signal);
  } catch (error) {
    signal.throwIfAborted();
    if (error instanceof BundleOpenError) throw error;
    throw new BundleOpenError('invalid', error instanceof Error ? (error.message || error.name) : 'The result bundle is invalid.');
  }
}
/** Verify declared bytes, schemas and shared cross-document semantics before exposing
 * a supported partial development projection. No SQL or arbitrary filters run here. */
export async function openCountBundle(files: ReadonlyMap<string, BundleFile>, signal: AbortSignal): Promise<VerifiedCount> {
  let total = 0;
  const bytesByPath = new Map<string, Uint8Array>();
  async function read(path: string): Promise<Uint8Array> {
    signal.throwIfAborted();
    requireValid(/^(manifest|terminology)\.json$|^results\/[a-z][a-z0-9._-]*\.json$/.test(path) && !path.includes('..'), 'Invalid bundle file path.');
    const file = files.get(path);
    requireValid(file && file.size <= 10 * 1024 * 1024, 'A declared bundle file is missing or exceeds 10 MiB.');
    total += file.size;
    requireValid(total <= 64 * 1024 * 1024, 'Bundle exceeds the 64 MiB tracer limit.');
    const bytes = new Uint8Array(await file.arrayBuffer());
    signal.throwIfAborted();
    requireValid(bytes.length === file.size, 'Selected file changed during reading.');
    bytesByPath.set(path, bytes);
    return bytes;
  }
  const manifestBytes = await read('manifest.json');
  const manifest = decode('bundle', manifestBytes) as BundleManifest;
  requireValid(manifest.publication === 'partial' && manifest.eligible_for_current_pointer === false &&
    ['AchillesNext-count-tracer', 'AchillesNext-observation-tracer', 'AchillesNext-measurement-reference'].includes(manifest.generator.name), 'Choose a partial count-tracer, observation-tracer or measurement reference bundle, not a complete alpha report.');
  requireValid(manifest.profile.sha256 === await sha256(profileText) &&
    manifest.request_sha256 === await sha256(canonical(manifest.request)) &&
    manifest.request.source_id === manifest.source.source_id, 'Request, profile or source identity mismatch.');
  const months = (value: string) => Number(value.slice(0, 4)) * 12 + Number(value.slice(5, 7));
  requireValid(manifest.request.window.start <= manifest.request.window.end &&
    months(manifest.request.window.end) - months(manifest.request.window.start) < 120, 'Invalid bounded request window.');
  const ids = manifest.outputs.map(p => p.metric_id);
  requireValid(new Set(ids).size === profile.required_outputs.length && profile.required_outputs.every(id => ids.includes(id)), 'The bundle must declare all 15 output partitions.');
  requireValid(new Set(manifest.outputs.map(p => p.path)).size === ids.length, 'Duplicate output path.');
  const documents = new Map<MetricId, ResultDocument>();
  // Independent reads run together; limits are reserved synchronously by read().
  await Promise.all(manifest.outputs.map(async partition => {
    const bytes = await read(partition.path);
    requireValid(await sha256(bytes) === partition.sha256 && String(bytes.length) === partition.bytes, 'Result integrity check failed. Regenerate the bundle.');
    const doc = decode('result', bytes) as ResultDocument;
    requireValid(doc.source_id === manifest.source.source_id && doc.bundle_id === manifest.bundle_id &&
      doc.run_id === manifest.run_id && doc.request_sha256 === manifest.request_sha256 &&
      doc.metric_id === partition.metric_id && doc.metric_version === partition.metric_version &&
      doc.state === partition.state && doc.reason === partition.reason &&
      String(doc.rows?.length ?? 0) === partition.rows, 'Result identity or state mismatch.');
    if (!['person.count', 'source.passport', ...(manifest.generator.name !== 'AchillesNext-count-tracer' ? observationIds : []), ...(manifest.generator.name === 'AchillesNext-measurement-reference' ? measurementIds : [])].includes(doc.metric_id)) {
      requireValid(doc.state === 'unsupported' && typeof doc.reason === 'string' && doc.reason.length > 0 && doc.rows === null,
        'Count tracer contains an undeclared implemented output.');
    }
    documents.set(doc.metric_id, doc);
  }));
  const termBytes = await read(manifest.terminology.path);
  requireValid(await sha256(termBytes) === manifest.terminology.sha256 && String(termBytes.length) === manifest.terminology.bytes, 'Terminology integrity check failed.');
  const terminology = decode('terminology', termBytes) as TerminologyDocument;
  requireValid(terminology.source_id === manifest.source.source_id &&
    canonical(terminology.vocabulary_release) === canonical(manifest.source.vocabulary_release) && (manifest.generator.name === 'AchillesNext-measurement-reference' || terminology.concepts.length === 0),
  'Terminology/source mismatch.');
  const countDoc = documents.get('person.count') as ResultDocument<'person.count'>;
  requireValid(countDoc.state === 'computed' || countDoc.state === 'empty_source', 'Person count is unavailable; it cannot be displayed as zero.');
  requireValid(countDoc.rows.length === 1, 'Expected one all-source count.');
  const row = countDoc.rows[0];
  requireValid(row.values && row.denominator === null && canonical(row.dimensions) === '{}' && row.state === countDoc.state &&
    (countDoc.state === 'computed' ? row.values.count !== '0' && row.reason === null && countDoc.reason === null :
      row.values.count === '0' && typeof row.reason === 'string' && !!row.reason && row.reason === countDoc.reason), 'Invalid person-count state or grain.');
  const passport = documents.get('source.passport') as ResultDocument<'source.passport'>;
  requireValid(passport.state === 'computed' && passport.reason === null && passport.rows.length === 1, 'Source passport is unavailable.');
  const passportRow = passport.rows[0], identity = passportRow.values;
  requireValid(identity && passportRow.state === 'computed' && passportRow.reason === null && passportRow.denominator === null && canonical(passportRow.dimensions) === '{}' &&
    identity.source_id === manifest.source.source_id && identity.run_id === manifest.run_id && identity.source_snapshot_id === manifest.source.snapshot.id &&
    identity.data_release_id === manifest.source.data_release.id && identity.vocabulary_release_id === manifest.source.vocabulary_release.id &&
    identity.declared_cdm_version === manifest.source.declared_cdm_version && canonical(identity.observed_schema_evidence) === canonical(manifest.source.schema_fingerprint), 'Passport/manifest mismatch.');
  requireValid(manifest.source.snapshot.state === 'unknown' && manifest.reproducibility.consistent_snapshot === false &&
    !!manifest.reproducibility.limitation && manifest.disclosure.applied === false && manifest.disclosure.approval_id === null &&
    manifest.disclosure.policy_id === manifest.request.disclosure_policy_id && manifest.reproducibility.execution_start <= manifest.reproducibility.execution_end,
  'Tracer must retain unknown snapshot and unapplied disclosure limitations.');
  validateBundleDocuments(manifest, documents, terminology, {profile, validateDocument: (name: string, doc: any) => {
    requireValid(validators[name](doc), `Invalid ${name}: incompatible typed fields.`);
    if (name === 'result') validateResult(doc);
    if (name === 'terminology') {
      requireValid(new Set(doc.concepts.map((c: {concept_id: number}) => c.concept_id)).size === doc.concepts.length, 'Duplicate terminology concept ID.');
      for (const c of doc.concepts) requireValid(c.state === 'available' ? c.concept_name !== null && c.domain_id !== null && c.reason === null :
        c.concept_name === null && c.domain_id === null && c.reason !== null, 'Terminology state/value mismatch.');
    }
  }});
  signal.throwIfAborted();
  const context: AccessContext = {source_id: manifest.source.source_id, bundle_id: manifest.bundle_id,
    manifest_sha256: await sha256(manifestBytes), access_scope_id: 'user-selected-local-files', authorization_epoch: 'local-selection'};
  async function get(path: string, ctx: Readonly<AccessContext>, options: ReadOptions): Promise<Uint8Array> {
    options.signal.throwIfAborted();
    assertContext(manifest, ctx);
    requireValid(ctx.manifest_sha256 === context.manifest_sha256 && ctx.access_scope_id === context.access_scope_id &&
      ctx.authorization_epoch === context.authorization_epoch, 'Local selection context mismatch.');
    const bytes = bytesByPath.get(path);
    requireValid(bytes, 'Result was not declared in this bundle.');
    return bytes.slice();
  }
  const provider: ResultProvider = {
    getManifest: (ctx, options) => get('manifest.json', ctx, options),
    getResult: (ctx, metricId, options) => {
      const partition = manifest.outputs.find(p => p.metric_id === metricId);
      requireValid(partition, 'Metric is not declared.');
      return get(partition.path, ctx, options);
    },
    getTerminology: (ctx, options) => get(manifest.terminology.path, ctx, options),
  };
  const observation = manifest.generator.name !== 'AchillesNext-count-tracer' ? verifyObservation(manifest, documents, row.values.count) : undefined;
  return {manifest, count: row.values.count, state: countDoc.state, context, provider, observation, measurement: manifest.generator.name === 'AchillesNext-measurement-reference' ? {documents, terminology} : undefined};
}
