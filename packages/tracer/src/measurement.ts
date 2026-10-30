import type {AnalysisRequest, MetricId, ResultDocument, TerminologyDocument} from '../../contracts/src/index.mjs';
export const measurementIds: MetricId[] = ['measurement.record_count', 'measurement.person_count', 'measurement.representation_count',
  'measurement.unit_count', 'measurement.operator_count', 'measurement.numeric_eligibility_count', 'measurement.numeric_summary'];
export interface VerifiedMeasurement {documents: ReadonlyMap<MetricId, ResultDocument>; terminology: TerminologyDocument}
export interface ScopeRequest {concept: string; start: string; end: string; jointFilter: boolean}
/** View projections cannot silently become a newly computed population. */
export function savedScope(request: AnalysisRequest, desired: ScopeRequest): {available: true; concept: number} | {available: false; reason: string} {
  if (!/^(0|[1-9][0-9]*)$/.test(desired.concept) || !request.measurement_concept_ids.includes(Number(desired.concept)))
    return {available: false, reason: 'This concept was not generated. Additional computation is required.'};
  if (desired.start !== request.window.start || desired.end !== request.window.end)
    return {available: false, reason: 'This date window was not generated. Additional computation is required.'};
  if (desired.jointFilter) return {available: false, reason: 'Joint patient filters are unavailable in this profile. Additional computation is required.'};
  return {available: true, concept: Number(desired.concept)};
}
export function conceptLabel(terms: TerminologyDocument, id: number): string {
  const c = terms.concepts.find(c => c.concept_id === id);
  return c?.state === 'available' ? `${c.concept_name} · ${id}` : `Unknown local concept · ${id}`;
}
export function rawLabel(terms: TerminologyDocument, tag: string, kind: 'unit' | 'operator'): string {
  if (tag === 'null') return kind === 'operator' ? 'NULL · no explicit comparator' : 'NULL · missing unit';
  if (tag === 'zero') return kind === 'operator' ? '0 · no explicit comparator' : '0 · unmapped unit';
  const idText = tag.slice(3), c = terms.concepts.find(c => String(c.concept_id) === idText);
  const label = c?.state === 'available' ? `${c.concept_name} · ${idText}` : `Unknown local concept · ${idText}`;
  return kind === 'unit' && c?.state === 'available' && c.domain_id !== 'Unit' ? `${label} · invalid unit domain: ${c.domain_id}` : label;
}
