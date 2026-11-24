import {beforeEach, expect, it, vi} from 'vitest';
import {mountPublicationWorkspace, type PublicationConceptEvent, type PublicationContext, type PublicationProvider} from '../src/mount-publication';

interface Frame {
  props: {provider: PublicationProvider; onConcept?: (type: PublicationConceptEvent['type'],
    payload: PublicationConceptEvent['payload'], correlation: string) => void; firstRender: {applied(): void; failed(error: unknown): void}};
}
const renderer = vi.hoisted(() => ({frames: [] as Frame[], unmount: vi.fn()}));
vi.mock('react-dom/client', () => ({createRoot: () => ({
  render: (frame: Frame) => renderer.frames.push(frame), unmount: renderer.unmount,
})}));

// This harness controls React's commit notification and provider completions.
// Real DOM commit, shadow style and host-framework isolation are browser tests.
class Element {
  parent: Element | null = null;
  shadowRoot: Element | null = null;
  children: Element[] = [];
  ownerDocument = document;
  hasChildNodes() { return this.children.length > 0; }
  appendChild(child: Element) { this.children.push(child); child.parent = this; }
  attachShadow() { this.shadowRoot = new Element(); return this.shadowRoot; }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(item => item !== this); this.parent = null; }
}
const document = {defaultView: {HTMLElement: Element}, createElement: () => new Element()};
const context: PublicationContext = {
  contract_version: '2.0.0', source_id: 'fixture:one', release_id: 'release', publication_id: 'publication',
  access_scope_id: 'approved', profile_id: 'core-characterization-v2', profile_sha256: 'a'.repeat(64),
  profile_revision: '2.0.0', authorization_epoch: 'epoch', instance_id: 'provider-instance',
};
const target = {kind: 'workspace', version: '2'} as const;
const fixture = () => ({
  provider: {people: vi.fn(), catalogue: vi.fn(), report: vi.fn()}, context: {...context}, target,
});
const container = () => new Element() as unknown as HTMLElement;
const frame = () => renderer.frames.at(-1)!.props;
beforeEach(() => { renderer.frames.length = 0; renderer.unmount.mockClear(); });

it('preserves a pending mount on invalid update, then settles only after the verified commit', async () => {
  const node = container(), options = fixture(), handle = mountPublicationWorkspace(node, options);
  expect(() => mountPublicationWorkspace(node, options)).toThrow(expect.objectContaining({code: 'container_occupied'}));
  await expect(handle.update({target, context: {...context, instance_id: ''}})).rejects.toMatchObject({code: 'invalid_context'});
  let applied = false;
  void handle.ready.then(() => { applied = true; });
  options.provider.people.mockResolvedValue({context});
  await frame().provider.people(new AbortController().signal);
  expect(applied).toBe(false);
  frame().firstRender.applied();
  await expect(handle.ready).resolves.toEqual({status: 'applied', generation: 1});
  const end = handle.destroy();
  expect(handle.destroy()).toBe(end);
  expect(node.hasChildNodes()).toBe(false);
  await end;
  await expect(handle.update({context, target})).rejects.toMatchObject({code: 'instance_destroyed'});
});

it('pins a copy independently of host mutation and rejects a mismatched provider without returning data', async () => {
  const options = fixture(), handle = mountPublicationWorkspace(container(), options);
  options.context.source_id = 'different';
  options.provider.people.mockResolvedValue({context: options.context});
  const failure = await frame().provider.people(new AbortController().signal).catch(error => error);
  expect(failure).toMatchObject({code: 'context_mismatch'});
  frame().firstRender.failed(failure);
  await expect(handle.ready).rejects.toMatchObject({code: 'context_mismatch'});
  await handle.destroy();
});

it('supersedes the outer update if a provider abort listener starts a newer generation', async () => {
  const options = fixture(), handle = mountPublicationWorkspace(container(), options);
  let newest: ReturnType<typeof handle.update> | undefined;
  options.provider.people.mockImplementation(signal => {
    signal.addEventListener('abort', () => { newest = handle.update({context, target}); }, {once: true});
    return new Promise(() => {});
  });
  void frame().provider.people(new AbortController().signal);
  const replaced = handle.update({context, target});
  expect(await handle.ready).toEqual({status: 'superseded', generation: 1});
  expect(await replaced).toEqual({status: 'superseded', generation: 2});
  expect(renderer.frames).toHaveLength(2);
  frame().firstRender.applied();
  expect(await newest).toEqual({status: 'applied', generation: 3});
  await handle.destroy();
});

