/** v1 contracts. Types describe the future viewer API; no UI mount is shipped. */
export type ContractVersion = '1.0.0';
export type CountString = string;
export type DecimalString = string;
export type MetricId = 'source.passport'|'source.capabilities'|'person.count'|
  'observation.person_count'|'observation.monthly_person_count'|'observation.person_days'|
  'measurement.record_count'|'measurement.person_count'|'measurement.representation_count'|
  'measurement.unit_count'|'measurement.operator_count'|'measurement.numeric_eligibility_count'|
  'measurement.numeric_summary'|'execution.output_status'|'execution.timing';
export type State = 'computed'|'empty_source'|'empty_population'|'unavailable'|'unsupported'|
  'inaccessible'|'not_requested'|'failed'|'suppressed'|'stale';
export type Identity = {state:'known';id:string;reason:null}|{state:'unknown';id:null;reason:string};
export type Snapshot = ({state:'known';id:string;reason:null;immutable:true;assertion_id:string;
  basis:'database_snapshot'|'institution_assertion'|'synthetic_fixture'})|
  {state:'unknown';id:null;reason:string;immutable:false;assertion_id:null;basis:null};
export interface SourceIdentity {source_id:string;snapshot:Snapshot;data_release:Identity;
  vocabulary_release:Identity;schema_fingerprint:Identity;declared_cdm_version:'5.3'|'5.4'|'5.5'|null}
export interface AccessContext {source_id:string;bundle_id:string;manifest_sha256:string;
  access_scope_id:string;authorization_epoch:string}
export interface AnalysisRequest {profile_id:'alpha-measurement-v1';source_id:string;window:{start:string;end:string};
  measurement_concept_ids:readonly number[];output_scope:'restricted';disclosure_policy_id:string}
export interface Partition {metric_id:MetricId;metric_version:'1.0.0';state:State;reason:string|null;
  path:string;sha256:string;bytes:CountString;rows:CountString}
export interface BundleManifest {contract_version:ContractVersion;bundle_id:string;run_id:string;created_at:string;
  generator:{name:string;version:string};profile:{id:'alpha-measurement-v1';revision:'1.0.0';sha256:string};
  source:SourceIdentity;request:AnalysisRequest;request_sha256:string;publication:'complete'|'partial'|'failed';
  eligible_for_current_pointer:boolean;disclosure:{policy_id:string;applied:boolean;approval_id:string|null;scope:'restricted'};
  reproducibility:{consistent_snapshot:boolean;execution_start:string;execution_end:string;limitation:string|null};
  outputs:readonly Partition[];terminology:{path:'terminology.json';sha256:string;bytes:CountString};
  timing_phases:readonly ['compute','materialize','validate','export']}
export type RawTag = 'null'|'zero'|`id:${number}`;
export type Period = {measurement_concept_id:number;period_kind:'window'|'month';period_start:string;period_end:string};
export interface NumericSummary {n:CountString;sum:DecimalString|null;min:DecimalString|null;max:DecimalString|null;
  mean_numerator:DecimalString|null;mean_denominator:CountString|null;p10:DecimalString|null;p25:DecimalString|null;
  p50:DecimalString|null;p75:DecimalString|null;p90:DecimalString|null}
export interface Passport {source_id:string;source_snapshot_id:string|null;data_release_id:string|null;
  declared_cdm_version:string|null;observed_schema_evidence:Identity;vocabulary_release_id:string|null;
  profile_id:'alpha-measurement-v1';profile_revision:'1.0.0';metric_versions:Record<MetricId,'1.0.0'>;run_id:string}
export interface Values {
  'source.passport':Passport;
  'source.capabilities':{table_present:boolean|null;column_present:boolean|null;readable:boolean|null;
    required_for:readonly MetricId[];availability:'available'|'absent'|'inaccessible'|'unknown';reason:string|null};
  'person.count':{count:CountString};'observation.person_count':{count:CountString};
  'observation.monthly_person_count':{count:CountString};'observation.person_days':{count:CountString};
  'measurement.record_count':{count:CountString};'measurement.person_count':{count:CountString};
  'measurement.representation_count':{count:CountString};'measurement.unit_count':{count:CountString};
  'measurement.operator_count':{count:CountString};'measurement.numeric_eligibility_count':{count:CountString};
  'measurement.numeric_summary':NumericSummary;
  'execution.output_status':{state:State;reason:string|null;requested:boolean;metric_version:'1.0.0';source_id:string};
  'execution.timing':{duration_ms:CountString|null;availability:'measured'|'unavailable';reason:string|null};
}
export interface Dimensions {
  'source.passport':Record<string,never>;'source.capabilities':{probe_id:string};'person.count':Record<string,never>;
  'observation.person_count':Record<string,never>;'observation.person_days':Record<string,never>;
  'observation.monthly_person_count':{month:string};'measurement.record_count':Period;'measurement.person_count':Period;
  'measurement.representation_count':Period&{numeric_present:boolean;coded_present:boolean;source_text_present:boolean};
  'measurement.unit_count':Period&{raw_unit_tag:RawTag};'measurement.operator_count':Period&{raw_operator_tag:RawTag};
  'measurement.numeric_eligibility_count':Period&{eligibility_reason:'missing_numeric'|'non_finite_numeric'|'explicit_operator'|'missing_unit'|'unmapped_unit'|'unknown_or_invalid_unit'|'eligible'};
  'measurement.numeric_summary':{measurement_concept_id:number;unit_concept_id:number;raw_operator_tag:'null'|'zero'};
  'execution.output_status':{metric_id:MetricId};'execution.timing':{metric_id:MetricId;phase:'compute'|'materialize'|'validate'|'export'};
}
export type Denominator = {metric_id:MetricId;dimensions:object;field:'count'|'n';value:CountString|null};
export type ResultRow<M extends MetricId> = {dimensions:Dimensions[M];denominator:Denominator|null}&(
  {state:'computed';reason:null;values:Values[M]}|{state:'empty_source'|'empty_population';reason:string;values:Values[M]}|
  {state:'suppressed';reason:string;values:null});
