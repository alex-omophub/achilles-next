import {lazy, Suspense, useId} from 'react';
import type {VerifiedObservation} from './observation';
const ObservationChart = lazy(() => import('./ObservationChart'));

export function ObservationView({observation, start, end}: {observation: VerifiedObservation; start: string; end: string}) {
  const title = useId();
  if (!observation.available) return <section className="observation unavailable" aria-labelledby={title}>
    <h2 id={title}>{observation.state === 'suppressed' ? 'Observation opportunity suppressed' : 'Observation opportunity unavailable'}</h2><p>{observation.reason}</p>
    <p>{observation.state === 'suppressed'
      ? 'State: suppressed. The output policy intentionally removes these values. Access changes or regeneration do not release them. No observation counts are inferred.'
      : `State: ${observation.state}. Check observation periods and access, regenerate, then reopen. No observation counts are inferred.`}</p>
  </section>;
  const chartable = observation.months.every(m => BigInt(m.count) <= BigInt(Number.MAX_SAFE_INTEGER));
  const data = chartable ? observation.months.map(m => ({month: m.month.slice(0, 7), count: Number(m.count)})) : [];
  return <section className="observation" aria-labelledby={title}>
    <h2 id={title}>Observation opportunity</h2>
    <p>Inclusive window: <strong>{start} to {end}</strong> · {observation.state.replaceAll('_', ' ')}</p>
    <dl className="observation-summary"><div><dt>Observed people in window</dt><dd>{observation.people}</dd></div>
      <div><dt>Unique observed person-days</dt><dd>{observation.personDays}</dd></div></dl>
    <h3>Monthly observed people</h3>
    <p>Distinct people with at least one observed day in each clipped calendar month.</p>
    {chartable ? <div className="observation-chart" role="group" aria-label="Monthly observed people; exact values in the following table">
      <Suspense fallback={<p role="status">Loading monthly chart. Exact values are available below.</p>}><ObservationChart data={data}/></Suspense>
    </div> : <p>Counts exceed safe chart coordinates. Exact values remain available in the table.</p>}
    <details><summary>Exact monthly values ({observation.months.length} months)</summary>
      <table><caption>Distinct observed people per month, clipped to the request window</caption><thead><tr><th scope="col">Month</th><th scope="col">Observed people</th><th scope="col">State</th></tr></thead>
        <tbody>{observation.months.map(m => <tr key={m.month}><th scope="row">{m.month.slice(0, 7)}</th><td>{m.count}</td><td>{m.state.replaceAll('_', ' ')}</td></tr>)}</tbody>
      </table></details>
    <aside className="interpretation"><h3>How to interpret these counts</h3>
      <p>Overlapping and adjacent observation periods are merged within each person. Endpoints are inclusive; partial first and last months are retained.</p>
      <p>A person appears once per month and once in the window. Monthly people are not additive. Person-days count each person/date once.</p>
      <p>Observation in an EHR describes recorded capture opportunity. It does not establish claims enrollment, continuous care, population prevalence or joint cohort eligibility.</p>
    </aside>
  </section>;
}
