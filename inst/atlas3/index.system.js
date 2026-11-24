// ATLAS3 v3 loads a SystemJS parcel and supplies a unique name for each mount.
System.register([], function (exports, module) {
  const instances = new Map();
  const occupied = new WeakSet();
  const entry = new URL('./embed/publication-workspace.mjs', module.meta.url);
  const colors = ['ink', 'muted', 'rule', 'surface', 'accent', 'focus'];

  function sourceDirectory(doc, key) {
    // Keep the host key a single, unambiguous gateway and navigation segment.
    if (typeof key !== 'string' || key.length > 255 || !/^[\p{L}\p{N}][\p{L}\p{N}_.:-]*$/u.test(key))
      throw new Error('Invalid source key.');
    const directory = new URL('achilles-results/v2/' + encodeURIComponent(key) + '/', doc.baseURI);
    const origin = doc.defaultView.location.origin;
    if (!['https:', 'http:'].includes(directory.protocol) || directory.origin !== origin || entry.origin !== origin)
      throw new Error('Invalid deployment origin.');
    return directory;
  }

  function palette(slot) {
    const style = slot.ownerDocument.defaultView.getComputedStyle(slot);
    const theme = {};
    for (const token of colors) {
      const value = style.getPropertyValue('--achillesnext-' + token).trim();
      if (/^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i.test(value)) theme[token] = value;
    }
    return theme;
  }

  function retire(state) {
    const session = state.session;
    state.session = null;
    return session?.handle?.destroy();
  }

  function unavailable(state, error) {
    void retire(state);
    const message = state.slot.ownerDocument.createElement('p');
    message.setAttribute('role', 'alert');
    switch (error?.code) {
      case 'authentication_required': message.textContent = 'Sign in to view this publication.'; break;
      case 'access_denied': message.textContent = 'Access to this publication was denied.'; break;
      default: message.textContent = 'The selected publication could not be opened.'; break;
    }
    state.slot.replaceChildren(message);
    state.slot.hidden = false;
  }

  async function waitForAdmission(check, signal) {
    signal.throwIfAborted();
    let abort;
    const aborted = new Promise((_, reject) => {
      abort = () => reject(signal.reason);
      signal.addEventListener('abort', abort, {once: true});
    });
    try {
      await Promise.race([check.finished, aborted]);
    } finally {
      signal.removeEventListener('abort', abort);
    }
  }

  // A provider response may arrive while the host is refreshing permissions.
  // Release it only if the same viewer session survives re-admission.
  function guardReads(provider, state, session) {
    const guarded = {};
    for (const [name, read] of Object.entries(provider)) {
      guarded[name] = async (...args) => {
        const signal = args.at(-1);
        try {
          const result = await read(...args);
          while (state.check && state.session === session && !signal.aborted) await waitForAdmission(state.check, signal);
          signal.throwIfAborted();
          if (state.session !== session) throw new DOMException('Session closed.', 'AbortError');
          return result;
        } catch (error) {
          if (!signal.aborted && state.session === session) {
            session.failed = true;
            if (error?.code === 'access_denied' || error?.code === 'authentication_required') unavailable(state, error);
          }
          throw error;
        }
      };
    }
    return guarded;
  }

  async function admit(state, host, check) {
    const {signal} = check.controller;
    const source = host.sourceKey;
    const base = sourceDirectory(state.slot.ownerDocument, source);
    const theme = palette(state.slot);
    const locale = host.locale || state.props.locale || 'en';
    const binding = JSON.stringify([source, [...host.permissions].sort(), locale, theme]);
    if (state.session?.binding !== binding) await retire(state);
    signal.throwIfAborted();
    const viewer = await import(entry.href);
    signal.throwIfAborted();
    const authorization = {getToken: () => state.props.getToken()};
    const context = await viewer.readPublicationAdmission(base, authorization, signal);
    signal.throwIfAborted();
    const previous = state.session;
    if (previous && !previous.failed && previous.binding === binding &&
        Object.keys(context).every(key => context[key] === previous.context[key])) return;
    await retire(state);
    signal.throwIfAborted();
    state.slot.replaceChildren();
    const session = {binding, context, failed: false, handle: null};
    state.session = session;
    const provider = viewer.createPublicationHttpProvider(new URL('api/', base), authorization);
    session.handle = viewer.mountPublicationWorkspace(state.slot, {
      context, theme, locale, target: {kind: 'workspace', version: '2'},
      provider: guardReads(provider, state, session),
      onEvent(event) {
        if (state.session === session && !state.check && event.type === 'navigation_requested') {
          const path = '/concept/' + encodeURIComponent(source) + '/' + encodeURIComponent(event.payload.concept_id);
          state.props.messageBus.send('navigation:request', {path});
        }
      },
    });
    session.handle.ready.catch(error => {
      if (state.session === session) unavailable(state, error);
    });
  }

  function recheck(state, host) {
    state.host = host;
    state.slot.hidden = true;
    const previous = state.check;
    let finish;
    const finished = new Promise(resolve => { finish = resolve; });
    const check = {controller: new AbortController(), finished, finish};
    state.check = check;
    previous?.controller.abort();
    previous?.finish();
    // ATLAS serializes parcel lifecycle calls. Let a later update or unmount
    // cancel admission without waiting for the host's token or the gateway.
    void admit(state, host, check).catch(error => {
      if (state.check === check) unavailable(state, error);
    }).finally(() => {
      if (state.check === check) {
        state.check = null;
        state.slot.hidden = false;
      }
      check.finish();
    });
  }

  async function mount(props) {
    if (!props.name || instances.has(props.name) || occupied.has(props.domElement))
      throw new Error('The ATLAS3 publication outlet is already occupied or unnamed.');
    const slot = props.domElement.ownerDocument.createElement('div');
    slot.className = 'achillesnext-atlas3';
    const state = {props, slot, session: null, check: null, host: props.hostContext};
    state.invalidate = () => {
      void retire(state);
      recheck(state, state.host);
    };
    props.domElement.appendChild(slot);
    instances.set(props.name, state);
    occupied.add(props.domElement);
    slot.ownerDocument.defaultView.addEventListener('achillesnext:access-changed', state.invalidate);
    recheck(state, props.hostContext);
  }

  async function update(props) {
    const state = instances.get(props.name);
    if (state) recheck(state, props.hostContext);
  }

  async function unmount(props) {
    const state = instances.get(props.name);
    if (!state) return;
    instances.delete(props.name);
    occupied.delete(state.props.domElement);
    state.slot.ownerDocument.defaultView.removeEventListener('achillesnext:access-changed', state.invalidate);
    const check = state.check;
    state.check = null;
    check?.controller.abort();
    check?.finish();
    state.slot.remove();
    await retire(state);
  }

  return {execute() { exports({bootstrap: async () => {}, mount, update, unmount}); }};
});
