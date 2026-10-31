import type {BundleManifest, MetricId, ResultDocument, State} from '../../contracts/src/index.mjs';
import {canonical} from '../../contracts/src/index.mjs';

type Available = 'computed' | 'empty_source' | 'empty_population';
export type VerifiedObservation = {available: true; state: Available; people: string; personDays: string;
  months: {month: string; count: string; state: Available}[]} |
  {available: false; state: State; reason: string};
export const observationIds = ['observation.person_count', 'observation.monthly_person_count', 'observation.person_days'] as const;
function requireValid(test: unknown, message: string): asserts test {if (!test) throw new Error(`Observation results: ${message}`);}
export function verifyObservation(manifest: BundleManifest, documents: Map<MetricId, ResultDocument>, allPeople: string): VerifiedObservation {
  const docs = observationIds.map(id => documents.get(id)!);
  const available = ['computed', 'empty_source', 'empty_population'];
  const failure = docs.find(d => !available.includes(d.state));
  if (failure) {
    requireValid(docs.every(d => ['failed', 'unavailable', 'inaccessible', 'suppressed'].includes(d.state) && d.rows === null && !!d.reason), 'inconsistent availability');
    return {available: false, state: failure.state, reason: failure.reason!};
  }
  const total = BigInt(allPeople);
  const expectedState = (count: string): Available => total === 0n ? 'empty_source' : count === '0' ? 'empty_population' : 'computed';
  function rows(id: typeof observationIds[number], months: boolean) {
    const d = documents.get(id)!;
    requireValid(d.rows && (months || d.rows.length === 1), 'invalid singleton grain');
    for (const row of d.rows) {
      requireValid(row.values && 'count' in row.values && row.state === expectedState(row.values.count) &&
        (row.state === 'computed' ? row.reason === null : !!row.reason), 'invalid count/state');
      if (!months) requireValid(canonical(row.dimensions) === '{}', 'invalid singleton dimensions');
      if (id === 'observation.person_days') requireValid(row.denominator === null, 'person-days cannot have a person denominator');
      else requireValid(row.denominator?.metric_id === 'person.count' && row.denominator.field === 'count' &&
        canonical(row.denominator.dimensions) === '{}' && row.denominator.value === allPeople, 'wrong all-source denominator');
    }
    return d.rows as readonly {values: {count: string}; state: Available; dimensions: {month?: string}}[];
  }
  const people = rows('observation.person_count', false)[0].values.count;
  const personDays = rows('observation.person_days', false)[0].values.count;
  const monthly = rows('observation.monthly_person_count', true);
  requireValid(docs.every(d => d.state === expectedState(people) && (d.state === 'computed' ? d.reason === null : !!d.reason)), 'invalid document state');
  const {start, end} = manifest.request.window;
  let year = Number(start.slice(0, 4)), month = Number(start.slice(5, 7));
  const expectedMonths: string[] = [];
  const touchedMonths = (Number(end.slice(0, 4)) - year) * 12 + Number(end.slice(5, 7)) - month + 1;
  for (let i = 0; i < touchedMonths; i++) {
    expectedMonths.push(`${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-01`);
    if (++month === 13) {month = 1; year++;}
  }
  requireValid(monthly.length === expectedMonths.length && monthly.every((r, i) => r.dimensions.month === expectedMonths[i]), 'missing, duplicate or out-of-order months');
  const n = BigInt(people), days = BigInt(personDays), counts = monthly.map(r => BigInt(r.values.count));
  const sum = counts.reduce((a, b) => a + b, 0n);
  const windowDays = BigInt((Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / 86400000 + 1);
  requireValid(n <= total && n <= days && n <= sum && counts.every(c => c <= n) && days >= sum && days <= n * windowDays &&
    (n > 0n || days === 0n) && (total > 0n || n === 0n), 'inconsistent person/month/day counts');
  return {available: true, state: expectedState(people), people, personDays,
    months: monthly.map(r => ({month: r.dimensions.month!, count: r.values.count, state: r.state}))};
}
