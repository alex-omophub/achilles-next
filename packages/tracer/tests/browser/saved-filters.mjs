import assert from 'node:assert/strict';

const conditionId = 'core.condition.capture_count';
const measurementId = 'core.measurement.numeric_summary';

async function openFilters(region) {
  const apply = region.getByRole('button', {name: 'Apply filters', exact: true});
  if (!await apply.isVisible()) await region.getByText('Filter saved rows', {exact: true}).press('Enter');
  await apply.waitFor();
}

async function search(region, prefix) {
  await region.getByLabel('Name prefix', {exact: true}).fill(prefix);
  await region.getByRole('button', {name: 'Search saved names', exact: true}).press('Enter');
}

async function expectRows(table, count) {
  const rows = table.locator('tbody tr');
  await rows.nth(count - 1).waitFor();
  await rows.nth(count).waitFor({state: 'detached'});
}

function latestFilters(requests, metric) {
  const url = requests.findLast(url => url.pathname.endsWith('/reports/' + metric + '.json') && url.searchParams.has('filters'));
  assert(url, 'Expected a typed saved selection for ' + metric);
  return JSON.parse(url.searchParams.get('filters'));
}

export async function checkSavedFilters(page, region, selectMetric, requests) {
  const dates = await selectMetric(region, conditionId);
  const panel = region.getByRole('region', {name: 'Saved row filters'});
  await expectRows(dates, 8);
  await openFilters(region);
  const useId = id => region.getByRole('button', {name: 'Use ID ' + id, exact: true});
  await search(region, ' \u00a0Paged concept ');
  await region.getByText('0 matches on page 1', {exact: true}).waitFor();
  assert.equal(requests.findLast(url => url.pathname.endsWith('/concepts/search.json')).searchParams.get('q'), '\u00a0Paged concept');
  await search(region, 'Paged concept');
  await useId('100').waitFor();
  await page.setViewportSize({width: 375, height: 820});
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Narrow filter panel overflows');
  await region.getByRole('button', {name: 'Next matches'}).click();
  await useId('115').waitFor();
  assert.equal(await useId('100').count(), 0);
  await region.getByRole('button', {name: 'Previous matches'}).click();
  await useId('100').waitFor();

  await search(region, 'Synthetic con');
  await region.getByText('Synthetic condition', {exact: true}).waitFor();
  await useId('123').click();
  assert.equal(await region.getByLabel('Concept ID', {exact: true}).inputValue(), '123');
  await panel.getByRole('combobox', {name: /^Saved period/}).selectOption('calendar_month');
  await region.getByLabel('Period start', {exact: true}).fill('2020-02-01');
  await region.getByLabel('Period end', {exact: true}).fill('2020-01-31');
  await region.getByRole('button', {name: 'Apply filters'}).press('Enter');
  const invalidPeriod = panel.getByRole('alert');
  await invalidPeriod.waitFor();
  await region.getByLabel('Period end', {exact: true}).fill('2020-02-29');
  await invalidPeriod.waitFor({state: 'detached'});
  await region.getByRole('button', {name: 'Apply filters'}).press('Enter');
  await expectRows(dates, 1);
  await page.setViewportSize({width: 1120, height: 820});
  const matched = dates.locator('tbody tr');
  await matched.getByText('123', {exact: true}).waitFor();
  await matched.getByText('2020-02-29', {exact: true}).waitFor();
  assert.equal(await matched.getByText('2', {exact: true}).count(), 2);
  assert.deepEqual(latestFilters(requests, conditionId), {concept_tag: {kind: 'id', value: '123'},
    period_kind: 'calendar_month', period_start: '2020-02-01', period_end: '2020-02-29'});
  await panel.getByText('ID 123', {exact: true}).waitFor();

  await openFilters(region);
  const start = panel.getByLabel('Period start', {exact: true});
  const conditionReads = () => requests.filter(url => url.pathname.endsWith('/reports/' + conditionId + '.json')).length;
  const requestsBeforeInvalid = conditionReads();
  await start.fill('');
  await panel.getByRole('button', {name: 'Apply filters'}).click();
  assert(await start.evaluate(input => input.validity.valueMissing));
  assert.equal(conditionReads(), requestsBeforeInvalid);
  await start.fill('2020-02-02');
  const partialPeriod = page.waitForResponse(response => {
    const url = new URL(response.url());
    return url.pathname.endsWith('/reports/' + conditionId + '.json')
      && JSON.parse(url.searchParams.get('filters') ?? '{}').period_start === '2020-02-02';
  });
  await panel.getByRole('button', {name: 'Apply filters'}).click();
  const unsavedPeriod = await (await partialPeriod).json();
  assert.equal(unsavedPeriod.state, 'additional_batch_job_required');
  assert.equal(unsavedPeriod.generation_requested, false);
  await region.getByText(unsavedPeriod.reason_code, {exact: true}).waitFor();
  assert.equal(await dates.count(), 0);
  await region.getByRole('button', {name: 'Clear filters'}).click();
  await expectRows(dates, 8);
  await openFilters(region);
  await panel.getByRole('combobox', {name: /^Find by/}).selectOption('id');
  await region.getByLabel('Exact concept ID', {exact: true}).fill('777');
  await region.getByRole('button', {name: 'Look up ID'}).press('Enter');
  await region.getByText('Name unavailable', {exact: true}).waitFor();
  await useId('777').click();
  await region.getByRole('button', {name: 'Apply filters'}).click();
  await region.getByText('selection.no_saved_rows', {exact: true}).waitFor();
  assert.equal(await dates.count(), 0);
  await region.getByRole('button', {name: 'Back to catalogue'}).press('Enter');
  await region.getByRole('button', {name: conditionId, exact: true}).press('Enter');
  await expectRows(dates, 8);

  const summaries = await selectMetric(region, measurementId);
  await openFilters(region);
  for (const [field, id] of [['Concept', '123'], ['Unit', '777']]) {
    await panel.getByRole('combobox', {name: new RegExp('^' + field)}).selectOption('id');
    await region.getByLabel(field + ' ID', {exact: true}).fill(id);
  }
  await panel.getByRole('combobox', {name: /^Operator/}).selectOption('null');
  await region.getByRole('button', {name: 'Apply filters'}).click();
  await expectRows(summaries, 1);
  const empty = summaries.locator('tbody tr');
  await empty.getByText('fixture.no_eligible', {exact: true}).waitFor();
  await empty.getByText('0', {exact: true}).waitFor();
  assert.deepEqual(latestFilters(requests, measurementId), {concept_tag: {kind: 'id', value: '123'},
    unit_concept_tag: {kind: 'id', value: '777'}, raw_operator_tag: {kind: 'null'}});
  const people = await selectMetric(region, 'core.person.count');
  await people.getByText('10', {exact: true}).waitFor();
  assert.equal(await region.getByText('Filter saved rows', {exact: true}).count(), 0);
}

