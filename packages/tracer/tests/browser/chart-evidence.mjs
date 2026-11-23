import assert from 'node:assert/strict';

// All charts and evidence are projections of the selected, already authorized page.
export async function checkChartsAndEvidence(page, main, selectMetric, requests) {
  const chart = main.getByRole('region', {name: 'Saved chart', exact: true});
  const svg = chart.locator('svg.recharts-surface');
  const reportReads = () => requests.filter(url => url.pathname.includes('/api/')).length;
  const evidence = main.locator('details').filter({has: page.getByText('Report evidence', {exact: true})});

  async function choose(selector, label) {
    const option = selector.getByRole('option', {name: label});
    await selector.selectOption(await option.getAttribute('value'));
  }
  async function showEvidence() {
    const toggle = main.getByText('Report evidence', {exact: true});
    await toggle.focus();
    await toggle.press('Enter');
    await evidence.getByText('Definition SHA-256', {exact: true}).waitFor();
    assert.match(await evidence.innerText(), /\b[a-f0-9]{64}\b/);
  }

  const dates = await selectMetric(main, 'core.condition.capture_count');
  await dates.getByText('2020-02-29', {exact: true}).first().waitFor();
  const byPeriod = chart.getByRole('combobox', {name: 'Concept and period'});
  await byPeriod.waitFor();
  let before = reportReads();
  await choose(byPeriod, /Concept ID 123.*Calendar month/i);
  await svg.waitFor();
  await choose(chart.getByRole('combobox', {name: 'Measure'}), /Distinct people/i);
  await chart.getByRole('figure', {name: /Capture by saved period.*Distinct people/i}).waitFor();
  await svg.getByText('2020-01', {exact: true}).waitFor();
  await svg.getByText('2020-02', {exact: true}).waitFor();
  assert.equal(await dates.locator('tbody tr').count(), 8);
  await showEvidence();
  assert.equal(reportReads(), before, 'Changing a chart or opening evidence requested more saved data');

  const values = await selectMetric(main, 'core.measurement.numeric_summary');
  await values.getByText('fixture.no_eligible', {exact: true}).waitFor();
  const stratum = chart.getByRole('combobox', {name: 'Measurement stratum'});
  before = reportReads();
  await choose(stratum, /456/);
  await svg.waitFor();
  await choose(stratum, /777/);
  await svg.waitFor({state: 'detached'});
  await chart.getByText(/No plottable values in this selection/).waitFor();
  await choose(stratum, /9007199254740993/);
  await svg.waitFor();
  assert.equal(await values.locator('tbody tr').count(), 3);
  await showEvidence();
  for (const [unit, count] of [['456', '6'], ['777', '0'], ['9007199254740993', '6']]) {
    const heading = evidence.getByRole('heading', {name: new RegExp('Unit concept ' + unit + ' · Operator NULL')});
    const detail = heading.locator('..').getByRole('definition');
    assert.equal(await detail.innerText(), count);
  }
  assert.match(await evidence.innerText(), /Other eligibility reasons are unavailable on this page/);
  assert.equal(reportReads(), before, 'Switching measurement units requested more saved data');

  const years = await selectMetric(main, 'core.person.birth_year_count');
  await years.getByText('1950', {exact: true}).waitFor();
  const rows = await years.locator('tbody tr').allTextContents();
  assert.equal(rows.length, 2);
  assert.match(rows[0], /1950.*6/);
  assert.match(rows[1], /1980.*4/);
  await svg.waitFor();
  await svg.focus();
  await svg.press('ArrowRight');
  const tooltip = chart.locator('.recharts-tooltip-wrapper');
  await tooltip.waitFor();
  assert.match(await tooltip.innerText(), /1950[\s\S]*Distinct people · 6|1980[\s\S]*Distinct people · 4/);
  await showEvidence();
  const provenance = await evidence.innerText();
  assert.match(provenance, /Denominator for person count/i);
  assert.match(provenance, /core\.person\.count/);
  assert.match(provenance, /\b10\b/);
  before = reportReads();
  const fills = [];
  for (const [width, colorScheme] of [[375, 'dark'], [1120, 'light']]) {
    await page.setViewportSize({width, height: 820});
    await page.emulateMedia({colorScheme});
    // ResponsiveContainer measures its new width via ResizeObserver.
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    assert(await page.evaluate(expected => matchMedia('(prefers-color-scheme: ' + expected + ')').matches, colorScheme));
    const box = await svg.boundingBox();
    assert(box && box.width > 0 && box.width <= width && box.height > 0);
    const bar = svg.locator('.recharts-bar-rectangle path').first();
    fills.push(await bar.evaluate(node => getComputedStyle(node).fill));
    assert.deepEqual(await years.locator('tbody tr').allTextContents(), rows);
  }
  assert.notEqual(fills[0], fills[1], 'Bar color did not adapt to the chart theme');
  assert.equal(reportReads(), before, 'Resize or color scheme requested more saved data');
}
