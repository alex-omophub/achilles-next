import React, {useLayoutEffect, useRef, useState} from 'react';
import {createRoot} from 'react-dom/client';

// These URLs belong to the test host's deployment. Neither host imports viewer source.
const at = path => new URL(path, document.baseURI).href;
const {mountPublicationWorkspace, createPublicationHttpProvider} = await import(/* @vite-ignore */ at('extensions/achilles/publication-workspace.mjs'));
const {createApp, h, onBeforeUnmount, onMounted, ref} = await import(/* @vite-ignore */ at('vue.mjs'));
const pins = await (await fetch(at('admissions.json'))).json();
const apis = Object.fromEntries(Object.keys(pins).map(key =>
  [key, createPublicationHttpProvider(new URL('sources/' + key + '/api/', document.baseURI))]));
const target = {kind: 'workspace', version: '2'};
const sessions = {};
const events = {react: [], vue: []};
const nextTargets = {};
window.fixture = {
  events: host => events[host],
  nextMount(host, next) { nextTargets[host] = next; },
  ready: host => sessions[host].handle.ready,
  id: host => sessions[host].handle.id,
  occupyAgain(host) {
    const {slot, provider, source} = sessions[host];
    try { mountPublicationWorkspace(slot, {provider, context: pins[source], target}); }
    catch (error) { return error.code; }
  },
  update(host, source, pin = source) {
    const current = sessions[host];
    current.source = source;
    return current.handle.update({context: pins[pin], target});
  },
  direct(host, kind, metric_id, metric_version = '1.0.0', pin) {
    const current = sessions[host];
    return current.handle.update({context: pins[pin ?? current.source], target: {kind, version: '2', metric_id, metric_version}});
  },
  invalid: host => sessions[host].handle.update({context: pins.first, target: {kind: 'workspace', version: '999'}}),
  invalidContext: host => sessions[host].handle.update({context: {...pins.first, contract_version: '9.0.0'}, target}),
  hold(host, source) {
    const current = sessions[host];
    current.holdNext = true;
    current.pending = this.update(host, source);
  },
  held: host => !!sessions[host].release,
  aborted: host => sessions[host].heldSignal.aborted,
  release(host) {
    const current = sessions[host];
    current.release();
    current.release = null;
    return current.pending;
  },
  destroy(host) {
    const {handle} = sessions[host];
    const cleanup = handle.destroy();
    return {samePromise: cleanup === handle.destroy()};
  },
};

function attach(host, slot, source) {
  const current = {source, slot};
  // The host may replace its authenticated route while keeping the provider identity stable.
  const api = () => apis[current.source];
  const provider = {
    people: async signal => {
      const result = await api().people(signal);
      if (current.holdNext) {
        current.holdNext = false;
        current.heldSignal = signal;
        // Deliberately deliver an already-authorized response after update/destroy.
        await new Promise(resolve => { current.release = resolve; });
      }
      return result;
    },
    catalogue: (cursor, signal) => api().catalogue(cursor, signal),
    report: (metric, cursor, signal) => api().report(metric, cursor, signal),
  };
  current.provider = provider;
  current.handle = mountPublicationWorkspace(slot, {provider, context: pins[source], target: nextTargets[host] ?? target, styleNonce: 'fixture-style',
    onEvent: event => events[host].push(event)});
  sessions[host] = current;
  return () => { void current.handle.destroy(); };
}

function ReactSlot() {
  const slot = useRef(null);
  useLayoutEffect(() => attach('react', slot.current, 'first'), []);
  return <div aria-label="React slot" role="region" ref={slot}/>;
}
function ReactHost() {
  const [mounted, setMounted] = useState(true);
  return <><button onClick={() => setMounted(!mounted)}>Toggle React workspace</button>{mounted && <ReactSlot/>}</>;
}
const VueSlot = {setup() {
  const slot = ref(null);
  let detach;
  onMounted(() => { detach = attach('vue', slot.value, 'second'); });
  onBeforeUnmount(() => detach());
  return () => h('div', {role: 'region', 'aria-label': 'Vue slot', ref: slot});
}};
createRoot(document.getElementById('react-host')).render(<ReactHost/>);
createApp({setup() {
  const mounted = ref(true);
  return () => [h('button', {onClick: () => { mounted.value = !mounted.value; }}, 'Toggle Vue workspace'),
    mounted.value ? h(VueSlot) : null];
}}).mount('#vue-host');
