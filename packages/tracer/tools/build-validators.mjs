// Contributor build step: no schema compilation or eval in the installed viewer.
import Ajv2020 from 'ajv/dist/2020.js';
import standaloneCode from 'ajv/dist/standalone/index.js';
import codegen from 'ajv/dist/compile/codegen/code.js';
import {readFile, writeFile} from 'node:fs/promises';

const schema = JSON.parse(await readFile(new URL('../../../inst/contracts/v1/contract.schema.json', import.meta.url), 'utf8'));
const {_Code} = codegen;
const date = value => /^\d{4}-\d{2}-\d{2}$/.test(value) && !value.startsWith('0000') &&
  !Number.isNaN(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;
const stamp = value => /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value) &&
  !Number.isNaN(Date.parse(value)) && new Date(value).toISOString() === value;
// Stop after the first error in each branch: collecting every error for all
// nonmatching metric/state unions rescans large, otherwise valid row arrays.
const ajv = new Ajv2020({allErrors: false, strict: true, inlineRefs: false,
  code: {source: true, esm: true, formats: new _Code(`({date: ${date.toString()}, "date-time": ${stamp.toString()}})`)}});
ajv.addFormat('date', date);
ajv.addFormat('date-time', stamp);
ajv.addSchema(schema);
const refs = {};
for (const name of ['bundle', 'result', 'terminology']) {
  const id = `urn:achilles-next:viewer:${name}`;
  ajv.addSchema({$id: id, $ref: `${schema.$id}#/$defs/${name}`});
  refs[name] = id;
}
let code = standaloneCode(ajv, refs);
// Ajv emits CommonJS helpers even with ESM validators. Convert only these known
// pinned helper imports so Vite can bundle them without runtime require/eval.
code = code.replaceAll('require("ajv/dist/runtime/ucs2length").default', 'ucs2length')
  .replaceAll('require("ajv/dist/runtime/equal").default', 'equal');
code = `import ucs2lengthModule from "ajv/dist/runtime/ucs2length.js";
import equalModule from "ajv/dist/runtime/equal.js";
// Node ESM and the frontend bundler differ in CommonJS default unwrapping.
const ucs2length = typeof ucs2lengthModule === 'function' ? ucs2lengthModule : ucs2lengthModule.default;
const equal = typeof equalModule === 'function' ? equalModule : equalModule.default;
` + code;
if (/\brequire\(/.test(code)) throw new Error('Unknown standalone validator helper; update the build adapter explicitly');
await writeFile(new URL('../src/generated-validation.mjs', import.meta.url), code);
