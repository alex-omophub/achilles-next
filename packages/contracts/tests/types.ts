import type {AccessContext, BundleManifest, MountAchilles, ResultDocument, ResultProvider, UpdateOptions, Values} from '../src/index.mjs';
import {inputReuseIdentity, toSafeCountNumber} from '../src/index.mjs';
const count:Values['person.count']={count:'9007199254740993'};
// @ts-expect-error Numeric values cannot replace exact count strings.
const unsafe:Values['person.count']={count:9007199254740993};
declare const manifest:BundleManifest;
const identity:string|null=inputReuseIdentity(manifest);
const safe:number=toSafeCountNumber('5');
declare const provider:ResultProvider;
declare const mount:MountAchilles;
declare const container:HTMLElement;
declare const context:AccessContext;
const instance=mount(container,{provider,context,view:{kind:'metric',metric_id:'person.count'},correlation_id:'mount-1'});
void instance.ready;
void instance.update({context,view:{kind:'report',report_id:'measurements'},correlation_id:'update-2'});
void instance.destroy();
// @ts-expect-error Context updates replace the full context rather than merging a source field.
const incomplete:UpdateOptions={context:{source_id:'another-source'},view:{kind:'workspace'},correlation_id:'bad'};
// @ts-expect-error Provider result transport is immutable bytes, not an unverified decoded object.
const badRead:ResultProvider['getManifest']=async()=>({bundle_id:'unverified'});
// UI consumers can narrow the metric discriminator to its exact typed values.
function displayedCount(result:ResultDocument):string|null {
  if(result.metric_id==='person.count' && result.rows?.[0]?.values) return result.rows[0].values.count;
  return null;
}
void [count,unsafe,identity,safe,incomplete,badRead,displayedCount];
