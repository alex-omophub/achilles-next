import {lazy, Suspense, useId, useState} from 'react';
import type {AnalysisRequest, MetricId, ResultRow} from '../../contracts/src/index.mjs';
import {conceptLabel, measurementIds, rawLabel, savedScope, type ScopeRequest, type VerifiedMeasurement} from './measurement';
const MeasurementChart = lazy(() => import('./MeasurementChart'));

/** Aggregate-only, embeddable report. Scope changes inspect stored cells; they do
 * not query a CDM, mutate a provider, or manufacture new cross-filter results. */
export function MeasurementView({measurement, request, numericStrategy}: {measurement: VerifiedMeasurement; request: AnalysisRequest; numericStrategy: 'reference' | 'weighted'}) {
  const title = useId(), scopeId = useId();
  const initial = (): ScopeRequest => ({concept: String(request.measurement_concept_ids.find(id => measurement.terminology.concepts.some(c => c.concept_id === id && c.state === 'available' && c.domain_id === 'Measurement')) ?? request.measurement_concept_ids[0]), ...request.window, jointFilter: false});
  const [draft, setDraft] = useState<ScopeRequest>(initial);
  const [scope, setScope] = useState<ScopeRequest>(initial);
  const resolved = savedScope(request, scope);
  const {documents, terminology} = measurement;
  const failures = measurementIds.map(id => documents.get(id)!).filter(doc => doc.rows === null);
  function rows<M extends MetricId>(id: M): readonly ResultRow<M>[] {
    return (documents.get(id)?.rows ?? []) as readonly ResultRow<M>[];
  }
  const reset = () => {setDraft(initial()); setScope(initial());};
  const label = (id: number) => conceptLabel(terminology, id);
  if (failures.length) return <section className="measurement unavailable" aria-labelledby={title}>
    <h2 id={title}>Measurement report unavailable</h2><p>No numeric values are inferred for failed prerequisites.</p>
    <ul>{failures.map(doc => <li key={doc.metric_id}>{doc.metric_id}: {doc.state} · {doc.reason}</li>)}</ul>
  </section>;
  const vocabulary = terminology.vocabulary_release;
  const concept = resolved.available ? resolved.concept : null;
  const window = <M extends MetricId,>(id: M) => rows(id).filter(r => 'measurement_concept_id' in r.dimensions &&
    r.dimensions.measurement_concept_id === concept && (!('period_kind' in r.dimensions) || r.dimensions.period_kind === 'window'));
  const records = window('measurement.record_count')[0];
  const tested = window('measurement.person_count')[0];
  const months = rows('measurement.record_count').filter(r => r.dimensions.measurement_concept_id === concept && r.dimensions.period_kind === 'month').map(r => {
    const people = rows('measurement.person_count').find(p => p.dimensions.measurement_concept_id === concept && p.dimensions.period_kind === 'month' && p.dimensions.period_start === r.dimensions.period_start)!;
    return {start: r.dimensions.period_start, end: r.dimensions.period_end, records: r.values?.count ?? null,
      people: people.values?.count ?? null, observed: people.denominator?.value ?? null, state: r.state};
  }).sort((a, b) => a.start.localeCompare(b.start));
  const chartable = months.every(m => m.records !== null && m.people !== null && BigInt(m.records) <= BigInt(Number.MAX_SAFE_INTEGER) && BigInt(m.people) <= BigInt(Number.MAX_SAFE_INTEGER));
  return <section className="measurement" aria-labelledby={title}>
    <div className="count-heading"><div><p className="eyebrow">Measurements · {numericStrategy} report</p><h2 id={title}>From records to distributions</h2></div><span className="status">Saved aggregates</span></div>
    <p className="vocabulary">Local vocabulary: <strong>{vocabulary.state === 'known' ? vocabulary.id : 'Unknown'}</strong>.
      {vocabulary.state === 'unknown' ? ` ${vocabulary.reason}.` : ' Declared CDM_SOURCE metadata; no immutable vocabulary snapshot is asserted.'} Labels come from the local CONCEPT table.</p>
    <label className="concept-select">Saved measurement concept<select value={resolved.available ? String(resolved.concept) : ''} onChange={e => {
      const next = {...initial(), concept: e.target.value}; setScope(next); setDraft(next);
    }}><option value="" disabled>Choose saved scope</option>{request.measurement_concept_ids.map(id => <option key={id} value={id}>{label(id)}</option>)}</select></label>
    <details className="scope-control"><summary>Check another analysis scope</summary>
      <p>Only explicitly selected concepts and the generated window are available. Joint filters need additional computation.</p>
      <form onSubmit={e => {e.preventDefault(); setScope({...draft});}} aria-labelledby={scopeId}>
        <h3 id={scopeId}>Requested scope</h3><div className="scope-fields">
          <label>Concept ID<input inputMode="numeric" value={draft.concept} onChange={e => setDraft({...draft, concept: e.target.value})}/></label>
          <label>Start date<input type="date" value={draft.start} onChange={e => setDraft({...draft, start: e.target.value})}/></label>
          <label>End date<input type="date" value={draft.end} onChange={e => setDraft({...draft, end: e.target.value})}/></label>
        </div><label className="check-label"><input type="checkbox" checked={draft.jointFilter} onChange={e => setDraft({...draft, jointFilter: e.target.checked})}/> Apply a joint patient filter</label>
        <button type="submit">Check availability</button>
      </form>
    </details>
    {!resolved.available ? <div className="error" role="alert"><h3>Additional computation required</h3><p>{resolved.reason}</p>
      <p>The saved report is hidden while this scope is requested. No results have been recalculated.</p><button onClick={reset}>Return to saved scope</button></div> : <>
      <p className="scope-caption">{label(resolved.concept)} · {request.window.start} to {request.window.end} · {records?.state.replaceAll('_', ' ')}</p>
      <dl className="measurement-summary"><div><dt>Measurement records</dt><dd>{records?.values?.count ?? 'Suppressed'}</dd></div>
        <div><dt>Distinct tested people</dt><dd>{tested?.values?.count ?? 'Suppressed'}</dd></div>
        <div><dt>Observed people · same window</dt><dd>{tested?.denominator?.value ?? 'Unavailable'}</dd></div></dl>
      <p>Physical duplicate records are retained. Observation membership is checked once per row. Tested people are deduplicated within each period; these are capture counts, not prevalence estimates.</p>
      <h3>Measurement activity</h3>
      {chartable ? <div role="group" aria-label="Monthly measurement records and distinct tested people; exact values follow">
        <Suspense fallback={<p role="status">Loading activity chart. Exact values are available below.</p>}><MeasurementChart data={months.map(m => ({month: m.start.slice(0, 7), records: Number(m.records), people: Number(m.people)}))}/></Suspense></div> : <p>The chart is unavailable for suppressed values or counts beyond safe coordinates. Use the table below.</p>}
      <details><summary>Exact monthly counts ({months.length} months)</summary><div className="table-scroll"><table className="report-table"><caption>Calendar months clipped to the generated window</caption><thead><tr><th scope="col">Dates</th><th scope="col">Records</th><th scope="col">Tested people</th><th scope="col">Observed people</th><th scope="col">State</th></tr></thead>
        <tbody>{months.map(m => <tr key={m.start}><th scope="row">{m.start} → {m.end}</th><td>{m.records ?? 'Suppressed'}</td><td>{m.people ?? 'Suppressed'}</td><td>{m.observed ?? 'Unavailable'}</td><td>{m.state.replaceAll('_', ' ')}</td></tr>)}</tbody></table></div></details>
      <h3>Result representations</h3><p>Each record occupies one of eight cells. Source text is not a standardized result; non-finite numeric values are still numeric-present.</p>
      <div className="representation-grid">{window('measurement.representation_count').map(r => <div key={`${r.dimensions.numeric_present}-${r.dimensions.coded_present}-${r.dimensions.source_text_present}`}>
        <span>{r.dimensions.numeric_present ? 'Numeric' : 'No numeric'} · {r.dimensions.coded_present ? 'Coded' : 'No code'} · {r.dimensions.source_text_present ? 'Text' : 'No text'}</span><strong>{r.values?.count ?? 'Suppressed'}</strong></div>)}</div>
      <div className="strata-grid"><div><h3>Units as recorded</h3><table className="report-table"><caption>Raw units · window records</caption><thead><tr><th scope="col">Unit</th><th scope="col">Records</th></tr></thead><tbody>
        {window('measurement.unit_count').map(r => <tr key={r.dimensions.raw_unit_tag}><th scope="row">{rawLabel(terminology, r.dimensions.raw_unit_tag, 'unit')}</th><td>{r.values?.count ?? 'Suppressed'}</td></tr>)}
      </tbody></table>{!window('measurement.unit_count').length ? <p>No observed unit strata.</p> : null}</div><div><h3>Operators as recorded</h3><table className="report-table"><caption>Raw operators · window records</caption><thead><tr><th scope="col">Operator</th><th scope="col">Records</th></tr></thead><tbody>
        {window('measurement.operator_count').map(r => <tr key={r.dimensions.raw_operator_tag}><th scope="row">{rawLabel(terminology, r.dimensions.raw_operator_tag, 'operator')}</th><td>{r.values?.count ?? 'Suppressed'}</td></tr>)}
      </tbody></table>{!window('measurement.operator_count').length ? <p>No observed operator strata.</p> : null}</div></div>
      <h3>Numeric eligibility</h3><p>First matching reason wins. Only finite numeric values with a known Unit-domain unit and raw operator NULL or 0 enter a distribution. All nonzero operators, including equality, are excluded.</p>
      <table className="report-table"><caption>Inclusion and exclusion · window records</caption><thead><tr><th scope="col">Reason</th><th scope="col">Records</th></tr></thead><tbody>{window('measurement.numeric_eligibility_count').map(r => <tr key={r.dimensions.eligibility_reason}><th scope="row">{r.dimensions.eligibility_reason.replaceAll('_', ' ')}</th><td>{r.values?.count ?? 'Suppressed'}</td></tr>)}</tbody></table>
      <h3>{numericStrategy === 'weighted' ? 'Weighted distributions' : 'Reference distributions'}</h3><p>Each unit and raw operator has its own summary. No unit conversion or pooling. NULL and 0 mean no explicit comparator; they do not prove uncensored values. Quantiles are observed values at rank ceil(p × n), with duplicate multiplicity retained.</p>
      {!window('measurement.numeric_summary').length ? <p>No observed mapped-unit / allowed-operator groups. No distribution is inferred.</p> : null}
      {window('measurement.numeric_summary').map(r => <section className="numeric-stratum" key={`${r.dimensions.unit_concept_id}-${r.dimensions.raw_operator_tag}`}>
        <h4>{label(r.dimensions.unit_concept_id)} · {rawLabel(terminology, r.dimensions.raw_operator_tag, 'operator')}</h4>
        <p>{r.state.replaceAll('_', ' ')} · n = {r.values?.n ?? 'Suppressed'}. {r.reason}</p>
        {r.values && r.values.n !== '0' ? <>
          <dl className="quantile-grid">{(['p10', 'p25', 'p50', 'p75', 'p90'] as const).map(k => <div key={k}><dt>{k === 'p50' ? 'Median · p50' : k}</dt><dd>{r.values![k]}</dd></div>)}</dl>
          <div className="table-scroll"><table className="report-table"><caption>Exact decimal statistics</caption><tbody>
            <tr><th scope="row">Range</th><td>{r.values.min} to {r.values.max}</td></tr><tr><th scope="row">Sum</th><td>{r.values.sum}</td></tr>
            <tr><th scope="row">Mean · exact sum / n</th><td>{r.values.mean_numerator} / {r.values.mean_denominator}</td></tr>
          </tbody></table></div></> : <p>{r.state === 'suppressed' ? 'Statistics are suppressed; no numeric values are available.' : 'Statistics are undefined and stored as NULL for this stratum.'}</p>}
      </section>)}
      <aside className="interpretation"><h3>Generated scope only</h3><p>Concept selection and monthly tables inspect saved aggregates. Monthly numeric distributions, new windows, unit conversions and joint patient filters require additional computation. Row-level measurements and frequency tables are not exported.</p></aside>
    </>}
  </section>;
}
