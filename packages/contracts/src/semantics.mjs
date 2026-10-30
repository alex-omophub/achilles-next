// Portable contract semantics shared by producer validation and the browser.
// No filesystem, network or Node imports. Callers supply their schema validator.
import {canonical} from './index.mjs';
export function ensure(test, message) { if (!test) throw new Error(message); }
const AVAILABLE = new Set(['computed','empty_source','empty_population']);
const ALL_STATS = ['sum','min','max','mean_numerator','mean_denominator','p10','p25','p50','p75','p90'];
function reason(state, value) {
  ensure(state === 'computed' ? value === null : typeof value === 'string' && value.length > 0, 'State/reason mismatch');
}
function compareDecimal(a, b, leftMultiplier = 1n) {
  const parse = value => { const [i, f=''] = value.split('.'); return [BigInt(i + f), f.length]; };
  const [x, p] = parse(a), [y, q] = parse(b), scale = Math.max(p,q);
  const left=x*leftMultiplier*10n**BigInt(scale-p), right=y*10n**BigInt(scale-q);
  return left < right ? -1 : left > right ? 1 : 0;
}
export function validateResult(doc) {
  reason(doc.state, doc.reason);
  ensure(AVAILABLE.has(doc.state) ? Array.isArray(doc.rows) : doc.rows === null, 'State/rows mismatch: unavailable values must not leak');
  if (doc.rows === null) return;
  if(doc.state!=='computed') ensure(doc.rows.every(r=>r.state===doc.state||r.state==='suppressed'),'Output/row empty state mismatch');
  const seen=new Set();
  for (const row of doc.rows) {
    const key=canonical(row.dimensions); ensure(!seen.has(key), 'Duplicate result stratum'); seen.add(key);
    reason(row.state,row.reason);
    if (row.state === 'suppressed') { ensure(row.values === null && row.denominator === null, 'Suppressed row leaked values'); continue; }
    ensure(row.values !== null, 'Computed/empty row has no typed values');
    const v=row.values;
    if (row.state !== 'computed') ensure(v.count === '0' || v.n === '0', 'Empty row must carry zero count/n');
    if (doc.metric_id === 'measurement.numeric_summary') {
      ensure(['null','zero'].includes(row.dimensions.raw_operator_tag), 'Nonzero operator cannot enter numeric summary');
      if (v.n === '0') ensure(row.state !== 'computed' && ALL_STATS.every(k => v[k] === null), 'Zero-n summary has non-null statistics or wrong state');
      else {
        ensure(row.state === 'computed' && ALL_STATS.every(k => v[k] !== null), 'Nonempty summary lacks statistics');
        ensure(v.mean_numerator === v.sum && v.mean_denominator === v.n, 'Mean must retain exact sum/n');
        const n=BigInt(v.n);
        ensure(compareDecimal(v.min,v.sum,n)<=0 && compareDecimal(v.max,v.sum,n)>=0, 'Numeric sum outside exact n × min/max bounds');
        const ordered=['min','p10','p25','p50','p75','p90','max'];
        ensure(ordered.slice(1).every((k,i) => compareDecimal(v[ordered[i]],v[k]) <= 0), 'Numeric order statistics out of order');
      }
    }
    if (doc.metric_id === 'execution.timing') ensure(v.availability === 'measured' ? v.duration_ms !== null && v.reason === null :
      v.duration_ms === null && v.reason !== null, 'Unavailable timing must not become zero');
    if (doc.metric_id === 'source.capabilities') ensure(v.availability === 'available' ?
      v.table_present === true && v.column_present === true && v.readable === true && v.reason === null :
      v.reason !== null, 'Capability availability/reason is inconsistent');
    if (doc.metric_id === 'source.capabilities' && v.availability === 'absent')
      ensure(v.table_present === false || v.column_present === false, 'Absent capability must identify a missing table or column');
    if (doc.metric_id === 'execution.output_status') reason(v.state,v.reason);
  }
}
export function periods(request) {
  const {start,end}=request.window, output=[];
  const [year,month]=start.split('-').map(Number), [ey,em]=end.split('-').map(Number);
  const count=(ey-year)*12+em-month+1;
  ensure(start<=end && count>=1 && count<=120, 'Invalid bounded window');
  output.push({period_kind:'window',period_start:start,period_end:end});
  for(let i=0;i<count;i++) {
    const y=year+Math.floor((month-1+i)/12),m=(month-1+i)%12+1;
    const first=`${String(y).padStart(4,'0')}-${String(m).padStart(2,'0')}-01`;
    const date=new Date(`${first}T00:00:00.000Z`); date.setUTCMonth(date.getUTCMonth()+1);date.setUTCDate(0);
    output.push({period_kind:'month',period_start:start>first?start:first,period_end:end<date.toISOString().slice(0,10)?end:date.toISOString().slice(0,10)});
  }
  return output;
}
export function validateBundleDocuments(manifest, documents, terminology, {profile, validateDocument}) {
  validateDocument('bundle',manifest);validateDocument('terminology',terminology);
  ensure(manifest.source.source_id===manifest.request.source_id,'Request/source mismatch');
  ensure(manifest.source.schema_fingerprint.state!=='known'||/^[0-9a-f]{64}$/.test(manifest.source.schema_fingerprint.id),'Schema identity must be a fingerprint');
  ensure(manifest.source.snapshot.state!=='unknown'||(!manifest.reproducibility.consistent_snapshot&&manifest.reproducibility.limitation!==null),'Unknown snapshot needs reproducibility limitation');
  ensure(manifest.reproducibility.consistent_snapshot||manifest.reproducibility.limitation!==null,'Inconsistent execution needs reproducibility limitation');
  ensure(manifest.reproducibility.execution_start<=manifest.reproducibility.execution_end,'Invalid execution window');
  ensure(documents.size===manifest.outputs.length && [...documents.keys()].every(id=>profile.required_outputs.includes(id)),'Unexpected result documents');
  ensure(terminology.source_id===manifest.source.source_id && canonical(terminology.vocabulary_release)===canonical(manifest.source.vocabulary_release), 'Terminology scope/vocabulary mismatch');
  ensure(manifest.eligible_for_current_pointer===(manifest.publication==='complete'),'Partial run cannot replace current complete pointer');
  if(manifest.publication==='complete') ensure(manifest.disclosure.applied && manifest.disclosure.approval_id!==null && manifest.outputs.every(o=>AVAILABLE.has(o.state)||o.state==='suppressed'),'Complete bundle has incomplete outputs or unapplied disclosure policy');
  ensure(manifest.disclosure.scope===manifest.request.output_scope && manifest.disclosure.policy_id===manifest.request.disclosure_policy_id,'Disclosure scope/policy mismatch');
  ensure(new Set(manifest.outputs.map(o=>o.metric_id)).size===profile.required_outputs.length && profile.required_outputs.every(id=>manifest.outputs.some(o=>o.metric_id===id)),'Missing/duplicate requested outputs');
  ensure(terminology.contract_version===manifest.contract_version,'Mixed contract versions');
  if(manifest.request.output_scope==='distributable') {
    ensure(manifest.contract_version==='1.1.0' && manifest.disclosure.applied && manifest.disclosure.approval_id!==null && manifest.disclosure.policy_id==='synthetic-aggregates-v1','Unapproved distributable scope');
    const permitted=new Set(['source.passport','person.count','execution.output_status']);
    ensure(manifest.outputs.every(p=>permitted.has(p.metric_id)||p.state==='suppressed'),'Restricted partition in distributable bundle');
    ensure(terminology.concepts.length===0 && manifest.source.source_id==='fixture:synthetic' && manifest.source.snapshot.state==='unknown' && manifest.source.data_release.state==='unknown' && manifest.source.vocabulary_release.state==='unknown' && manifest.source.schema_fingerprint.state==='unknown','Restricted metadata in distributable bundle');
  }
  const byId=new Map(), cells=new Map();
  for(const partition of manifest.outputs) {
    const doc=documents.get(partition.metric_id);ensure(doc,'Missing declared result document');validateDocument('result',doc);
    ensure(doc.contract_version===manifest.contract_version,'Mixed contract versions');
    ensure(doc.metric_id===partition.metric_id && doc.metric_version===partition.metric_version && doc.state===partition.state && doc.reason===partition.reason, 'Partition/result identity or status mismatch');
    ensure(doc.bundle_id===manifest.bundle_id && doc.source_id===manifest.source.source_id && doc.run_id===manifest.run_id && doc.request_sha256===manifest.request_sha256,'Result source/run/request mismatch');
    ensure(partition.rows===String(doc.rows?.length??0),'Declared row count mismatch');byId.set(doc.metric_id,doc);
    cells.set(doc.metric_id,new Map((doc.rows??[]).map(row=>[canonical(row.dimensions),row])));
  }
  const lookup=(mid,dims)=>cells.get(mid)?.get(canonical(dims));
  const passport=lookup('source.passport',{})?.values;
  if(passport) ensure(passport.source_id===manifest.source.source_id && passport.source_snapshot_id===manifest.source.snapshot.id &&
    passport.data_release_id===manifest.source.data_release.id && passport.vocabulary_release_id===manifest.source.vocabulary_release.id &&
    passport.declared_cdm_version===manifest.source.declared_cdm_version && canonical(passport.observed_schema_evidence)===canonical(manifest.source.schema_fingerprint) &&
    passport.run_id===manifest.run_id,'Passport/manifest identity mismatch');
  const ps=periods(manifest.request);
  const periodKey=d=>[d.period_kind,d.period_start,d.period_end].join('|');
  const periodKeys=new Set(ps.map(periodKey));
  for(const doc of documents.values()) for(const row of doc.rows??[]) {
    let expected=null;const d=row.dimensions;
    if(['observation.person_count','observation.monthly_person_count'].includes(doc.metric_id)) expected=['person.count',{},'count'];
    if(doc.metric_id==='measurement.person_count') expected=d.period_kind==='window'?['observation.person_count',{},'count']:
      ['observation.monthly_person_count',{month:d.period_start.slice(0,7)+'-01'},'count'];
    if(['measurement.representation_count','measurement.unit_count','measurement.operator_count','measurement.numeric_eligibility_count'].includes(doc.metric_id))
      expected=['measurement.record_count',Object.fromEntries(['measurement_concept_id','period_kind','period_start','period_end'].map(k=>[k,d[k]])),'count'];
    if(doc.metric_id==='measurement.numeric_summary') expected=[doc.metric_id,d,'n'];
    if(row.state!=='suppressed') ensure(expected ? row.denominator?.metric_id===expected[0] && canonical(row.denominator.dimensions)===canonical(expected[1]) && row.denominator.field===expected[2] : row.denominator===null,'Wrong denominator definition');
    if(row.denominator) {
      const d=row.denominator,target=lookup(d.metric_id,d.dimensions);
      ensure(target && target.values?.[d.field]===d.value,'Denominator does not resolve to exact source cell');
    }
    if('measurement_concept_id' in row.dimensions) ensure(manifest.request.measurement_concept_ids.includes(row.dimensions.measurement_concept_id),'Result concept outside request');
    if('period_kind' in d) ensure(periodKeys.has(periodKey(d)),'Result period outside request');
    if(doc.metric_id==='measurement.numeric_summary') ensure(terminology.concepts.some(c=>c.concept_id===row.dimensions.unit_concept_id && c.state==='available' && c.domain_id==='Unit'),'Numeric unit is not known locally');
    if(doc.metric_id==='execution.output_status' && row.values) {
      const p=manifest.outputs.find(p=>p.metric_id===row.dimensions.metric_id);
      ensure(p && row.values.state===p.state && row.values.reason===p.reason && row.values.requested===true && row.values.source_id===manifest.source.source_id,'Execution ledger disagrees with requested outputs');
    }
  }
  const sameSet=(actual,expected,label)=>ensure(canonical([...actual].sort())===canonical([...expected].sort()),`Missing/extra dense cells: ${label}`);
  const keys=rows=>(rows??[]).map(r=>canonical(r.dimensions));
  const dense=['measurement.record_count','measurement.person_count','measurement.representation_count','measurement.numeric_eligibility_count'];
  const base=manifest.request.measurement_concept_ids.flatMap(c=>ps.map(p=>({measurement_concept_id:c,...p})));
  for(const mid of dense) if(byId.get(mid).rows!==null) {
    let expected=base;
    if(mid==='measurement.representation_count') expected=base.flatMap(d=>[false,true].flatMap(n=>[false,true].flatMap(c=>[false,true].map(s=>({...d,numeric_present:n,coded_present:c,source_text_present:s})))));
    if(mid==='measurement.numeric_eligibility_count') expected=base.flatMap(d=>profile.numeric_eligibility.map(r=>({...d,eligibility_reason:r.reason})));
    sameSet(keys(byId.get(mid).rows),expected.map(canonical),mid);
  }
  const singletons=['source.passport','person.count','observation.person_count','observation.person_days'];
  for(const mid of singletons) if(byId.get(mid).rows!==null) sameSet(keys(byId.get(mid).rows),[canonical({})],mid);
  if(byId.get('source.capabilities').rows!==null) sameSet(keys(byId.get('source.capabilities').rows),profile.prerequisite_probes.map(p=>canonical({probe_id:p.id})),'capabilities');
  if(byId.get('execution.output_status').rows!==null) sameSet(keys(byId.get('execution.output_status').rows),profile.required_outputs.map(metric_id=>canonical({metric_id})),'output ledger');
  if(byId.get('execution.timing').rows!==null) sameSet(keys(byId.get('execution.timing').rows),profile.required_outputs.flatMap(metric_id=>manifest.timing_phases.map(phase=>canonical({metric_id,phase}))),'timing');
  const months=ps.filter(p=>p.period_kind==='month').map(p=>canonical({month:p.period_start.slice(0,7)+'-01'}));
  if(byId.get('observation.monthly_person_count').rows!==null) sameSet(keys(byId.get('observation.monthly_person_count').rows),months,'monthly observed people');
  // Index base-period groups once; dense requests must not rescan every result
  // row for every denominator and reconciliation cell in the browser.
  const grouped=new Map();
  for(const mid of ['measurement.representation_count','measurement.numeric_eligibility_count','measurement.unit_count','measurement.operator_count']) {
    const rows=byId.get(mid).rows;
    if(rows===null) continue;
    const groups=new Map();
    for(const row of rows) {
      const key=canonical(Object.fromEntries(['measurement_concept_id','period_kind','period_start','period_end'].map(k=>[k,row.dimensions[k]])));
      if(!groups.has(key)) groups.set(key,[]);
      groups.get(key).push(row);
    }
    grouped.set(mid,groups);
  }
  for(const d of base) {
    const records=lookup('measurement.record_count',d)?.values?.count;
    for(const mid of ['measurement.representation_count','measurement.numeric_eligibility_count','measurement.unit_count','measurement.operator_count']) {
      const rows=grouped.has(mid)?(grouped.get(mid).get(canonical(d))??[]):undefined;
      if(records!==undefined && rows && rows.every(r=>r.values!==null)) ensure(rows.reduce((s,r)=>s+BigInt(r.values.count),0n)===BigInt(records),`Counts do not reconcile: ${mid}`);
    }
    const tested=lookup('measurement.person_count',d),den=tested?.denominator;
    if(tested?.values && den?.value!==null && den) ensure(BigInt(tested.values.count)<=BigInt(den.value),'Tested people exceed observed denominator');
  }
  for(const concept of manifest.request.measurement_concept_ids) {
    const window=base.find(d=>d.measurement_concept_id===concept&&d.period_kind==='window');
    const rows=byId.get('measurement.numeric_summary').rows?.filter(r=>r.dimensions.measurement_concept_id===concept);
    const eligible=lookup('measurement.numeric_eligibility_count',{...window,eligibility_reason:'eligible'})?.values?.count;
    if(rows&&eligible!==undefined&&rows.every(r=>r.values!==null)) ensure(rows.reduce((n,r)=>n+BigInt(r.values.n),0n)===BigInt(eligible),'Numeric n does not reconcile to eligible records');
    const records=lookup('measurement.record_count',window)?.values?.count;
    const monthly=base.filter(d=>d.measurement_concept_id===concept&&d.period_kind==='month').map(d=>lookup('measurement.record_count',d)?.values?.count);
    if(records!==undefined&&monthly.every(v=>v!==undefined)) ensure(monthly.reduce((n,v)=>n+BigInt(v),0n)===BigInt(records),'Monthly records do not reconcile to window');
  }
  if(manifest.publication==='complete') for(const row of byId.get('source.capabilities').rows??[]) {
    const probe=profile.prerequisite_probes.find(p=>p.id===row.dimensions.probe_id);
    ensure(!probe.required||row.values?.availability==='available','Complete alpha lacks a required capability');
  }
  return {manifest,documents,terminology};
}
