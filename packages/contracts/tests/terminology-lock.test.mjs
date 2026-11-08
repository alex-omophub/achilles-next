import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {verifyTerminologyLock} from '../tools/terminology-lock.mjs';

const directory = new URL('../../../inst/contracts/v2.1/', import.meta.url);
const bytes = readFileSync(new URL('terminology.schema.json', directory));
const lock = JSON.parse(readFileSync(new URL('schema-lock.json', directory), 'utf8'));
test('terminology oracle accepts the native supported locked format', () => {
  assert.doesNotThrow(() => verifyTerminologyLock(lock, bytes));
});
test('terminology oracle refuses missing or unsupported extension versions', () => {
  for (const version of [undefined, '1.1.0', ['1.0.0']]) {
    assert.throws(() => verifyTerminologyLock({...lock, extension_version: version}, bytes), /Terminology schema integrity mismatch/);
  }
  assert.throws(() => verifyTerminologyLock({...lock, sha256: {...lock.sha256, 'unexpected.json': 'ignored'}}, bytes), /Terminology schema integrity mismatch/);
});
