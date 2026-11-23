import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {createServer} from 'vite';
import {checkChartRecovery, checkChartsAndEvidence} from './chart-evidence.mjs';
import {checkLateConceptSearch, checkSavedFilters} from './saved-filters.mjs';

// Playwright is test-only and can be installed separately through NODE_PATH.
const {chromium} = createRequire(import.meta.url)('playwright');
const [firstUrl, secondUrl] = process.argv.slice(2);
const proxy = {};
for (const [name, url] of [['first', firstUrl], ['second', secondUrl]]) {
  const viewer = new URL(url);
  assert.equal(viewer.hostname, '127.0.0.1');
  proxy['/' + name + '/api/'] = {
    target: viewer.origin, changeOrigin: true,
    rewrite: path => viewer.pathname + path.slice(name.length + 2),
  };
}
const server = await createServer({logLevel: 'error', server: {host: '127.0.0.1', port: 0, hmr: false, proxy}});
let browser;
try {
  await server.listen();
  browser = await chromium.launch({executablePath: process.env.ACHILLES_NEXT_TEST_CHROME, headless: true});
  const page = await browser.newPage({viewport: {width: 1120, height: 820}});
  const errors = [], requests = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => requests.push(new URL(request.url())));
  page.setDefaultTimeout(10000);

  async function selectMetric(region, id) {
    await region.getByRole('combobox', {name: 'Domain or section'}).selectOption(id.split('.')[1]);
    const button = region.getByRole('button', {name: id, exact: true});
    await button.focus();
    await button.press('Enter');
    const heading = region.getByRole('heading', {name: id, exact: true});
    await heading.waitFor();
    return region.getByRole('table', {name: 'Saved rows for ' + id, exact: true});
  }

  // Exercise the packaged production bundle and its real loopback provider.
  await page.goto(firstUrl);
  const main = page.getByRole('main');
  await main.getByText('fixture:first', {exact: true}).waitFor();
  await selectMetric(main, 'core.drug.capture_count');
  await main.getByText('policy.output_omitted', {exact: true}).first().waitFor();
  assert.equal(await main.getByRole('table', {name: 'Saved rows for core.drug.capture_count'}).count(), 0);
  const zero = await selectMetric(main, 'core.specimen.capture_count');
  await zero.getByText('fixture.empty_source', {exact: true}).waitFor();
  assert.equal(await zero.getByText('0', {exact: true}).count(), 2);
  const unavailable = await selectMetric(main, 'core.visit.care_setting_count');
  await unavailable.getByText('capability.care_site_absent', {exact: true}).waitFor();
  assert.equal(await unavailable.getByText('0', {exact: true}).count(), 0);
  for (const width of [375, 1120]) {
    await page.setViewportSize({width, height: 820});
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
      'Standalone viewer overflows at width ' + width);
  }
  const table = await selectMetric(main, 'core.person.gender_count');
  const firstRows = await table.locator('tbody tr').allTextContents();
  assert.equal(firstRows.length, 12);
  await main.getByRole('button', {name: 'Next rows', exact: true}).press('Enter');
  await table.getByText('9007199254740993', {exact: true}).waitFor();
  assert.equal(await table.locator('tbody tr').count(), 6);
  assert.equal(await page.evaluate(() => document.activeElement.textContent), 'core.person.gender_count');
  await main.getByRole('button', {name: 'Previous rows', exact: true}).click();
  await table.getByText('100', {exact: true}).waitFor();
  assert.deepEqual(await table.locator('tbody tr').allTextContents(), firstRows);
  await main.getByRole('button', {name: 'Back to catalogue', exact: true}).press('Enter');
  const previousSelection = main.getByRole('button', {name: 'core.person.gender_count', exact: true});
  await previousSelection.waitFor();
  assert(await previousSelection.evaluate(button => button === document.activeElement));
  await checkChartsAndEvidence(page, main, selectMetric, requests);
  await checkSavedFilters(page, main, selectMetric, requests);
  assert(requests.every(url => url.origin === new URL(firstUrl).origin));
  assert(requests.some(url => url.pathname.endsWith('/reports/core.person.gender_count.json') && url.searchParams.has('cursor')));

  // Both components use real native responses through same-origin host prefixes.
  const host = 'http://127.0.0.1:' + server.httpServer.address().port;
  await page.goto(host + '/tests/browser/domain-host.html');
  const first = page.getByRole('region', {name: 'First workspace', exact: true});
  const second = page.getByRole('region', {name: 'Second workspace', exact: true});
  await first.getByText('fixture:first', {exact: true}).waitFor();
  await second.getByText('fixture:second', {exact: true}).waitFor();
  assert.equal(await page.getByRole('main').count(), 0);
  const selected = await selectMetric(second, 'core.specimen.capture_count');
  await selected.getByText('fixture.empty_source', {exact: true}).waitFor();
  await checkChartsAndEvidence(page, first, selectMetric, requests);
  await first.getByRole('combobox', {name: 'Domain or section'}).selectOption('all');
  await first.getByRole('heading', {name: 'Metric catalogue', exact: true}).waitFor();
  assert.equal(await selected.locator('tbody tr').count(), 1);
  await first.getByRole('combobox', {name: 'Domain or section'}).selectOption('condition');
  await page.evaluate(() => { window.delayFirstReport = true; });
  await first.getByRole('button', {name: 'core.condition.capture_count', exact: true}).click();
  await page.waitForFunction(() => typeof window.releaseFirstReport === 'function');
  await page.getByRole('button', {name: 'Switch first source'}).click();
  await first.getByText('fixture:second', {exact: true}).waitFor();
  assert(await page.evaluate(() => window.delayedReportSignal.aborted));
  await page.evaluate(() => window.releaseFirstReport());
  await first.getByRole('combobox', {name: 'Domain or section'}).selectOption('drug');
  await first.getByRole('button', {name: 'core.drug.capture_count', exact: true}).waitFor();
  assert.equal(await first.getByText('fixture:first', {exact: true}).count(), 0);
  assert.equal(await first.getByRole('heading', {name: 'core.condition.capture_count'}).count(), 0);
  assert.equal(await second.getByRole('combobox', {name: 'Domain or section'}).inputValue(), 'specimen');
  assert.equal(await selected.locator('tbody tr').count(), 1);

  const previous = await selectMetric(first, 'core.person.gender_count');
  await previous.getByText('100', {exact: true}).waitFor();
  await page.route(url => url.pathname.endsWith('/reports/core.person.gender_count.json') && url.searchParams.has('cursor'),
    route => route.fulfill({status: 403, body: ''}), {times: 1});
  await first.getByRole('button', {name: 'Next rows', exact: true}).click();
  await first.getByRole('alert').waitFor();
  assert.equal(await previous.count(), 0);
  assert.equal(await first.getByRole('table').count(), 0);
  assert.equal(await first.getByText('People in source', {exact: true}).count(), 0);
  assert.equal(await first.getByText('fixture:second', {exact: true}).count(), 0);
  assert.equal(await selected.locator('tbody tr').count(), 1);
  const stillAuthorized = await selectMetric(second, 'core.visit.care_setting_count');
  await stillAuthorized.getByText('capability.care_site_absent', {exact: true}).waitFor();
  await checkLateConceptSearch(page, host, selectMetric);
  assert.deepEqual(errors, []);
  await checkChartRecovery(page, host, selectMetric);
} finally {
  await browser?.close();
  await server.close();
}
