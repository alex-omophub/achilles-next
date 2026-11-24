import assert from 'node:assert/strict';
import {register} from 'node:module';
import {beforeEach, test} from 'node:test';
import {setImmediate} from 'node:timers/promises';
import {admissions, mounts, providers, reads} from './viewer.mjs';

const hostUrl = 'https://atlas.example.test/institution/atlas/';
const entry = hostUrl + 'plugins/achilles-next/index.system.js';
const viewer = new URL('embed/publication-workspace.mjs', entry).href;
const fixture = new URL('./viewer.mjs', import.meta.url).href;

// Resolve precisely the sibling resource the browser would fetch. Load the
// shipped parcel unchanged and drive it with the reduced props ATLAS3 sends.
const resolver = `
  export function resolve(specifier, context, next) {
    if (specifier === ${JSON.stringify(viewer)}) return {url: ${JSON.stringify(fixture)}, shortCircuit: true};
    return next(specifier, context);
  }
`;
register('data:text/javascript,' + encodeURIComponent(resolver));

let declare;
globalThis.System = {register(dependencies, factory) { assert.deepEqual(dependencies, []); declare = factory; }};
await import('../../../../inst/atlas3/index.system.js');
delete globalThis.System;

class Element {
  ownerDocument = document;
  children = [];
  attributes = new Map();
  parentElement = null;
  hidden = false;
  text = '';
  get textContent() { return this.text + this.children.map(child => child.textContent).join(''); }
  set textContent(value) { this.replaceChildren(); this.text = value; }
  append(...children) {
    for (const child of children) { this.children.push(child); child.parentElement = this; }
  }
  appendChild(child) { this.append(child); return child; }
  remove() {
    if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(node => node !== this);
    this.parentElement = null;
  }
  replaceChildren(...children) { this.children.forEach(child => { child.parentElement = null; }); this.children = []; this.text = ''; this.append(...children); }
  setAttribute(name, value) { this.attributes.set(name, value); }
}
const document = {
  baseURI: hostUrl, createElement: () => new Element(),
  defaultView: null,
};

const context = {
  source_id: 'analytical:id', release_id: 'test-release', publication_id: 'published-result',
  contract_version: '2.1.0', profile_id: 'test-profile', profile_revision: '1', profile_sha256: 'a'.repeat(64),
  instance_id: 'provider-a', authorization_epoch: '1', access_scope_id: 'test-scope',
};

let parcel;
function source(sourceKey) { return {sourceKey, permissions: ['result:read'], locale: 'en', surface: 'datasource-sidebar'}; }
function host(name, key) {
  let token = name + '-login-1';
  const messages = [];
  const props = {
    name, domElement: new Element(), hostContext: source(key), locale: 'en',
    getToken: async () => token, messageBus: {send: (...args) => messages.push(args)},
  };
  return {props, messages, rotate: () => { token = name + '-login-2'; },
    update: key => parcel.update({name, hostContext: source(key)}),
    unmount: () => parcel.unmount({name})};
}

async function until(predicate, label) {
  const deadline = Date.now() + 2000;
  while (!predicate() && Date.now() < deadline) await setImmediate();
  assert.ok(predicate(), label);
}

