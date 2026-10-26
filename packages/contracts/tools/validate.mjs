import { resolve } from 'node:path';
import { ROOT, validateBundleDirectory } from '../src/validator.mjs';
try {
  const bundle=await validateBundleDirectory(process.argv[2]?resolve(process.argv[2]):resolve(ROOT,'tests/fixtures/contracts/complete'));
  console.log(`PASS: contracts 1.0.0; ${bundle.documents.size} requested outputs; typed states, identities, counts and file integrity`);
  console.log('Contract fixtures only; no production generator, viewer or host adapter certification.');
} catch(error) { console.error(`FAIL: ${error.message}`);process.exitCode=1; }
