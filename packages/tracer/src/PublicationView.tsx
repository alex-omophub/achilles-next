import {useEffect, useRef, useState} from 'react';
import {assertSamePublication, PublicationReadError, readCatalogue, readPeople,
  type CataloguePage, type PopulationResult} from './saved-publication';
import './publication.css';

function label(state: string) {
  const text = state.replaceAll('_', ' ');
  return text.charAt(0).toUpperCase() + text.slice(1);
}
interface ReportProps {
  people: PopulationResult;
  catalogue: CataloguePage;
  page: number;
  busy: boolean;
  previous: () => void;
  next: () => void;
}
export function PublicationReport({people, catalogue, page, busy, previous, next}: ReportProps) {
  const {context} = catalogue;
  const heading = useRef<HTMLHeadingElement>(null);
  const displayed = useRef(page);
  useEffect(() => {
    if (displayed.current !== page) heading.current?.focus();
    displayed.current = page;
  }, [page]);
  return <>
    <section className="publication-summary" aria-label="Publication summary">
      <div className="publication-count">
        <h2>People in source</h2>
        <p className={people.count === null ? 'population-state' : 'population-number'}>{people.count ?? label(people.state)}</p>
        {people.count !== null && <p className="population-caption">Distinct person IDs{people.state !== 'computed' && ` · ${label(people.state)}`}</p>}
        {people.reason && <p className="population-caption">{people.reason}</p>}
      </div>
      <dl className="publication-identities">
        <dt>Source</dt><dd>{context.source_id}</dd>
        <dt>Result release</dt><dd>{context.release_id}</dd>
        <dt>Access scope</dt><dd>{context.access_scope_id}</dd>
      </dl>
    </section>
    <section className="publication-catalogue" aria-busy={busy} aria-label="Metric catalogue">
      <div className="publication-heading">
        <h2 ref={heading} tabIndex={-1}>Metric catalogue</h2>
        <span role="status">{busy ? 'Loading page…' : `Page ${page}`}</span>
      </div>
      <table aria-label={`Saved metrics, page ${page}`}>
        <thead><tr><th scope="col">Metric</th><th scope="col">State</th><th scope="col">Saved rows</th></tr></thead>
        <tbody>{catalogue.metrics.map(metric => <tr key={metric.metric_id}>
          <th scope="row">{metric.metric_id} <small>v{metric.version}</small></th>
          <td>{label(metric.state)}</td><td>{metric.rows}</td>
        </tr>)}</tbody>
      </table>
      {!catalogue.metrics.length && <p>No catalogue entries in this publication.</p>}
      <nav aria-label="Catalogue pages">
        <button type="button" disabled={busy || page === 1} onClick={previous}>Previous page</button>
        <button type="button" disabled={busy || catalogue.cursor === null} onClick={next}>Next page</button>
      </nav>
    </section>
  </>;
}
interface Loaded {
  people: PopulationResult;
  catalogue: CataloguePage;
  // Keep only page start cursors. Previous pages are reauthorized on each read.
  history: (string | null)[];
}
function Session({base}: {base: URL}) {
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(true);
  const active = useRef<AbortController | null>(null);
  function failed(failure: unknown) {
    setLoaded(null);
    setError(failure instanceof PublicationReadError ? failure.message
      : 'The saved results could not be read. Reopen the publication from R.');
  }
  const href = base.href;
  useEffect(() => {
    const controller = new AbortController();
    active.current = controller;
    const from = new URL(href);
    void Promise.all([readPeople(from, controller.signal), readCatalogue(from, null, controller.signal)])
      .then(([people, catalogue]) => {
        if (controller.signal.aborted) return;
        assertSamePublication(people.context, catalogue.context);
        setLoaded({people, catalogue, history: [null]});
      })
      .catch(failure => {if (!controller.signal.aborted) failed(failure);})
      .finally(() => {if (!controller.signal.aborted) setBusy(false);});
    return () => active.current?.abort();
  }, [href]);
  async function navigate(forward: boolean) {
    if (!loaded || busy || (forward ? !loaded.catalogue.cursor : loaded.history.length === 1)) return;
    const history = forward ? [...loaded.history, loaded.catalogue.cursor] : loaded.history.slice(0, -1);
    active.current?.abort();
    const controller = new AbortController();
    active.current = controller;
    setBusy(true);
    try {
      const catalogue = await readCatalogue(base, history[history.length - 1], controller.signal);
      if (controller.signal.aborted) return;
      assertSamePublication(loaded.people.context, catalogue.context);
      setLoaded({...loaded, catalogue, history});
    } catch (failure) {
      if (!controller.signal.aborted) failed(failure);
    } finally {
      if (!controller.signal.aborted) setBusy(false);
    }
  }
  return <main className="publication-view">
    <header><span className="wordmark">Achilles<span>Next</span></span></header>
    <h1>Characterization results</h1>
    {error ? <section className="error" role="alert"><h2>Publication unavailable</h2><p>{error}</p></section>
      : loaded ? <PublicationReport people={loaded.people} catalogue={loaded.catalogue} page={loaded.history.length}
          busy={busy} previous={() => void navigate(false)} next={() => void navigate(true)}/>
      : <p role="status">Opening saved publication…</p>}
  </main>;
}
export function PublicationView({base}: {base: URL}) {
  return <Session key={base.href} base={base}/>;
}