export type ResultDocument<M extends MetricId=MetricId> = M extends MetricId ? {contract_version:ContractVersion;bundle_id:string;
  source_id:string;run_id:string;request_sha256:string;metric_id:M;metric_version:'1.0.0'}&(
  {state:'computed';reason:null;rows:readonly ResultRow<M>[]}|
  {state:'empty_source'|'empty_population';reason:string;rows:readonly ResultRow<M>[]}|
  {state:Exclude<State,'computed'|'empty_source'|'empty_population'>;reason:string;rows:null}) : never;
export interface TerminologyDocument {contract_version:ContractVersion;provider_id:string;provider_version:string;
  source_id:string;vocabulary_release:Identity;concepts:readonly {concept_id:number;state:'available'|'unknown'|'unavailable';
  concept_name:string|null;domain_id:string|null;reason:string|null}[]}
export interface ReadOptions {signal:AbortSignal;requestId:string}
/** Return immutable UTF-8 JSON bytes; the consumer verifies hashes before decoding. */
export interface ResultProvider {
  getManifest(context:Readonly<AccessContext>,options:ReadOptions):Promise<Uint8Array>;
  getResult(context:Readonly<AccessContext>,metricId:MetricId,options:ReadOptions):Promise<Uint8Array>;
  getTerminology(context:Readonly<AccessContext>,options:ReadOptions):Promise<Uint8Array>;
}
/** Optional metadata-only capability, disabled by default. No numeric result writes. */
export interface ConceptEnrichmentProvider {readonly providerId:string;readonly providerVersion:string;
  getConcepts(context:Readonly<AccessContext>,conceptIds:readonly number[],options:ReadOptions):Promise<TerminologyDocument>}
export type ViewerEvent = {contract_version:ContractVersion;event_id:string;instance_id:string;generation:number;
  correlation_id:string;origin:'user'|'host'|'system';context:Readonly<AccessContext>}&(
  {type:'ready'|'destroyed';payload:Record<string,never>}|
  {type:'concept_selected';payload:{concept_id:number}}|
  {type:'navigation_requested';payload:{target:'concept';concept_id:number}}|
  {type:'error';payload:{code:string;message:string}});
export type View = {kind:'metric';metric_id:MetricId}|{kind:'report';report_id:'measurements'}|{kind:'workspace'};
export interface UpdateOptions {context:Readonly<AccessContext>;view:View;correlation_id:string;
  locale?:string;theme?:Readonly<Record<string,string>>}
export interface MountOptions extends UpdateOptions {provider:ResultProvider;instance_id?:string;
  onEvent?:(event:ViewerEvent)=>void;enrichment?:{enabled:boolean;provider:ConceptEnrichmentProvider}}
export type UpdateOutcome = {status:'applied'|'superseded'|'destroyed';generation:number};
export interface AchillesInstance {readonly id:string;readonly ready:Promise<UpdateOutcome>;
  update(options:UpdateOptions):Promise<UpdateOutcome>;destroy():Promise<void>}
/** Interface only: a React/viewer implementation will supply this function later. */
export type MountAchilles = (container:HTMLElement,options:MountOptions)=>AchillesInstance;
export declare const CONTRACT_VERSION:ContractVersion;
export declare function canonical(value:unknown):string;
export declare function sha256(value:string|Uint8Array):Promise<string>;
export declare function toSafeCountNumber(value:CountString):number;
export declare function inputReuseIdentity(manifest:BundleManifest):string|null;
export declare function viewCacheKey(manifest:BundleManifest,context:AccessContext,metricId:MetricId,instanceId:string):string|null;
export declare function assertContext(document:BundleManifest|ResultDocument,context:AccessContext):void;
export declare class ResultAccessError extends Error {
  constructor(code:'UNAUTHENTICATED'|'INACCESSIBLE'|'NOT_FOUND'|'PROVIDER_FAILURE',status?:number|null);
  readonly code:'UNAUTHENTICATED'|'INACCESSIBLE'|'NOT_FOUND'|'PROVIDER_FAILURE';
  readonly status:number|null;
}
/** Experimental transport; the host owns its gateway, authentication and authorization. */
export declare function createFetchResultProvider(options:{baseUrl:string;
  getHeaders?:(context:Readonly<AccessContext>,options:ReadOptions)=>HeadersInit|Promise<HeadersInit>;
  fetch?:typeof globalThis.fetch}):ResultProvider;
