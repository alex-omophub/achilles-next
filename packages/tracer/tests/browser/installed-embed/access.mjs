import assert from 'node:assert/strict';
import {writeFile} from 'node:fs/promises';
import {join} from 'node:path';

const metric = 'core.person.gender_count';

async function direct(page, host) {
  return page.evaluate(async ([host, metric]) => {
    try { return (await fixture.direct(host, 'report', metric)).status; }
    catch (error) { return error.code; }
  }, [host, metric]);
}

export async function checkAccessChanges(page, react, vue, pins, scratch) {
  for (const key of ['source_id', 'release_id', 'publication_id', 'access_scope_id']) {
    assert.equal(pins.first[key], pins.renewed[key]);
  }
  // The native reader starts each session at epoch 1; the instance ID separates admissions.
  assert.equal(pins.first.authorization_epoch, pins.renewed.authorization_epoch);
  assert.notEqual(pins.first.instance_id, pins.renewed.instance_id);
  await page.evaluate(() => fixture.update('react', 'first'));
  await page.evaluate(() => fixture.update('vue', 'renewed'));
  for (const host of ['react', 'vue']) assert.equal(await direct(page, host), 'applied');

  const peer = await vue.getByRole('table').innerText();
  // The second source has saved labels; late label and download responses cannot cross the rebind.
  const downloads = [];
  const onDownload = file => downloads.push(file.suggestedFilename());
  page.on('download', onDownload);
  try {
    for (const method of ['search', 'exportEvidence']) {
      await page.evaluate(() => fixture.update('react', 'second'));
      await page.evaluate(() => fixture.direct('react', 'report', 'core.condition.capture_count'));
      await page.evaluate(method => fixture.holdOptional('react', method), method);
      if (method === 'search') {
        await react.getByText('Filter saved rows', {exact: true}).click();
        await react.getByLabel('Name prefix', {exact: true}).fill('Synthetic');
        await react.getByRole('button', {name: 'Search saved names'}).click();
      } else {
        await react.getByRole('button', {name: 'Download page evidence (JSON)'}).click();
      }
      await page.waitForFunction(() => fixture.held('react'));
      await page.evaluate(() => fixture.update('react', 'first'));
      assert(await page.evaluate(() => fixture.aborted('react')));
      await page.evaluate(() => fixture.release('react'));
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(resolve)));
      assert.equal(await react.getByText('Synthetic condition', {exact: true}).count(), 0);
      assert.equal(await vue.getByRole('table').innerText(), peer);
    }
    assert.deepEqual(downloads, []);
  } finally { page.off('download', onDownload); }

  // The host gateway challenges the expired session; the response body stays outside the viewer.
  const marker = 'fixture private error detail';
  await page.route(url => url.pathname.endsWith('/first/api/reports/' + metric + '.json'),
    route => route.fulfill({status: 401, body: marker}), {times: 1});
  assert.equal(await direct(page, 'react'), 'authentication_required');
  await react.getByRole('alert').getByText('Authentication is required to read this publication.').waitFor();
  assert.equal(await react.getByRole('table').count(), 0);
  assert.equal(await react.getByText(marker).count(), 0);
  assert.equal(await vue.getByRole('table').innerText(), peer);

  // Revoke the first R session only; the other still reads the exact same saved publication.
  assert.equal(await direct(page, 'react'), 'applied');
  const currentRows = react.getByRole('table');
  await currentRows.waitFor();
  await writeFile(join(scratch, 'first-approval.json.revoked'), '');
  await react.getByRole('button', {name: 'Next rows'}).click();
  await react.getByRole('alert').getByText('Access to this publication was denied.').waitFor();
  assert.equal(await currentRows.count(), 0);
  assert.equal(await direct(page, 'react'), 'access_denied');
  await react.getByRole('alert').getByText('Access to this publication was denied.').waitFor();
  assert.equal(await react.getByRole('table').count(), 0);
  assert.equal(await direct(page, 'vue'), 'applied');
  assert.equal(await vue.getByRole('table').innerText(), peer);

  // Retire an already authorized response while it is pending, then deny the replacement session.
  await page.evaluate(() => fixture.hold('react', 'renewed'));
  await page.waitForFunction(() => fixture.held('react'));
  const denial = await page.evaluate(async () => {
    try { await fixture.update('react', 'first'); } catch (error) { return error.code; }
  });
  assert.equal(denial, 'access_denied');
  assert(await page.evaluate(() => fixture.aborted('react')));
  assert.equal((await page.evaluate(() => fixture.release('react'))).status, 'superseded');
  await react.getByRole('alert').waitFor();
  assert.equal(await react.getByRole('table').count(), 0);
  assert.equal(await vue.getByRole('table').innerText(), peer);

  const stalePin = await page.evaluate(async () => {
    try { await fixture.update('react', 'renewed', 'first'); }
    catch (error) { return error.code; }
  });
  assert.equal(stalePin, 'context_mismatch');
  await react.getByRole('alert').waitFor();
  assert.equal(await react.getByRole('table').count(), 0);
  await page.evaluate(() => fixture.update('react', 'renewed'));
  const wrongEpoch = await page.evaluate(async context => {
    try { await fixture.present('react', {kind: 'workspace', version: '2'}, {context: {...context, authorization_epoch: 'expired'}}); }
    catch (error) { return error.code; }
  }, pins.renewed);
  assert.equal(wrongEpoch, 'context_mismatch');
  assert.equal(await react.getByRole('table').count(), 0);
  assert.equal(await direct(page, 'react'), 'applied');
  assert.equal(await react.getByRole('table').innerText(), peer);
}