beforeEach(async () => {
  admissions.length = mounts.length = providers.length = reads.length = 0;
  document.defaultView = Object.assign(new EventTarget(), {
    location: new URL(hostUrl), getComputedStyle: () => ({getPropertyValue: () => ''}),
  });
  parcel = {};
  const expose = (key, value) => typeof key === 'object' ? Object.assign(parcel, key) : (parcel[key] = value);
  declare(expose, {meta: {url: entry}}).execute();
  await parcel.bootstrap();
});
test('host key binds the approved route and repeat admission preserves the mounted workspace', async () => {
  const a = host('parcel-1', 'CDM_A');
  await parcel.mount(a.props);
  await until(() => admissions.length === 1, 'first admission');
  const request = admissions[0];
  assert.equal(request.url.href, hostUrl + 'achilles-results/v2/CDM_A/');
  assert.equal(await request.options.getToken(), 'parcel-1-login-1');
  request.resolve({...context});
  await until(() => mounts.length === 1, 'viewer mount');
  const mounted = mounts[0];
  assert.deepEqual(mounted.options.target, {kind: 'workspace', version: '2'});
  assert.deepEqual(mounted.options.context, context);
  assert.equal(providers[0].url.href, hostUrl + 'achilles-results/v2/CDM_A/api/');

  a.rotate();
  assert.equal(await providers[0].options.getToken(), 'parcel-1-login-2');
  await a.update('CDM_A');
  await until(() => admissions.length === 2, 'repeat admission');
  assert.equal(await admissions[1].options.getToken(), 'parcel-1-login-2');
  admissions[1].resolve({...context});
  await setImmediate();
  assert.equal(mounts.length, 1);
  assert.equal(mounted.updates.length, 0, 'keep the selected report during an equivalent permission refresh');

  await a.update('CDM_A');
  await until(() => admissions.length === 3, 'new approval');
  admissions[2].resolve({...context, instance_id: 'provider-b'});
  await until(() => mounts.length === 2, 'fresh session must rebind');
  assert.equal(mounted.destroyed, true);
  await a.unmount();
  assert.equal(a.props.domElement.children.length, 0);
});

test('overlapping updates and unmount cannot render stale admissions over a peer', async () => {
  const a = host('left', 'A'), b = host('right', 'B');
  await parcel.mount(a.props);
  await until(() => admissions.length === 1, 'left pending');
  await parcel.mount(b.props);
  await until(() => admissions.length === 2, 'right pending');
  admissions[1].resolve({...context, source_id: 'right-source'});
  await until(() => mounts.length === 1, 'right mounted');
  await a.update('C');
  await until(() => admissions.length === 3, 'left switched');
  assert.ok(admissions[0].signal.aborted);
  admissions[0].resolve({...context, source_id: 'obsolete'});
  await a.unmount();
  assert.ok(admissions[2].signal.aborted);
  admissions[2].resolve({...context, source_id: 'late'});
  await setImmediate();
  assert.equal(mounts.length, 1);
  assert.equal(a.props.domElement.children.length, 0);
  assert.equal(b.props.domElement.textContent, 'right-source');
  assert.equal(mounts[0].destroyed, false);
  await b.unmount();
  assert.equal(mounts[0].destroyed, true);
});

test('an unsafe host key cannot request admission; rejected refresh clears prior results', async () => {
  const a = host('parcel', 'CDM');
  await parcel.mount(a.props);
  await until(() => admissions.length === 1, 'initial admission');
  admissions[0].resolve({...context});
  await until(() => mounts.length === 1, 'initial result');
  await a.update('CDM');
  await until(() => admissions.length === 2, 'refresh admission');
  admissions[1].reject(new Error('private gateway detail'));
  await until(() => mounts[0].destroyed, 'denied result retired');
  assert.doesNotMatch(a.props.domElement.textContent, /private gateway detail|analytical:id/);
  for (const key of ['.', '..', 'CDM/other', 'CDM%2fother', 'CDM\\other', 'CDM\n']) await a.update(key);
  await setImmediate();
  assert.equal(admissions.length, 2);
  await a.unmount();
});

test('a permission refresh holds in-flight reads and ignores navigation until the full context is reconfirmed', async () => {
  const a = host('parcel', 'Gateway:1');
  await parcel.mount(a.props);
  await until(() => admissions.length === 1, 'first admission');
  admissions[0].resolve({...context});
  await until(() => mounts.length === 1, 'mounted');
  const mounted = mounts[0];
  const navigate = () => mounted.options.onEvent({type: 'navigation_requested', context,
    payload: {concept_id: '9007199254740993'}});
  const signal = new AbortController().signal;
  const page = mounted.options.provider.people(signal);
  await a.update('Gateway:1');
  await until(() => admissions.length === 2, 'revalidating');
  let visible = false;
  page.then(() => { visible = true; });
  reads[0].resolve({saved: true});
  navigate();
  await setImmediate();
  assert.equal(visible, false);
  assert.deepEqual(a.messages, []);
  admissions[1].resolve({...context});
  assert.deepEqual(await page, {saved: true});
  navigate();
  assert.deepEqual(a.messages, [['navigation:request', {path: '/concept/Gateway%3A1/9007199254740993'}]]);

  const late = mounted.options.provider.people(signal);
  await a.update('Gateway:1');
  await until(() => admissions.length === 3, 'new context pending');
  reads[1].resolve({stale: true});
  admissions[2].resolve({...context, authorization_epoch: '2'});
  await assert.rejects(late, {name: 'AbortError'});
  await until(() => mounts.length === 2, 'new context installed');
  navigate();
  mounted.ready.reject(new Error('previous mount failed late'));
  await setImmediate();
  assert.equal(a.messages.length, 1);
  assert.equal(mounts[1].destroyed, false);
  assert.equal(a.props.domElement.textContent, context.source_id);
  await a.unmount();
});

