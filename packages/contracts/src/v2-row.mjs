// Independent development oracle. End-user publication uses native R.
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import {canonical} from './index.mjs';
const assets=fileURLToPath(new URL('../../../inst/contracts/v2/',import.meta.url));
const ajv=new Ajv2020({strict:false,allErrors:false});addFormats(ajv);
const validate=ajv.compile(JSON.parse(readFileSync(`${assets}row.schema.json`,'utf8')));
const registry=JSON.parse(readFileSync(`${assets}rows.json`,'utf8'));
const metrics=new Map(registry.metrics.map(m=>[m.id,m]));
const need=(test,message)=>{if(!test)throw new Error(message);};
const exact=x=>{const neg=x.startsWith('-'),p=x.replace(/^-/,'').split('.');return {n:BigInt(`${neg?'-':''}${p.join('')}`),scale:p[1]?.length??0};};
function cmp(a,b,multiplier='1') {a=exact(a);b=exact(b);const scale=Math.max(a.scale,b.scale);a.n*=BigInt(multiplier);return a.n*10n**BigInt(scale-a.scale)-b.n*10n**BigInt(scale-b.scale);}
export function validateSavedRow(metricId,row) {
  need(validate({metric_id:metricId,row}),'Row schema rejected');
  const metric=metrics.get(metricId);
  const identity={metric_id:metricId,metric_version:metric.version,row_kind:row.row_kind,dimensions:row.dimensions};
  need(row.row_key===createHash('sha256').update(`${canonical(identity)}\n`).digest('hex'),'Row identity mismatch');
  need(row.state==='computed'?row.reason_code===null:typeof row.reason_code==='string','State/reason');
  if(['unsupported','unavailable'].includes(row.state))need(metricId==='core.visit.care_setting_count'&&row.dimensions.setting_kind==='place_of_service','Unavailable required stratum');
  if(['suppressed','unsupported','unavailable'].includes(row.state)) {need(row.values===null&&!row.denominator_refs.length,'Suppression leak');return;}
  need(row.values!==null,'Missing values');const v=row.values;
  if(['counts','eligibility_counts'].includes(row.row_kind)) {
    if(row.state!=='computed')need(Object.values(v).every(x=>x==='0'),'Empty count');
    if(v.person_count!==undefined&&v.record_count!==undefined)need(BigInt(v.person_count)<=BigInt(v.record_count),'People exceed records');
  }
  if(row.row_kind==='summary') {
    const stats=Object.keys(v).filter(k=>k!=='n');
    if(v.n==='0')need(row.state!=='computed'&&stats.every(k=>v[k]===null),'Zero summary');
    else {
      need(row.state==='computed'&&stats.every(k=>v[k]!==null),'Missing summary');
      need(v.mean_numerator===v.sum&&v.mean_denominator===v.n,'Rational mean');
      need(cmp(v.min,v.sum,v.n)<=0n&&cmp(v.max,v.sum,v.n)>=0n,'Sum bounds');
      const keys=['min','p10','p25','p50','p75','p90','max'];
      keys.slice(1).forEach((key,i)=>need(cmp(v[keys[i]],v[key])<=0n,'Quantile order'));
    }
  }
  if(row.row_kind==='metadata') {
    const coverage=x=>{need(x.complete===true,'Incomplete coverage');if(x.scope_kind==='standard_full')need(x.excluded_record_count==='0','Excluded full-scope rows');};
    const identity=x=>need(x.state==='known'?x.value!==null&&x.basis!==null&&x.assertion_id!==null&&x.reason_code===null:x.value===null&&x.reason_code!==null,'Identity assertion');
    if(metricId==='core.source.passport') {identity(v.source_release);identity(v.vocabulary_release);coverage(v.coverage);need(v.generation.started_at<=v.generation.ended_at,'Generation order');need(!v.consistency.reusable||v.consistency.within_run==='verified_immutable_source','Reuse consistency');}
    if(metricId==='core.source.capabilities')need(['available','available_empty'].includes(v.state)?v.reason_code===null:v.reason_code!==null,'Capability reason');
    if(metricId==='core.execution.output_status') {need(v.state==='computed'?v.reason_code===null:v.reason_code!==null,'Output reason');coverage(v.coverage);need(v.integrity.state==='validated'?v.integrity.sha256!==null&&v.integrity.reason_code===null:v.integrity.sha256===null&&v.integrity.reason_code!==null,'Integrity assertion');}
    if(metricId==='core.execution.timing')need(v.availability==='measured'?v.duration_ms!==null&&v.reason_code===null:v.duration_ms===null&&v.reason_code!==null,'Timing availability');
  }
  for(const ref of row.denominator_refs)need(Object.hasOwn(v,ref.measure),'Denominator measure');
  const d=row.dimensions;
  if(d.representation_flags!==undefined)need((metricId.includes('measurement')?/^[01]{3}$/:/^[01]{4}[01X]$/).test(d.representation_flags),'Representation flags');
  if(d.presence_bits!==undefined)need(/^[01]{9}$/.test(d.presence_bits),'Domain mask');
  if(d.period_kind!==undefined) {
    if(d.period_kind==='undated'||(d.period_kind==='full_scope'&&d.period_start==='null'))need(d.period_start==='null'&&d.period_end==='null','Undated period');
    else {need(/^\d{4}-\d{2}-\d{2}$/.test(d.period_start)&&d.period_start<=d.period_end,'Period bounds');
      if(d.period_kind==='calendar_month')need(d.period_start.slice(0,7)===d.period_end.slice(0,7),'Month bounds');
      if(d.period_kind==='calendar_year')need(d.period_start.slice(0,4)===d.period_end.slice(0,4),'Year bounds');}
  }
}

