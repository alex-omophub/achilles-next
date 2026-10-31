import {readFileSync} from 'node:fs';
import {validateSavedRow} from '../src/v2-row.mjs';
const cases=JSON.parse(readFileSync(process.argv[2],'utf8'));
for(const c of cases){let ok=true;try{validateSavedRow(c.metric_id,c.row);}catch{ok=false;}
 if(ok!==c.valid)throw new Error(`Differential mismatch: ${c.metric_id}/${c.row.row_kind}/${c.label}`);}
console.log(`V2_DIFFERENTIAL_OK: ${cases.length} vectors`);