test('explicit access invalidation retires the session immediately and teardown detaches the host listener', async () => {
  const a = host('parcel', 'Source');
  await parcel.mount(a.props);
  await until(() => admissions.length === 1, 'first admission');
  admissions[0].resolve({...context});
  await until(() => mounts.length === 1, 'mounted');
  const stale = mounts[0].options.provider.people(new AbortController().signal);
  document.defaultView.dispatchEvent(new Event('achillesnext:access-changed'));
  assert.equal(mounts[0].destroyed, true);
  await until(() => admissions.length === 2, 'host invalidation requested admission');
  reads[0].resolve({stale: true});
  await assert.rejects(stale, {name: 'AbortError'});
  admissions[1].reject(Object.assign(new Error('gateway credential detail'), {code: 'authentication_required'}));
  await until(() => /sign in/i.test(a.props.domElement.textContent), 'classified authentication failure');
  assert.doesNotMatch(a.props.domElement.textContent, /gateway credential detail/);
  await a.unmount();
  document.defaultView.dispatchEvent(new Event('achillesnext:access-changed'));
  await setImmediate();
  assert.equal(admissions.length, 2);
});

test('a denied read clears its publication without disclosing provider details', async () => {
  const a = host('parcel', 'CDM');
  await parcel.mount(a.props);
  await until(() => admissions.length === 1, 'initial admission');
  admissions[0].resolve({...context});
  await until(() => mounts.length === 1, 'mounted');
  const denied = mounts[0].options.provider.people(new AbortController().signal);
  reads[0].reject(Object.assign(new Error('private gateway detail'), {code: 'access_denied'}));
  await assert.rejects(denied, {code: 'access_denied'});
  assert.ok(mounts[0].destroyed);
  assert.match(a.props.domElement.textContent, /denied/i);
  assert.doesNotMatch(a.props.domElement.textContent, /private gateway detail|analytical:id/);
  await a.unmount();
});

test('a read canceled while re-admission is pending settles before the gateway responds', async () => {
  const a = host('parcel', 'CDM');
  await parcel.mount(a.props);
  await until(() => admissions.length === 1, 'first admission');
  admissions[0].resolve({...context});
  await until(() => mounts.length === 1, 'mounted');
  const controller = new AbortController();
  const pending = mounts[0].options.provider.people(controller.signal);
  await a.update('CDM');
  await until(() => admissions.length === 2, 'pending re-admission');
  reads[0].resolve({saved: true});
  await setImmediate();
  const outcome = pending.then(() => 'delivered', error => error.name);
  controller.abort();
  try {
    assert.equal(await Promise.race([outcome, setImmediate().then(() => 'pending')]), 'AbortError');
  } finally {
    await a.unmount();
    admissions[1].resolve({...context});
  }
});

test('a host refresh recovers a failed provider on an otherwise identical binding', async () => {
  const a = host('parcel', 'CDM');
  await parcel.mount(a.props);
  await until(() => admissions.length === 1, 'first admission');
  admissions[0].resolve({...context});
  await until(() => mounts.length === 1, 'mounted');
  const pending = mounts[0].options.provider.people(new AbortController().signal);
  reads[0].reject(new Error('network unavailable'));
  await assert.rejects(pending, /network unavailable/);
  await a.update('CDM');
  await until(() => admissions.length === 2, 'recovery admission');
  admissions[1].resolve({...context});
  await until(() => mounts.length === 2, 'fresh workspace after read failure');
  assert.equal(mounts[0].destroyed, true);
  await a.unmount();
});
