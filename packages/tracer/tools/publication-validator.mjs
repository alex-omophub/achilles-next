// Bundled into the R package: no npm installation or schema compiler at runtime.
import {bundle, result, terminology} from '../src/generated-validation.mjs';
import profile from '../../../inst/analysis/alpha-measurement-v1.json';
import {validateDirectory} from '../../contracts/src/directory.mjs';
import {ensure, validateResult, validateBundleDocuments} from '../../contracts/src/semantics.mjs';
import {canonical} from '../../contracts/src/index.mjs';
import {createHash} from 'node:crypto';
const validators = {bundle,result,terminology};
const digest = text => createHash('sha256').update(text).digest('hex');
function validateDocument(name, doc) {
  ensure(validators[name](doc), `Invalid ${name} typed fields`);
  if (name === 'result') validateResult(doc);
  if (name === 'bundle') {
    ensure(doc.request_sha256 === digest(canonical(doc.request)), 'Request hash mismatch');
    ensure(doc.profile.sha256 === '2e106f260cbcfcaccab23c55846384886dc5c0b2d7178b48e62c7f82cbe18951', 'Profile hash mismatch');
    ensure(doc.eligible_for_current_pointer === (doc.publication === 'complete'), 'Invalid publication eligibility');
    if (doc.publication === 'complete') ensure(doc.disclosure.applied && doc.disclosure.approval_id !== null &&
      doc.outputs.every(o=>['computed','empty_source','empty_population','suppressed'].includes(o.state)), 'Incomplete or unapproved publication');
    ensure(doc.source.snapshot.state !== 'unknown' || (!doc.reproducibility.consistent_snapshot && doc.reproducibility.limitation !== null), 'Unknown snapshot limitation required');
    ensure(doc.reproducibility.consistent_snapshot || doc.reproducibility.limitation !== null, 'Snapshot limitation required');
    ensure(doc.reproducibility.execution_start <= doc.reproducibility.execution_end, 'Invalid execution window');
  }
  if (name === 'terminology') {
    ensure(new Set(doc.concepts.map(c=>c.concept_id)).size === doc.concepts.length,'Duplicate terminology concept');
    for (const c of doc.concepts) ensure(c.state === 'available' ? c.concept_name !== null && c.domain_id !== null && c.reason === null :
      c.concept_name === null && c.domain_id === null && c.reason !== null,'Invalid terminology availability');
  }
}
try {
  ensure(process.argv.length === 3,'Supply one bundle directory');
  await validateDirectory(process.argv[2],validateDocument,(m,d,t)=>validateBundleDocuments(m,d,t,{profile,validateDocument}));
  process.stdout.write('Validated bundle\n');
} catch {process.stderr.write('Bundle validation failed\n');process.exitCode=1;}
