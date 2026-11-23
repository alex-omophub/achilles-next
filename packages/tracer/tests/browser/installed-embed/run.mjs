import assert from 'node:assert/strict';
import {cp, copyFile, readFile, writeFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {build, preview} from 'vite';

const require = createRequire(import.meta.url);
const [scratch, installedEmbed, ...urls] = process.argv.slice(2);
const site = join(scratch, 'site');
const hostDir = join(site, 'host', 'demo');
const vite = {root: scratch, configFile: false, cacheDir: join(scratch, 'vite-cache'), publicDir: false, logLevel: 'error'};
await build({...vite, define: {'process.env.NODE_ENV': '"production"'}, build: {
  target: 'esnext', outDir: hostDir, emptyOutDir: true,
  lib: {entry: fileURLToPath(new URL('host.jsx', import.meta.url)), formats: ['es'], fileName: () => 'host.mjs'},
}});
await cp(installedEmbed, join(hostDir, 'extensions', 'achilles'), {recursive: true});
const vuePackage = require.resolve('vue/package.json');
assert.equal(require(vuePackage).version, '3.5.39');
await copyFile(join(dirname(vuePackage), 'dist', 'vue.runtime.esm-browser.prod.js'), join(hostDir, 'vue.mjs'));
const pins = {}, proxy = {};
for (const [index, key] of ['first', 'second'].entries()) {
  const url = new URL(urls[index]);
  assert.equal(url.hostname, '127.0.0.1');
  const authorized = JSON.parse(await readFile(join(scratch, key + '-context.json'), 'utf8'));
  const {contract_version, source_id, release_id, publication_id, access_scope_id, profile_id, profile_sha256,
    profile_revision, authorization_epoch, instance_id} = authorized;
  pins[key] = {contract_version, source_id, release_id, publication_id, access_scope_id,
    profile_id, profile_sha256, profile_revision, authorization_epoch, instance_id};
  assert.equal(source_id, 'fixture:' + key);
  const prefix = '/host/demo/sources/' + key + '/';
  proxy[prefix] = {target: url.origin, changeOrigin: true, rewrite: path => url.pathname + path.slice(prefix.length)};
}
assert.notEqual(pins.first.instance_id, pins.second.instance_id);
await writeFile(join(hostDir, 'admissions.json'), JSON.stringify(pins));
await writeFile(join(hostDir, 'index.html'), `<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Installed workspace host</title><style>.publication-summary { display: none !important; }</style></head>
<body><header>Host navigation</header><section class="publication-summary" id="host-sentinel">Host sentinel</section>
<div id="react-host"></div><div id="vue-host"></div><script type="module" src="./host.mjs"></script></body></html>`);
const server = await preview({...vite, build: {outDir: site}, preview: {host: '127.0.0.1', port: 0, proxy}});
let browser;
try {
  browser = await require('playwright').chromium.launch({executablePath: process.env.ACHILLES_NEXT_TEST_CHROME});
  const page = await browser.newPage({viewport: {width: 1120, height: 820}});
  const errors = [], assets = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('request', r => assets.push(new URL(r.url())));
  page.setDefaultTimeout(10000);
  const href = 'http://127.0.0.1:' + server.httpServer.address().port + '/host/demo/index.html#/host-owned-route';
  await page.goto(href);
  const react = page.getByRole('region', {name: 'React slot', exact: true});
  const vue = page.getByRole('region', {name: 'Vue slot', exact: true});
  for (const [name, slot, key] of [['react', react, 'first'], ['vue', vue, 'second']]) {
    await slot.waitFor();
    assert.deepEqual(await page.evaluate(n => window.fixture.ready(n), name), {status: 'applied', generation: 1});
    await slot.getByText('fixture:' + key, {exact: true}).waitFor();
    assert.equal(await slot.evaluate(node => node.firstElementChild.shadowRoot.querySelector('style').nonce), 'fixture-style');
    assert.equal(await page.evaluate(n => fixture.occupyAgain(n), name), 'container_occupied');
    await slot.getByRole('combobox', {name: 'Domain or section'}).selectOption('measurement');
    const metric = 'core.measurement.numeric_summary';
    await slot.getByRole('button', {name: metric, exact: true}).press('Enter');
    await slot.getByRole('table', {name: 'Saved rows for ' + metric}).getByText('2.5', {exact: true}).first().waitFor();
    await slot.getByRole('figure', {name: /Measurement distribution/}).locator('.recharts-line-dot').first().waitFor();
  }
  const peerChart = vue.getByRole('figure', {name: /Measurement distribution/});
  const peerWidth = (await peerChart.boundingBox()).width;
  await react.evaluate(node => { node.style.width = '340px'; });
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const narrowChart = await react.locator('svg.recharts-surface').boundingBox();
  assert(narrowChart && narrowChart.width > 0 && narrowChart.width <= 340);
  assert.equal((await peerChart.boundingBox()).width, peerWidth);
  const hostState = () => page.evaluate(() => ({
    headStyles: document.head.querySelectorAll('style,link[rel=stylesheet]').length,
    summaries: document.querySelectorAll('.publication-summary').length,
    sentinel: getComputedStyle(document.getElementById('host-sentinel')).display,
    header: document.querySelector('header').textContent,
  }));
  assert.deepEqual(await hostState(), {headStyles: 1, summaries: 1, sentinel: 'none', header: 'Host navigation'});
  assert.notEqual(await page.evaluate(() => fixture.id('vue')), await page.evaluate(() => fixture.id('react')));
  for (const [method, code] of [['invalid', 'invalid_configuration'], ['invalidContext', 'invalid_context']]) {
    assert.equal(await page.evaluate(async m => {
      try { await fixture[m]('react'); } catch (error) { return error.code; }
    }, method), code);
  }
  await react.getByRole('figure', {name: /Measurement distribution/}).waitFor();

  await page.evaluate(() => fixture.hold('react', 'second'));
  await page.waitForFunction(() => fixture.held('react'));
  assert.deepEqual(await page.evaluate(() => fixture.update('react', 'first')), {status: 'applied', generation: 3});
  assert(await page.evaluate(() => fixture.aborted('react')));
  assert.deepEqual(await page.evaluate(() => fixture.release('react')), {status: 'superseded', generation: 2});
  await react.getByText('fixture:first', {exact: true}).waitFor();
  assert.equal(await react.getByRole('figure').count(), 0);
  await vue.getByRole('figure', {name: /Measurement distribution/}).waitFor();

  assert.deepEqual(await page.evaluate(() => fixture.update('react', 'second')), {status: 'applied', generation: 4});
  await react.getByText('fixture:second', {exact: true}).waitFor();
  assert.equal(await react.getByText('fixture:first', {exact: true}).count(), 0);

  const mismatch = await page.evaluate(async () => {
    try { await fixture.update('react', 'second', 'first'); } catch (e) { return e.code; }
  });
  assert.equal(mismatch, 'context_mismatch');
  assert.equal(await react.getByText('fixture:second', {exact: true}).count(), 0);
  await page.evaluate(() => fixture.hold('react', 'first'));
  await page.waitForFunction(() => fixture.held('react'));
  assert.deepEqual(await page.evaluate(() => fixture.destroy('react')), {samePromise: true});
  assert.equal(await react.evaluate(slot => slot.childElementCount), 0);
  assert(await page.evaluate(() => fixture.aborted('react')));
  assert.deepEqual(await page.evaluate(() => fixture.release('react')), {status: 'destroyed', generation: 6});
  assert.equal(await page.evaluate(async () => {
    try { await fixture.update('react', 'first'); } catch (e) { return e.code; }
  }), 'instance_destroyed');

  for (const [name, slot, key] of [['React', react, 'first'], ['Vue', vue, 'second']]) {
    const toggle = page.getByRole('button', {name: 'Toggle ' + name + ' workspace'});
    await toggle.click();
    await slot.waitFor({state: 'detached'});
    await toggle.click();
    await slot.getByText('fixture:' + key, {exact: true}).waitFor();
    await slot.getByRole('heading', {name: 'Metric catalogue'}).waitFor();
    assert.equal(await slot.getByRole('figure').count(), 0);
  }
  for (const [host, slot, source] of [['react', react, 'first'], ['vue', vue, 'second']]) {
    const metric = 'core.measurement.numeric_summary';
    for (const kind of ['report', 'chart']) {
      const before = assets.length;
      const outcome = await page.evaluate(args => fixture.direct(...args), [host, kind, metric]);
      assert.equal(outcome.status, 'applied');
      await slot.getByRole('region', {name: 'Saved ' + kind + ' view'}).waitFor();
      await slot.getByRole('figure', {name: /Measurement distribution/}).locator('.recharts-line-curve').waitFor();
      if (kind === 'chart') await slot.getByText('Exact saved rows', {exact: true}).click();
      await slot.getByRole('table', {name: 'Saved rows for ' + metric}).getByText('2.5', {exact: true}).first().waitFor();
      assert.equal(await slot.getByRole('combobox', {name: 'Domain or section'}).count(), 0);
      assert.deepEqual(assets.slice(before).map(url => url.pathname).filter(path => path.includes('/api/')),
        ['/host/demo/sources/' + source + '/api/reports/' + metric + '.json']);
    }
    await page.evaluate(name => fixture.direct(name, 'chart', 'core.person.gender_count'), host);
    await slot.getByText('A chart is unavailable', {exact: false}).waitFor();
    await slot.getByText('Exact saved rows', {exact: true}).click();
    await slot.getByRole('table').waitFor();
    const firstRows = await slot.getByRole('table').innerText();
    await slot.getByRole('button', {name: 'Next rows'}).click();
    await slot.getByText('Page 2', {exact: true}).waitFor();
    await slot.getByText('Exact saved rows', {exact: true}).click();
    await slot.getByRole('table').waitFor();
    const secondRows = await slot.getByRole('table').innerText();
    assert.notEqual(firstRows, secondRows);
    assert((firstRows + secondRows).includes('9007199254740993'));
    await slot.getByRole('button', {name: 'Previous rows'}).click();
    await slot.getByText('Page 1', {exact: true}).waitFor();
    await slot.getByText('Exact saved rows', {exact: true}).click();
    assert.equal(await slot.getByRole('table').innerText(), firstRows);
    for (const [version, pin, code] of [['3.0.0', source, 'read_failed'],
      ['1.0.0', source === 'first' ? 'second' : 'first', 'context_mismatch']]) {
      assert.equal(await page.evaluate(async args => {
        try { await fixture.direct(...args); } catch (error) { return error.code; }
      }, [host, 'report', metric, version, pin]), code);
      await slot.getByRole('alert').waitFor();
      assert.equal(await slot.getByRole('table').count(), 0);
    }
  }
  const toggle = page.getByRole('button', {name: 'Toggle Vue workspace'});
  await toggle.click();
  await vue.waitFor({state: 'detached'});
  const directStart = assets.length;
  const metric = 'core.condition.capture_count';
  await page.evaluate(id => fixture.nextMount('vue', {kind: 'report', version: '2', metric_id: id, metric_version: '1.0.0'}), metric);
  await toggle.click();
  await vue.getByRole('table', {name: 'Saved rows for ' + metric}).waitFor();
  assert.deepEqual(await page.evaluate(() => fixture.ready('vue')), {status: 'applied', generation: 1});
  assert.deepEqual(assets.slice(directStart).map(url => url.pathname).filter(path => path.includes('/api/')),
    ['/host/demo/sources/second/api/reports/' + metric + '.json']);
  assert.equal(page.url(), href);
  assert.deepEqual(await hostState(), {headStyles: 1, summaries: 1, sentinel: 'none', header: 'Host navigation'});
  assert(assets.some(url => url.pathname.endsWith('/extensions/achilles/publication-workspace.mjs')));
  assert(assets.every(url => url.origin === new URL(href).origin && url.pathname.startsWith('/host/demo/')));
  assert.deepEqual(errors, []);
} finally {
  await browser?.close();
  await server.close();
}
