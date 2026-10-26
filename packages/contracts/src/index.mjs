// Portable contract primitives. No React, router, HTTP client or credentials.
export const CONTRACT_VERSION = '1.0.0';
export const canonical = value => {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
};
export async function sha256(text) {
  const hash = await globalThis.crypto.subtle.digest('SHA-256', typeof text === 'string' ? new TextEncoder().encode(text) : text);
  return [...new Uint8Array(hash)].map(n => n.toString(16).padStart(2, '0')).join('');
}
export function toSafeCountNumber(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) throw new TypeError('Expected exact count string');
  if (BigInt(value) > BigInt(Number.MAX_SAFE_INTEGER)) throw new RangeError('Count exceeds safe Number range; retain the exact string');
  return Number(value);
}
export function inputReuseIdentity(manifest) {
  const s = manifest.source;
  if (!s || s.snapshot.state !== 'known' || s.snapshot.immutable !== true || !s.snapshot.assertion_id ||
      manifest.reproducibility.consistent_snapshot !== true ||
      [s.data_release, s.vocabulary_release, s.schema_fingerprint].some(id => id.state !== 'known') ||
      !manifest.disclosure.applied || !manifest.disclosure.approval_id) return null;
  return canonical({source: s, request_sha256: manifest.request_sha256, profile: manifest.profile,
    metrics: manifest.outputs.map(o => [o.metric_id, o.metric_version]).sort(), disclosure: manifest.disclosure});
}
export function viewCacheKey(manifest, context, metricId, instanceId) {
  const inputs = inputReuseIdentity(manifest);
  if (!inputs || !instanceId || !context.access_scope_id || !context.authorization_epoch) return null;
  assertContext(manifest, context);
  return canonical({inputs, context, metricId, instanceId});
}
export function assertContext(document, context) {
  const sourceId = document.source?.source_id ?? document.source_id;
  if (sourceId !== context.source_id || document.bundle_id !== context.bundle_id) {
    throw new Error('INCOMPATIBLE_CONTEXT: response source/bundle does not match the requested context');
  }
}