export async function checkLateConceptSearch(page, host, selectMetric) {
  await page.goto(host + '/tests/browser/domain-host.html');
  const first = page.getByRole('region', {name: 'First workspace'});
  const second = page.getByRole('region', {name: 'Second workspace'});
  const sibling = await selectMetric(second, measurementId);
  await expectRows(sibling, 3);
  await selectMetric(first, conditionId);
  await openFilters(first);
  await page.evaluate(() => { window.delayFirstSearch = true; });
  await search(first, 'Synthetic con');
  await page.waitForFunction(() => typeof window.releaseFirstSearch === 'function');
  await page.getByRole('button', {name: 'Switch first source'}).click();
  await first.getByText('fixture:second', {exact: true}).waitFor();
  assert(await page.evaluate(() => window.delayedSearchSignal.aborted));
  await selectMetric(first, conditionId);
  await openFilters(first);
  await search(first, 'Synthetic con');
  await first.getByText('terminology.name_index_not_saved', {exact: false}).waitFor();
  await page.evaluate(() => window.releaseFirstSearch());
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(resolve)));
  assert.equal(await first.getByRole('button', {name: 'Use ID 123'}).count(), 0);
  assert.equal(await first.getByText('Synthetic condition', {exact: true}).count(), 0);
  await first.getByRole('combobox', {name: /^Find by/}).selectOption('id');
  await first.getByLabel('Exact concept ID', {exact: true}).fill('123');
  await first.getByRole('button', {name: 'Look up ID'}).click();
  await first.getByRole('button', {name: 'Use ID 123'}).waitFor();
  await first.getByText('Name unavailable', {exact: true}).waitFor();
  await expectRows(sibling, 3);
}
