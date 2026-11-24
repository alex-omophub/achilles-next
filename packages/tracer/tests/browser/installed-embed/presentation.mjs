import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const report = {kind: 'report', version: '2', metric_id: 'core.measurement.numeric_summary', metric_version: '1.0.0'};
const workspace = {kind: 'workspace', version: '2'};
const arabic = 'ar-EG-u-nu-arab';

function present(page, host, target, options = {}) {
  return page.evaluate(args => fixture.present(...args), [host, target, options]);
}
async function snapshot(slot) {
  await slot.locator('.recharts-line-dot').first().waitFor();
  return slot.evaluate(node => {
    const root = node.firstElementChild.shadowRoot;
    const graphic = root.querySelector('.recharts-line-dot');
    return {
      color: getComputedStyle(graphic).fill,
      surface: getComputedStyle(root.querySelector('.publication-workspace')).backgroundColor,
      positions: [...root.querySelectorAll('.recharts-line-dot')].map(dot => dot.getAttribute('cy')),
      ticks: [...root.querySelectorAll('.recharts-yAxis-tick-labels .recharts-cartesian-axis-tick-value')].map(tick => tick.textContent),
      rows: root.querySelector('.publication-scroll table').innerText,
      language: root.querySelector('[lang]').lang,
    };
  });
}
async function download(page, slot) {
  const [file] = await Promise.all([page.waitForEvent('download'),
    slot.getByRole('button', {name: 'Download page evidence (JSON)'}).click()]);
  return readFile(await file.path(), 'utf8');
}

export async function checkPresentation(page, react, vue) {
  await present(page, 'vue', report);
  await present(page, 'react', report);
  const peer = await snapshot(vue);
  const baseline = await snapshot(react);
  const evidence = await download(page, react);
  assert(baseline.ticks.length && baseline.positions.length);
  const theme = {ink: '#222', accent: '#774411', focus: '#008811', surface: '#fafafa'};
  await present(page, 'react', report, {locale: arabic, theme});
  const themed = await snapshot(react);
  const formatter = new Intl.NumberFormat(arabic);
  assert.equal(themed.color, 'rgb(119, 68, 17)');
  assert.equal(themed.surface, 'rgb(250, 250, 250)');
  assert.equal(themed.language, 'en');
  assert.deepEqual(themed.ticks, baseline.ticks.map(label => formatter.format(Number(label))));
  assert.deepEqual(themed.positions, baseline.positions);
  assert.equal(themed.rows, baseline.rows);
  assert.equal(await download(page, react), evidence);
  await page.keyboard.press('Tab');
  const control = react.getByRole('button', {name: 'Download page evidence (JSON)'});
  await control.focus();
  assert.equal(await control.evaluate(node => getComputedStyle(node).outlineColor), 'rgb(0, 136, 17)');
  assert.deepEqual(await snapshot(vue), peer);
  await present(page, 'react', report, {theme: {accent: '#173d65'}});
  assert.equal((await snapshot(react)).color, 'rgb(23, 61, 101)');
  await present(page, 'react', report);
  assert.deepEqual(await snapshot(react), baseline);
  await present(page, 'vue', workspace, {locale: arabic});
  assert.equal(await vue.locator('.population-number').innerText(), formatter.format(10));
  await present(page, 'vue', workspace);
  assert.equal(await vue.locator('.population-number').innerText(), '10');
  assert.deepEqual(await snapshot(react), baseline);
}
