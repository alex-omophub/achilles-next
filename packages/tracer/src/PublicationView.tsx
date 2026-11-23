import {useEffect, useMemo, useRef, useState} from 'react';
import {assertSamePublication, PublicationReadError, readCatalogue, readPeople, readReport,
  type CatalogueMetric, type CataloguePage, type PopulationResult, type ReportPage} from './saved-publication';
import {SavedReportTable, stateLabel} from './SavedReportTable';
import {SavedReportChart} from './SavedReportChart';
import {SavedReportEvidence} from './SavedReportEvidence';
import './publication.css';

export interface PublicationProvider {
  people(signal: AbortSignal): Promise<PopulationResult>;
  catalogue(cursor: string | null, signal: AbortSignal): Promise<CataloguePage>;
  report(metricId: string, cursor: string | null, signal: AbortSignal): Promise<ReportPage>;
}

const domains: Record<string, string> = {
  person: 'Person', observation_period: 'Observation period', visit: 'Visit', condition: 'Condition',
  drug: 'Drug', procedure: 'Procedure', device: 'Device', measurement: 'Measurement',
  observation: 'Observation', death: 'Death', specimen: 'Specimen', density: 'Density',
  source: 'Source', execution: 'Execution',
};
const invalid = () => new PublicationReadError('The saved publication returned an invalid response.');
type Starts = (string | null)[];
interface Selection {
  domain: string;
  catalogueStarts: Starts;
  metric: CatalogueMetric | null;
  rowStarts: Starts;
}
const initial: Selection = {domain: 'all', catalogueStarts: [null], metric: null, rowStarts: [null]};
async function domainCatalogue(provider: PublicationProvider, context: PopulationResult['context'],
    domain: string, signal: AbortSignal): Promise<CataloguePage> {
  const metrics: CatalogueMetric[] = [];
  const ids = new Set<string>();
  const cursors = new Set<string>();
  let cursor: string | null = null;
  do {
    signal.throwIfAborted();
    const page = await provider.catalogue(cursor, signal);
    signal.throwIfAborted();
    assertSamePublication(context, page.context);
    for (const metric of page.metrics) {
      if (ids.has(metric.metric_id) || ids.size >= 142) throw invalid();
      ids.add(metric.metric_id);
      if (metric.metric_id.split('.')[1] === domain) metrics.push(metric);
    }
    cursor = page.cursor;
    if (cursor !== null) {
      if (!page.metrics.length || ids.size >= 142 || cursors.has(cursor)) throw invalid();
      cursors.add(cursor);
    }
  } while (cursor !== null);
  return {context, metrics, cursor: null};
}
function Summary({people}: {people: PopulationResult}) {
  const {context} = people;
  return <section className="publication-summary" aria-label="Publication summary">
    <div className="publication-count">
      <h2>People in source</h2>
      <p className={people.count === null ? 'population-state' : 'population-number'}>{people.count ?? stateLabel(people.state)}</p>
      {people.count !== null && <p className="population-caption">Distinct person IDs{people.state !== 'computed' && ` · ${stateLabel(people.state)}`}</p>}
      {people.reason && <p className="population-caption">{people.reason}</p>}
    </div>
    <dl className="publication-identities">
      <dt>Source</dt><dd>{context.source_id}</dd>
      <dt>Result release</dt><dd>{context.release_id}</dd>
      <dt>Access scope</dt><dd>{context.access_scope_id}</dd>
    </dl>
  </section>;
}
function Session({provider}: {provider: PublicationProvider}) {
  const [selection, setSelection] = useState<Selection>(initial);
  const [people, setPeople] = useState<PopulationResult | null>(null);
  const [result, setResult] = useState<{catalogue?: CataloguePage; report?: ReportPage} | null>(null);
  const [error, setError] = useState<string | null>(null);
  const pinned = useRef<PopulationResult | null>(null);
  const active = useRef<AbortController | null>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const restoreButton = useRef<string | null>(null);
  const selectedButton = useRef<HTMLButtonElement>(null);
  function open(next: Selection, returnTo: string | null = null) {
    active.current?.abort();
    restoreButton.current = returnTo;
    setResult(null);
    setSelection(next);
  }
  useEffect(() => {
    const controller = new AbortController();
    const {signal} = controller;
    active.current = controller;
    async function load() {
      let population = pinned.current;
      let catalogue: CataloguePage | undefined;
      let report: ReportPage | undefined;
      if (!population) {
        [population, catalogue] = await Promise.all([provider.people(signal), provider.catalogue(null, signal)]);
      } else if (selection.metric) {
        const metric = selection.metric;
        report = await provider.report(metric.metric_id, selection.rowStarts.at(-1) ?? null, signal);
        if (report.metric_id !== metric.metric_id || report.version !== metric.version
            || (report.cursor !== null && selection.rowStarts.includes(report.cursor))) throw invalid();
      } else if (selection.domain === 'all') {
        catalogue = await provider.catalogue(selection.catalogueStarts.at(-1) ?? null, signal);
      } else {
        catalogue = await domainCatalogue(provider, population.context, selection.domain, signal);
      }
      if (signal.aborted) return;
      if (catalogue) {
        assertSamePublication(population.context, catalogue.context);
        if (catalogue.cursor !== null && selection.catalogueStarts.includes(catalogue.cursor)) throw invalid();
      }
      if (report) assertSamePublication(population.context, report.context);
      pinned.current = population;
      setPeople(population);
      setResult({catalogue, report});
    }
    void load().catch(failure => {
      if (signal.aborted) return;
      controller.abort();
      pinned.current = null;
      setPeople(null);
      setResult(null);
      setError(failure instanceof PublicationReadError ? failure.message : 'The saved results could not be read.');
    });
    return () => controller.abort();
  }, [provider, selection]);
  useEffect(() => {
    if (!result || selection === initial) return;
    (selectedButton.current ?? heading.current)?.focus();
  }, [result, selection]);
  if (error) return <div className="publication-error" role="alert"><h2>Publication unavailable</h2><p>{error}</p></div>;
  if (!people) return <p role="status">Opening saved publication…</p>;
  const {metric, domain, catalogueStarts, rowStarts} = selection;
  const {catalogue, report} = result ?? {};
  const starts = metric ? rowStarts : catalogueStarts;
  const next = report?.cursor ?? catalogue?.cursor ?? null;
  function page(forward: boolean) {
    const history = forward ? [...starts, next] : starts.slice(0, -1);
    open(metric ? {...selection, rowStarts: history} : {...selection, catalogueStarts: history});
  }
  return <>
    <Summary people={people}/>
    <section className="publication-catalogue" aria-label="Metric catalogue">
      <div className="publication-heading">
        <label>Domain or section
          <select value={domain} onChange={event => open({...initial, domain: event.target.value})}>
            <option value="all">All domains and sections</option>
            {Object.entries(domains).map(([id, name]) => <option value={id} key={id}>{name}</option>)}
          </select>
        </label>
        {metric && <button type="button" className="publication-back" onClick={() => open({...selection, metric: null, rowStarts: [null]}, metric.metric_id)}>Back to catalogue</button>}
      </div>
      {!result ? <p role="status">{metric ? 'Loading saved rows…' : 'Loading catalogue…'}</p> : <>
        {catalogue && <>
          <div className="publication-heading"><h2 ref={heading} tabIndex={-1}>{domain === 'all' ? 'Metric catalogue' : domains[domain] + ' metrics'}</h2>
            <span role="status">{domain === 'all' ? `Page ${starts.length}` : `${catalogue.metrics.length} metrics`}</span></div>
          <table className="publication-metrics" aria-label={domain === 'all' ? `Saved metrics, page ${starts.length}` : domains[domain] + ' metrics'}>
            <thead><tr><th scope="col">Metric</th><th scope="col">State</th><th scope="col">Saved rows</th></tr></thead>
            <tbody>{catalogue.metrics.map(item => <tr key={item.metric_id}>
              <th scope="row"><button className="publication-metric" type="button"
                ref={restoreButton.current === item.metric_id ? selectedButton : undefined}
                onClick={() => open({...selection, metric: item, rowStarts: [null]})}>{item.metric_id}</button> <small>v{item.version}</small></th>
              <td>{stateLabel(item.state)}</td><td>{item.rows}</td>
            </tr>)}</tbody>
          </table>
          {!catalogue.metrics.length && <p>No catalogue entries in this selection.</p>}
        </>}
        {report && <>
          <div className="publication-heading"><h2 ref={heading} tabIndex={-1}>{report.metric_id}</h2><span role="status">Page {starts.length}</span></div>
          <dl className="publication-metadata">
            <div><dt>Metric version</dt><dd>{report.version}</dd></div>
            <div><dt>Population</dt><dd>{report.population}</dd></div>
            <div><dt>Grain</dt><dd>{report.grain}</dd></div>
            <div><dt>Row kind</dt><dd>{report.rowKind}</dd></div>
            <div><dt>Dataset state</dt><dd>{stateLabel(report.datasetState)}{report.datasetReason && <small>{report.datasetReason}</small>}</dd></div>
            <div><dt>Selection state</dt><dd>{stateLabel(report.state)}{report.reason && <small>{report.reason}</small>}</dd></div>
          </dl>
          <SavedReportChart report={report} page={starts.length}/>
          <SavedReportTable report={report}/>
          <SavedReportEvidence report={report}/>
        </>}
        {(metric || domain === 'all') && <nav aria-label={metric ? 'Saved row pages' : 'Catalogue pages'}>
          <button type="button" disabled={starts.length === 1} onClick={() => page(false)}>{metric ? 'Previous rows' : 'Previous page'}</button>
          <button type="button" disabled={next === null} onClick={() => page(true)}>{metric ? 'Next rows' : 'Next page'}</button>
        </nav>}
      </>}
    </section>
  </>;
}

export function PublicationWorkspace({provider, instanceKey}: {provider: PublicationProvider; instanceKey: string}) {
  // A replaced provider can carry different authority even if its display key is unchanged.
  const [binding, setBinding] = useState({provider, generation: 0});
  if (binding.provider !== provider) setBinding({provider, generation: binding.generation + 1});
  return <div className="publication-workspace"><Session key={JSON.stringify([instanceKey, binding.generation])} provider={provider}/></div>;
}

export function PublicationView({base}: {base: URL}) {
  const href = base.href;
  const provider = useMemo<PublicationProvider>(() => {
    const api = new URL(href);
    return {people: signal => readPeople(api, signal), catalogue: (cursor, signal) => readCatalogue(api, cursor, signal),
      report: (id, cursor, signal) => readReport(api, id, cursor, signal)};
  }, [href]);
  return <main className="publication-view">
    <header><span className="wordmark">Achilles<span>Next</span></span></header>
    <h1>Characterization results</h1>
    <PublicationWorkspace provider={provider} instanceKey={href}/>
  </main>;
}
