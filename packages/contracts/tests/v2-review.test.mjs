import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {canonical} from '../src/index.mjs';
import {validateSavedRow,matchesSavedRowSchema} from '../src/v2-row.mjs';
const make=(id,dimensions,values)=>{
 const row={row_key:'',dimensions,row_kind:id==='core.execution.output_status'?'metadata':'counts',state:'computed',reason_code:null,values,denominator_refs:[]};
 row.row_key=createHash('sha256').update(`${canonical({metric_id:id,metric_version:'1.0.0',row_kind:row.row_kind,dimensions})}\n`).digest('hex');return row;
};
test('schema and oracle reject non-calendar-month anchors',()=>{
 const id='core.observation_period.boundary_month_count';
 for(const month of ['null','undated','2020-01-15','0000-01-01']) {
  const row=make(id,{boundary_kind:'start',month},{interval_count:'1',person_count:'1'});
  assert.equal(matchesSavedRowSchema(id,row),false);assert.throws(()=>validateSavedRow(id,row));
 }
 validateSavedRow(id,make(id,{boundary_kind:'start',month:'2020-02-01'},{interval_count:'1',person_count:'1'}));
});
test('schema and oracle bound age dimensions',()=>{
 for(const [id,dimensions] of [
  ['core.observation_period.year_gender_age_count',{year:'2020',gender_concept_id:'0',year_age_decile:'14'}],
  ['core.observation_period.year_gender_age_count',{year:'2020',gender_concept_id:'0',year_age_decile:'99'}],
  ['core.observation_period.first_age_count',{year_age_or_unknown:'131',gender_concept_id:'0'}]
 ]) {const row=make(id,dimensions,{person_count:'1'});assert.equal(matchesSavedRowSchema(id,row),false);assert.throws(()=>validateSavedRow(id,row));}
 const id='core.observation_period.first_age_count';
 for(const age of ['0','130','unknown']) validateSavedRow(id,make(id,{year_age_or_unknown:age,gender_concept_id:'0'},{person_count:'1'}));
});
test('schema alone enforces payload presence and suppression',()=>{
 const id='core.person.count';const row=make(id,{}, {person_count:'1'});
 assert.equal(matchesSavedRowSchema(id,row),true);
 assert.equal(matchesSavedRowSchema(id,{...row,values:null}),false);
 const suppressed={...row,state:'suppressed',reason_code:'fixture.policy'};
 assert.equal(matchesSavedRowSchema(id,suppressed),false);
 assert.equal(matchesSavedRowSchema(id,{...suppressed,values:null}),true);
 const ref={measure:'person_count',metric_id:id,row_key:'a'.repeat(64),field:'person_count',value:'1'};
 assert.equal(matchesSavedRowSchema(id,{...suppressed,values:null,denominator_refs:[ref]}),false);
});
test('reduced metadata coverage requires its reason',()=>{
 const id='core.execution.output_status';const v={state:'computed',reason_code:null,required:true,
  coverage:{scope_kind:'declared_reduced',complete:true,excluded_record_count:'2',reason_code:null},
  integrity:{state:'not_validated',sha256:null,reason_code:'fixture.pending'}};
 assert.throws(()=>validateSavedRow(id,make(id,{metric_id:'core.person.count'},v)));
 v.coverage.reason_code='fixture.reduced';validateSavedRow(id,make(id,{metric_id:'core.person.count'},v));
});
