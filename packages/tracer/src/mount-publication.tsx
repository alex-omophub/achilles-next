import {createRoot, type Root} from 'react-dom/client';
import {PublicationWorkspace, DirectPublicationView} from './PublicationView';
import {PublicationReadError, assertSamePublication, validMetricId, type PublicationContext, type PublicationProvider} from './saved-publication.js';
import styles from './publication.css?inline';

export {createPublicationHttpProvider} from './saved-publication.js';
export type {PublicationContext, PublicationProvider} from './saved-publication.js';

export interface DirectPublicationTarget {
  readonly kind: 'report' | 'chart';
  readonly version: '2';
  readonly metric_id: string;
  readonly metric_version: string;
}
const colorTokens = ['ink', 'muted', 'rule', 'surface', 'accent', 'focus'] as const;
export type PublicationTheme = Readonly<Partial<Record<typeof colorTokens[number], string>>>;
export interface PublicationMountConfiguration {
  readonly theme?: PublicationTheme;
  readonly locale?: string;
  readonly target: {readonly kind: 'workspace'; readonly version: '2'} | DirectPublicationTarget;
  readonly context: PublicationContext;
}
export interface PublicationConceptEvent {
  readonly event_version: '1.0.0';
  readonly type: 'concept_selected' | 'navigation_requested';
  readonly event_id: string;
  readonly correlation_id: string;
  readonly origin: 'user';
  readonly instance_id: string;
  readonly generation: number;
  readonly context: PublicationContext;
  readonly payload: {
    readonly target: 'concept'; readonly concept_id: string; readonly dimension: string;
    readonly metric_id: string; readonly metric_version: string;
  };
}
export interface PublicationMountOptions extends PublicationMountConfiguration {
  readonly provider: PublicationProvider;
  readonly styleNonce?: string;
  readonly onEvent?: (event: PublicationConceptEvent) => void;
}
export interface PublicationMountOutcome {
  readonly status: 'applied' | 'superseded' | 'destroyed';
  readonly generation: number;
}
export interface PublicationMountHandle {
  readonly id: string;
  readonly ready: Promise<PublicationMountOutcome>;
  update(options: PublicationMountConfiguration): Promise<PublicationMountOutcome>;
  destroy(): Promise<void>;
}

const messages = {
  invalid_container: 'Supply an HTML element for the publication workspace.',
  unsupported_environment: 'This browser cannot mount a publication workspace.',
  container_occupied: 'The publication workspace requires an empty container.',
  invalid_configuration: 'The publication workspace configuration is invalid.',
  invalid_context: 'Supply a complete publication context for contract version 2.',
  context_mismatch: 'The saved results do not match the selected publication or access scope.',
  read_failed: 'The selected publication could not be read.',
  render_failed: 'The publication workspace could not be displayed.',
  instance_destroyed: 'The publication workspace has been destroyed.',
};
class MountFailure extends PublicationReadError {
  constructor(readonly code: keyof typeof messages) { super(messages[code]); }
}
function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
const pins = ['contract_version','source_id','release_id','publication_id','access_scope_id','profile_id',
  'profile_sha256','profile_revision','authorization_epoch','instance_id'] as const;
function pinTarget(target: unknown): PublicationMountConfiguration['target'] {
  if (!object(target) || !Object.hasOwn(target, 'kind') || !Object.hasOwn(target, 'version') || target.version !== '2') throw new MountFailure('invalid_configuration');
  if (target.kind === 'workspace' && Object.keys(target).length === 2) return {kind: 'workspace', version: '2'};
  if ((target.kind === 'report' || target.kind === 'chart') && Object.keys(target).length === 4
    && Object.hasOwn(target, 'metric_id') && Object.hasOwn(target, 'metric_version')
    && validMetricId(target.metric_id) && typeof target.metric_version === 'string'
    && target.metric_version.length <= 64 && /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(target.metric_version)) {
    return {kind: target.kind, version: '2', metric_id: target.metric_id, metric_version: target.metric_version};
  }
  throw new MountFailure('invalid_configuration');
}
function themeRule(theme: unknown): string {
  if (theme === undefined) return '';
  if (!object(theme) || Object.prototype.toString.call(theme) !== '[object Object]') throw new MountFailure('invalid_configuration');
  const declarations: string[] = [];
  for (const [token, value] of Object.entries(theme)) {
    if (!colorTokens.some(key => key === token) || typeof value !== 'string' || !/^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i.test(value))
      throw new MountFailure('invalid_configuration');
    declarations.push(`--${token}:${value}`);
    if (token === 'surface') declarations.push('background-color:var(--surface)');
  }
  return declarations.length ? '.publication-workspace{' + declarations.join(';') + '}' : '';
}

