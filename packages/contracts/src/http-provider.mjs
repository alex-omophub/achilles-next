/** Experimental immutable-byte transport for an institution-owned result gateway. */
export class ResultAccessError extends Error {
  constructor(code, status = null) {
    super(`Result access failed: ${code}`);
    this.name = 'ResultAccessError';
    this.code = code;
    this.status = status;
  }
}

export function createFetchResultProvider({baseUrl, getHeaders = async () => ({}), fetch: fetchImpl = globalThis.fetch}) {
  const base = new URL(baseUrl);
  if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password || base.search || base.hash) {
    throw new TypeError('Use an HTTP(S) gateway base URL without credentials, query or fragment');
  }
  base.pathname = base.pathname.replace(/\/?$/, '/');
  async function read(context, resource, options) {
    try {
      options.signal.throwIfAborted();
      const headers = new Headers(await getHeaders(context, options));
      options.signal.throwIfAborted();
      headers.set('Accept', 'application/json');
      headers.set('X-Request-Id', options.requestId);
      if ([context.source_id, context.bundle_id].some(id => typeof id !== 'string' || !id || id === '.' || id === '..')) {
        throw new ResultAccessError('PROVIDER_FAILURE');
      }
      const path = `sources/${encodeURIComponent(context.source_id)}/bundles/${encodeURIComponent(context.bundle_id)}/${resource}`;
      const response = await fetchImpl(new URL(path, base), {
        method: 'GET', headers, signal: options.signal, cache: 'no-store',
        credentials: 'same-origin', redirect: 'error',
      });
      if (!response.ok) {
        const code = response.status === 401 ? 'UNAUTHENTICATED' : response.status === 403 ? 'INACCESSIBLE' :
          response.status === 404 ? 'NOT_FOUND' : 'PROVIDER_FAILURE';
        throw new ResultAccessError(code, response.status);
      }
      return new Uint8Array(await response.arrayBuffer());
    } catch (error) {
      if (options.signal.aborted) throw new DOMException('Result access cancelled', 'AbortError');
      if (error?.name === 'AbortError') throw error;
      if (error instanceof ResultAccessError) throw error;
      // Transport exceptions and remote bodies can contain URLs or secrets.
      throw new ResultAccessError('PROVIDER_FAILURE');
    }
  }
  return {
    getManifest: (context, options) => read(context, 'manifest.json', options),
    getResult: (context, metricId, options) => read(context, `results/${encodeURIComponent(metricId)}.json`, options),
    getTerminology: (context, options) => read(context, 'terminology.json', options),
  };
}