it('closes the handle before a destroy abort listener can reopen it', async () => {
  const node = container(), options = fixture(), handle = mountPublicationWorkspace(node, options);
  let attempted: ReturnType<typeof handle.update> | undefined;
  options.provider.catalogue.mockImplementation((_cursor, signal) => {
    signal.addEventListener('abort', () => { attempted = handle.update({context, target}); }, {once: true});
    return new Promise(() => {});
  });
  void frame().provider.catalogue(null, new AbortController().signal);
  const teardown = handle.destroy();
  await expect(attempted).rejects.toMatchObject({code: 'instance_destroyed'});
  expect(await handle.ready).toEqual({status: 'destroyed', generation: 1});
  await teardown;
  expect(renderer.frames).toHaveLength(1);
  expect(node.hasChildNodes()).toBe(false);
});

it('pins the direct target on initial mount and preserves it after an invalid update', async () => {
  const options = fixture();
  const target = {kind: 'chart' as const, version: '2' as const, metric_id: 'core.person.birth_year_count', metric_version: '1.0.0'};
  const handle = mountPublicationWorkspace(container(), {...options, target});
  const expected = {...target};
  target.metric_id = 'core.person.gender_count';
  expect(frame()).toMatchObject({direct: {target: expected, context}});
  for (const invalid of [{metric_id: '../people'}, {metric_version: ''}, {unexpected: true}]) {
    await expect(handle.update({context, target: {...target, ...invalid}})).rejects.toMatchObject({code: 'invalid_configuration'});
  }
  expect(renderer.frames).toHaveLength(1);
  frame().firstRender.applied();
  expect(await handle.ready).toEqual({status: 'applied', generation: 1});
  await handle.destroy();
});


it('contains concept actions within the live generation and drops retired callbacks', async () => {
  const events: PublicationConceptEvent[] = [];
  const options = fixture();
  const handle = mountPublicationWorkspace(container(), {...options, onEvent: event => events.push(event)});
  const first = frame().onConcept!;
  const payload = {target: 'concept' as const, metric_id: 'core.person.gender_count',
    metric_version: '1.0.0', dimension: 'gender_concept_id', concept_id: '9007199254740993'};
  const next = handle.update({context: {...context, authorization_epoch: 'new'}, target});
  first('concept_selected', payload, 'retired');
  expect(events).toHaveLength(0);
  const current = frame().onConcept!;
  current('concept_selected', payload, 'interaction');
  expect(events[0]).toMatchObject({generation: 2, instance_id: handle.id, origin: 'user',
    context: {authorization_epoch: 'new'}, payload, event_version: '1.0.0'});
  await handle.destroy();
  current('navigation_requested', payload, 'interaction');
  expect(events).toHaveLength(1);
  expect((await next).status).toBe('destroyed');
});

it('validates presentation before changing a generation or touching the host', async () => {
  const options = fixture(), node = container();
  for (const presentation of [{theme: {other: '#abc'}}, {theme: {ink: 'red'}}, {theme: null},
    {theme: []}, {locale: 'en US'}, {locale: 'zz-ZZ'}, {locale: 7}]) {
    expect(() => mountPublicationWorkspace(node, {...options, ...presentation} as typeof options))
      .toThrow(expect.objectContaining({code: 'invalid_configuration'}));
    expect(node.hasChildNodes()).toBe(false);
  }
  const theme = {accent: '#abc'};
  const handle = mountPublicationWorkspace(node, {...options, theme, locale: 'PT-pt'});
  theme.accent = '#def';
  expect(frame()).toMatchObject({locale: 'pt-PT'});
  await expect(handle.update({context, target, theme: {focus: 'invalid'}})).rejects.toMatchObject({code: 'invalid_configuration'});
  expect(renderer.frames).toHaveLength(1);
  frame().firstRender.applied();
  expect(await handle.ready).toEqual({status: 'applied', generation: 1});
  await handle.destroy();
});