function numberLocale(value: unknown): string {
  if (value === undefined) return 'en';
  if (typeof value !== 'string' || !value) throw new MountFailure('invalid_configuration');
  try {
    const [locale] = Intl.NumberFormat.supportedLocalesOf(value, {localeMatcher: 'lookup'});
    if (locale) return locale;
  } catch { /* Malformed locale tags also fail configuration validation. */ }
  throw new MountFailure('invalid_configuration');
}

function pin(options: unknown, mounting: boolean) {
  if (!object(options) || Object.keys(options).some(key =>
    !['target', 'context', 'theme', 'locale', ...(mounting ? ['provider', 'styleNonce', 'onEvent'] : [])].includes(key))) throw new MountFailure('invalid_configuration');
  const target = pinTarget(options.target);
  const ctx = options.context;
  if (!object(ctx) || Object.keys(ctx).length !== pins.length || !pins.every(key =>
    Object.hasOwn(ctx, key) && typeof ctx[key] === 'string' && ctx[key].length > 0)
    || !['2.0.0', '2.1.0'].includes(String(ctx.contract_version)) || !/^[a-f0-9]{64}$/.test(String(ctx.profile_sha256)))
    throw new MountFailure('invalid_context');
  return {target, context: Object.freeze({...ctx}) as PublicationContext, css: themeRule(options.theme), locale: numberLocale(options.locale)};
}
function scopedProvider(provider: PublicationProvider, context: PublicationContext, life: AbortSignal): PublicationProvider {
  async function call<T>(signal: AbortSignal, read: (combined: AbortSignal) => Promise<T>) {
    const combined = AbortSignal.any([signal, life]);
    combined.throwIfAborted();
    let result: T;
    try { result = await read(combined); }
    catch { throw new MountFailure('read_failed'); }
    combined.throwIfAborted();
    return result;
  }
  async function pinned<T extends {context: PublicationContext}>(signal: AbortSignal, read: (combined: AbortSignal) => Promise<T>) {
    const result = await call(signal, read);
    try { assertSamePublication(context, result.context); }
    catch { throw new MountFailure('context_mismatch'); }
    return result;
  }
  const scoped: PublicationProvider = {
    people: signal => pinned(signal, combined => provider.people(combined)),
    catalogue: (cursor, signal) => pinned(signal, combined => provider.catalogue(cursor, combined)),
    report: (metric, cursor, signal) => pinned(signal, combined => provider.report(metric, cursor, combined)),
  };
  if (provider.select) scoped.select = (id, filters, cursor, signal) => pinned(signal, combined => provider.select!(id, filters, cursor, combined));
  if (provider.search) scoped.search = (q, cursor, signal) => pinned(signal, combined => provider.search!(q, cursor, combined));
  if (provider.lookup) scoped.lookup = (id, signal) => pinned(signal, combined => provider.lookup!(id, combined));
  if (provider.exportEvidence) scoped.exportEvidence = (id, filters, cursor, signal) =>
    call(signal, combined => provider.exportEvidence!(id, filters, cursor, combined));
  return scoped;
}
interface Generation {
  index: number;
  controller: AbortController;
  element: HTMLDivElement;
  root: Root;
  settle: (value: PublicationMountOutcome) => void;
}

const occupied = new WeakSet<HTMLElement>();

