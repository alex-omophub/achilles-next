import assert from 'node:assert/strict';
import {readFile, unlink, writeFile} from 'node:fs/promises';

const downloadButton = region => region.getByRole('button', {name: 'Download page evidence (JSON)', exact: true});
const endpoint = (response, kind, metric) => new URL(response.url()).pathname.endsWith('/' + kind + '/' + metric + '.json');

async function verifyDownload(page, region, displayedResponse, trusted, number) {
  const displayed = await displayedResponse.json();
  const metric = displayed.dataset.metric_id;
  const button = downloadButton(region);
  await button.focus();
  assert(await button.evaluate(node => node === document.activeElement));
  const [download, freshlyAuthorized] = await Promise.all([
    page.waitForEvent('download'), page.waitForResponse(r => endpoint(r, 'evidence', metric)), button.press('Enter'),
  ]);
  assert.equal(freshlyAuthorized.status(), 200);
  assert.equal(new URL(freshlyAuthorized.url()).search, new URL(displayedResponse.url()).search);
  assert.equal(download.suggestedFilename(), 'achillesnext-' + metric + '-page-' + number + '.json');
  assert.equal(await download.failure(), null);
  const file = JSON.parse(await readFile(await download.path(), 'utf8'));
  assert.equal(file.kind, 'selected_page_evidence');
  assert.equal(file.format_version, '1.0.0');
  assert.equal(file.generation_requested, false);
  assert.equal(file.limitations.selection, 'current_page_only');
  assert.equal(file.provenance.root_sha256, trusted.root.sha256);
  assert.equal(file.provenance.scope_kind, 'restricted');
  assert.equal(file.provenance.approval_id, 'fixture-review');
  assert.equal(file.definition.id, metric);
  const downloaded = file.page;
  assert.equal(downloaded.number, number);
  assert.equal(downloaded.complete, displayed.complete);
  assert.equal(downloaded.context.source_id, trusted.source_id);
  assert.equal(downloaded.context.access_scope_id, trusted.access_scope_id);
  assert.equal(downloaded.context.publication_id, trusted.publication_id);
  assert.equal(downloaded.dataset.definition_sha256, displayed.dataset.definition_sha256);
  assert.equal(downloaded.selection.metric_id, metric);
  assert.deepEqual(downloaded.selection.filters, displayed.selection.filters);
  assert.deepEqual(downloaded.rows, displayed.rows);
  assert.deepEqual(downloaded.dependencies, displayed.dependencies);
  for (const key of ['cursor', 'budget']) assert.equal(Object.hasOwn(downloaded, key), false);
  for (const key of ['instance_id', 'authorization_epoch']) assert.equal(Object.hasOwn(downloaded.context, key), false);
  return downloaded;
}

export async function checkEvidenceDownloads(page, host, standaloneUrl, approvals, selectMetric) {
  const trusted = JSON.parse(await readFile(approvals[0], 'utf8'));
  const downloads = [];
  const collect = file => downloads.push(file.suggestedFilename());
  page.on('download', collect);
  try {
    await page.goto(standaloneUrl);
    const standalone = page.getByRole('main');
    const gender = 'core.person.gender_count';
    const table = await selectMetric(standalone, gender);
    await table.locator('tbody tr').first().waitFor();
    const [continued] = await Promise.all([
      page.waitForResponse(r => endpoint(r, 'reports', gender) && new URL(r.url()).searchParams.has('cursor')),
      standalone.getByRole('button', {name: 'Next rows'}).click(),
    ]);
    await table.getByText('9007199254740993', {exact: true}).waitFor();
    const secondPage = await verifyDownload(page, standalone, continued, trusted, 2);
    assert.equal(secondPage.rows.length, 6);
    assert(secondPage.rows.some(row => row.dimensions.gender_concept_id === '9007199254740993'));
    assert(!secondPage.rows.some(row => row.dimensions.gender_concept_id === '100'));
    assert(secondPage.dependencies.some(dep => dep.metric_id === 'core.person.count' && dep.row.values.person_count === '10'));

    await page.goto(host + '/tests/browser/domain-host.html');
    const first = page.getByRole('region', {name: 'First workspace'});
    const second = page.getByRole('region', {name: 'Second workspace'});
    const metric = 'core.measurement.numeric_summary';
    const summary = await selectMetric(first, metric);
    await first.getByRole('button', {name: 'Filter saved rows'}).click();
    const panel = first.getByRole('region', {name: 'Saved row filters'});
    await panel.getByRole('combobox', {name: /^Unit/}).selectOption('id');
    await panel.getByLabel('Unit ID', {exact: true}).fill('9007199254740993');
    const [filtered] = await Promise.all([
      page.waitForResponse(r => endpoint(r, 'reports', metric) && new URL(r.url()).searchParams.has('filters')),
      panel.getByRole('button', {name: 'Apply filters'}).click(),
    ]);
    await summary.locator('tbody tr').nth(1).waitFor({state: 'detached'});
    await summary.getByText('2.5', {exact: true}).first().waitFor();
    const filteredPage = await verifyDownload(page, first, filtered, trusted, 1);
    assert.deepEqual(filteredPage.selection.filters, {unit_concept_tag: {kind: 'id', value: '9007199254740993'}});
    assert.equal(filteredPage.rows.length, 1);
    assert.equal(filteredPage.rows[0].values.p50, '2.5');
    assert(filteredPage.dependencies.some(dep => dep.row.row_kind === 'eligibility_counts' && dep.row.values.record_count === '6'));

    // Hold a verified response while the host replaces the workspace's source.
    await page.evaluate(() => { window.delayFirstExport = true; });
    await downloadButton(first).click();
    await page.waitForFunction(() => typeof window.releaseFirstExport === 'function');
    await page.getByRole('button', {name: 'Switch first source'}).click();
    await first.getByText('fixture:second', {exact: true}).waitFor();
    assert(await page.evaluate(() => window.delayedExportSignal.aborted));
    await page.evaluate(() => window.releaseFirstExport());

    // Revoke the real synthetic callback after displaying the second source's report.
    const people = 'core.person.count';
    const count = await selectMetric(second, people);
    await count.getByText('10', {exact: true}).waitFor();
    const sentinel = approvals[1] + '.revoked';
    await writeFile(sentinel, '', {flag: 'wx'});
    try {
      const [denied] = await Promise.all([
        page.waitForResponse(r => endpoint(r, 'evidence', people)), downloadButton(second).click(),
      ]);
      assert.equal(denied.status(), 403);
      await second.getByRole('alert').waitFor();
      assert.equal(await count.count(), 0);
      assert.equal(await downloadButton(second).count(), 0);
      assert.equal(downloads.length, 2, 'A stale or unauthorized response started a download');
    } finally {
      await unlink(sentinel);
    }
  } finally {
    page.off('download', collect);
  }
}
