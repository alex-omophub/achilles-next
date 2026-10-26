import test from 'node:test';
import assert from 'node:assert/strict';
import {createFetchResultProvider, ResultAccessError} from '../src/index.mjs';

const context = {source_id:'fixture:tiny_a', bundle_id:'fixture-1', manifest_sha256:'0'.repeat(64),
  access_scope_id:'scope', authorization_epoch:'epoch'};
const options = () => ({signal:new AbortController().signal,requestId:'read-1'});

test('HTTP provider preserves exact bytes and obtains current host authorization for every request', async () => {
  const bytes = new TextEncoder().encode('{"count":"9007199254740993"}');
  const calls = [];let token = 'fixture-token-a';
  const provider = createFetchResultProvider({baseUrl:'https://example.test/results/v1',
    getHeaders:async()=>({Authorization:`Bearer ${token}`}),
    fetch:async(url,init)=>{calls.push({url,init});return new Response(bytes);}});
  assert.deepEqual(await provider.getResult(context,'person.count',options()),bytes);
  token='fixture-token-b';await provider.getManifest(context,options());
  await provider.getTerminology(context,options());
  assert.equal(calls[0].url.pathname,'/results/v1/sources/fixture%3Atiny_a/bundles/fixture-1/results/person.count.json');
  assert.equal(calls[0].init.headers.get('Authorization'),'Bearer fixture-token-a');
  assert.equal(calls[1].init.headers.get('Authorization'),'Bearer fixture-token-b');
  assert.ok(calls.every(c=>c.init.cache==='no-store' && c.init.redirect==='error' && !c.url.href.includes('token')));
});

test('denied and missing results remain explicit errors without exposing response bodies', async () => {
  for(const [status,code] of [[401,'UNAUTHENTICATED'],[403,'INACCESSIBLE'],[404,'NOT_FOUND'],[500,'PROVIDER_FAILURE']]) {
    const provider = createFetchResultProvider({baseUrl:'https://example.test/',
      fetch:async()=>new Response('remote-secret',{status})});
    await assert.rejects(provider.getManifest(context,options()),e=>e instanceof ResultAccessError &&
      e.status===status && e.code===code && !e.message.includes('remote-secret'));
  }
});

test('cancellation prevents a request after pending authorization resolves', async () => {
  let resolveHeaders,calls=0;const controller=new AbortController();
  const provider=createFetchResultProvider({baseUrl:'https://example.test/',
    getHeaders:()=>new Promise(resolve=>resolveHeaders=resolve),
    fetch:async()=>{calls++;return new Response('{}');}});
  const pending=provider.getManifest(context,{signal:controller.signal,requestId:'cancel'});
  controller.abort();resolveHeaders({});await assert.rejects(pending,e=>e.name==='AbortError');assert.equal(calls,0);
});

test('transport failures and credential-bearing base URLs cannot expose secrets', async () => {
  assert.throws(()=>createFetchResultProvider({baseUrl:'https://user:secret@example.test/'}),TypeError);
  const provider=createFetchResultProvider({baseUrl:'https://example.test/',
    fetch:async()=>{throw new Error('secret-token in transport exception');}});
  await assert.rejects(provider.getManifest(context,options()),e=>e.code==='PROVIDER_FAILURE' && !e.message.includes('secret-token'));
});

test('source or bundle dot segments cannot redirect an authenticated gateway request', async () => {
  let calls=0;const provider=createFetchResultProvider({baseUrl:'https://example.test/results/v1/',
    fetch:async()=>{calls++;return new Response('{}');}});
  for(const bad of [{...context,source_id:'..'},{...context,bundle_id:'.'}])
    await assert.rejects(provider.getManifest(bad,options()),e=>e.code==='PROVIDER_FAILURE');
  assert.equal(calls,0);
});