export function mountPublicationWorkspace(container: HTMLElement, options: PublicationMountOptions): PublicationMountHandle {
  if (!container?.ownerDocument?.defaultView || !(container instanceof container.ownerDocument.defaultView.HTMLElement))
    throw new MountFailure('invalid_container');
  if (typeof globalThis.crypto?.randomUUID !== 'function' || typeof globalThis.AbortSignal?.any !== 'function'
    || typeof globalThis.AbortSignal.prototype.throwIfAborted !== 'function' || typeof container.attachShadow !== 'function')
    throw new MountFailure('unsupported_environment');
  if (occupied.has(container) || container.hasChildNodes() || container.shadowRoot) throw new MountFailure('container_occupied');
  const initial = pin(options, true), provider = options.provider, onEvent = options.onEvent;
  if (!object(provider) || !['people','catalogue','report'].every(key => typeof provider[key] === 'function')
    || !['lookup','search','select','exportEvidence'].every(key => provider[key] === undefined || typeof provider[key] === 'function')
    || (onEvent !== undefined && typeof onEvent !== 'function')
    || (options.styleNonce !== undefined && (typeof options.styleNonce !== 'string' || !options.styleNonce)))
    throw new MountFailure('invalid_configuration');
  const doc = container.ownerDocument;
  const host = doc.createElement('div');
  const shadow = host.attachShadow({mode: 'open'});
  const style = doc.createElement('style');
  if (options.styleNonce) style.nonce = options.styleNonce;
  shadow.appendChild(style);
  const id = crypto.randomUUID();
  let generation = 0;
  let active: Generation | null = null;
  let destroyed: Promise<void> | null = null;
  function retire(status: 'superseded' | 'destroyed') {
    const previous = active;
    active = null;
    if (!previous) return Promise.resolve();
    previous.element.remove();
    previous.settle({status, generation: previous.index});
    // Unmount outside the host framework's current React commit, if any.
    const cleanup = Promise.resolve().then(() => previous.root.unmount());
    previous.controller.abort();
    return cleanup;
  }
  function start({context, target, css, locale}: ReturnType<typeof pin>): Promise<PublicationMountOutcome> {
    const index = ++generation;
    void retire('superseded');
    // A provider's abort listener can synchronously update or destroy this handle.
    if (destroyed || index !== generation) return Promise.resolve({status: destroyed ? 'destroyed' : 'superseded', generation: index});
    const controller = new AbortController();
    const element = doc.createElement('div');
    element.lang = 'en';
    const stylesheet = styles + css;
    if (style.textContent !== stylesheet) style.textContent = stylesheet;
    shadow.appendChild(element);
    return new Promise<PublicationMountOutcome>((resolve, reject) => {
      const root = createRoot(element, {onUncaughtError() {
        if (active?.index !== index) return;
        controller.abort();
        element.textContent = messages.render_failed;
        reject(new MountFailure('render_failed'));
      }});
      active = {index, controller, element, root, settle: resolve};
      const reads = scopedProvider(provider, context, controller.signal);
      const firstRender = {
        applied() { if (active?.index === index) resolve({status: 'applied', generation: index}); },
        failed(error: unknown) { if (active?.index === index) reject(error instanceof MountFailure ? error : new MountFailure('read_failed')); },
      };
      const onConcept = onEvent && ((type: PublicationConceptEvent['type'], payload: PublicationConceptEvent['payload'], correlationId: string) => {
        if (active?.index !== index || controller.signal.aborted) return;
        onEvent({event_version: '1.0.0', type, event_id: crypto.randomUUID(), correlation_id: correlationId,
          origin: 'user', instance_id: id, generation: index, context, payload: {...payload}});
      });
      root.render(target.kind === 'workspace'
        ? <PublicationWorkspace provider={reads} locale={locale} instanceKey={id} onConcept={onConcept} firstRender={firstRender}/>
        : <DirectPublicationView provider={reads} locale={locale} direct={{target, context}} onConcept={onConcept} firstRender={firstRender}/>);
    });
  }
  container.appendChild(host);
  occupied.add(container);
  const ready = start(initial);
  return {
    id, ready,
    async update(next) {
      if (destroyed) throw new MountFailure('instance_destroyed');
      return start(pin(next, false));
    },
    destroy() {
      if (!destroyed) {
        let cleanup: Promise<void>;
        destroyed = Promise.resolve().then(() => cleanup);
        host.remove();
        occupied.delete(container);
        cleanup = retire('destroyed');
      }
      return destroyed;
    },
  };
}
