// Host lifecycle tests control asynchronous admissions independently of React rendering.
export const admissions = [];
export const providers = [];
export const reads = [];
export const mounts = [];

export function readPublicationAdmission(url, options, signal) {
  const pending = Promise.withResolvers();
  admissions.push({url, options, signal, ...pending});
  return pending.promise;
}

export function createPublicationHttpProvider(url, options) {
  providers.push({url, options});
  return {people() {
    const pending = Promise.withResolvers();
    reads.push(pending);
    return pending.promise;
  }};
}

export function mountPublicationWorkspace(slot, options) {
  const ready = Promise.withResolvers();
  const record = {slot, options, ready, updates: [], destroyed: false};
  mounts.push(record);
  slot.textContent = options.context.source_id;
  return {
    id: 'viewer-' + mounts.length,
    ready: ready.promise,
    async update(configuration) {
      record.updates.push(configuration);
      return {status: 'applied', generation: record.updates.length + 1};
    },
    async destroy() {
      record.destroyed = true;
      slot.textContent = '';
    },
  };
}
