// Independent structural oracle only. Native admission owns index/scope closure.
import {readFileSync} from 'node:fs';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import {verifyTerminologyLock} from './terminology-lock.mjs';
const directory = new URL('../../../inst/contracts/v2.1/', import.meta.url);
const bytes = readFileSync(new URL('terminology.schema.json', directory));
const lock = JSON.parse(readFileSync(new URL('schema-lock.json', directory), 'utf8'));
verifyTerminologyLock(lock, bytes);
const schema = JSON.parse(bytes);
const ajv = new Ajv({strict: true}); addFormats(ajv); ajv.addSchema(schema);
const validators = new Map(['concept_entry','name_entry','metadata','snapshot_header'].map(kind => [kind, ajv.compile({$ref: `${schema.$id}#/$defs/${kind}`})]));
const cases = JSON.parse(readFileSync(process.argv[2], 'utf8'));
for (const [i, test] of cases.entries()) {
  const validate = validators.get(test.kind);
  if (!validate || validate(test.value) !== test.valid) throw new Error(`Terminology structural mismatch: ${i}/${test.kind}`);
}
console.log(`TERMINOLOGY_STRUCTURAL_DIFFERENTIAL_OK: ${cases.length} vectors`);
