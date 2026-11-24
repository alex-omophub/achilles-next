import assert from 'node:assert/strict';

// Installed before either framework starts. Keep counts rather than references to retired DOM nodes.
export function observeResources() {
  const counts = {react: 0, vue: 0, workers: 0};
  const owner = node => node.getRootNode()?.host?.closest('#react-host, #vue-host')?.id.split('-')[0];
  const NativeResize = window.ResizeObserver;
  window.ResizeObserver = class extends NativeResize {
    #targets = new Map();
    observe(node, options) {
      super.observe(node, options);
      const host = owner(node);
      if (host && !this.#targets.has(node)) {
        this.#targets.set(node, host);
        counts[host]++;
      }
    }
    unobserve(node) {
      super.unobserve(node);
      if (this.#targets.has(node)) {
        counts[this.#targets.get(node)]--;
        this.#targets.delete(node);
      }
    }
    disconnect() {
      super.disconnect();
      for (const host of this.#targets.values()) counts[host]--;
      this.#targets.clear();
    }
  };
  const NativeWorker = window.Worker;
  window.Worker = class extends NativeWorker {
    constructor(...args) { super(...args); counts.workers++; }
  };
  window.embedResources = () => ({...counts});
}

// Sample the real Chromium window and document without retaining listener objects between cycles.
async function globalListeners(cdp) {
  const counts = {};
  try {
    for (const expression of ['window', 'document']) {
      const {result} = await cdp.send('Runtime.evaluate', {expression, objectGroup: 'embed-listeners'});
      const {listeners} = await cdp.send('DOMDebugger.getEventListeners', {objectId: result.objectId});
      for (const listener of listeners) {
        const key = [expression, listener.type, listener.useCapture].join('/');
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    return counts;
  } finally {
    await cdp.send('Runtime.releaseObjectGroup', {objectGroup: 'embed-listeners'});
  }
}

export async function checkRetirement(page, react, vue) {
  const target = {kind: 'chart', version: '2', metric_id: 'core.measurement.numeric_summary', metric_version: '1.0.0'};
  const apply = host => page.evaluate(([host, target]) => fixture.present(host, target, {}), [host, target]);
  await apply('vue');
  await vue.locator('.recharts-line-dot').first().waitFor();
  const peerCount = (await page.evaluate(() => window.embedResources())).vue;
  assert(peerCount > 0);
  const toggle = page.getByRole('button', {name: 'Toggle React workspace'});
  const ids = new Set();
  const cdp = await page.context().newCDPSession(page);
  let detachedListeners;
  for (let cycle = 0; cycle < 3; cycle++) {
    const id = await page.evaluate(() => fixture.id('react'));
    assert(!ids.has(id)); ids.add(id);
    await page.evaluate(() => fixture.update('react', 'renewed'));
    await apply('react');
    await react.locator('.recharts-line-dot').first().waitFor();
    assert((await page.evaluate(() => window.embedResources())).react > 0);
    await page.evaluate(() => fixture.hold('react', 'renewed'));
    await page.waitForFunction(() => fixture.held('react'));
    const before = await page.evaluate(() => fixture.events('react').length);
    await toggle.click();
    await react.waitFor({state: 'detached'});
    assert(await page.evaluate(() => fixture.aborted('react')));
    assert.equal((await page.evaluate(() => fixture.release('react'))).status, 'destroyed');
    assert.equal(await page.evaluate(() => fixture.events('react').length), before);
    const listeners = await globalListeners(cdp);
    if (detachedListeners) assert.deepEqual(listeners, detachedListeners);
    detachedListeners = listeners;
    const counts = await page.evaluate(() => window.embedResources());
    assert.deepEqual(counts, {react: 0, vue: peerCount, workers: 0});
    await vue.locator('.recharts-line-dot').first().waitFor();
    if (cycle < 2) {
      // A fresh React mount's default source is first, whose approval was revoked.
      await page.evaluate(() => fixture.nextSource('react', 'renewed'));
      await toggle.click();
      await react.getByText('fixture:first', {exact: true}).waitFor();
    }
  }
  await cdp.detach();
  await page.getByRole('button', {name: 'Toggle Vue workspace'}).click();
  await vue.waitFor({state: 'detached'});
  assert.deepEqual(await page.evaluate(() => window.embedResources()), {react: 0, vue: 0, workers: 0});
}
