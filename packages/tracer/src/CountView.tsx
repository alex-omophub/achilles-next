import {useId} from 'react';
import {MeasurementView} from './MeasurementView';
import {ObservationView} from './ObservationView';
import type {VerifiedCount} from './file-provider';

/** Pure reusable view: no router, authentication, file picker or global state. */
export function CountView({result}: {result: VerifiedCount}) {
  const {manifest, count, state} = result;
  const title = useId();
  return <article className={`count-view${result.measurement ? ' with-measurement' : ''}`} aria-labelledby={title}>
    <div className="count-heading"><div><h2 id={title}>All-source people</h2>
      <p>Distinct people in PERSON, before applying an observation window.</p></div>
      <span className="status">{state === 'empty_source' ? 'Empty source' : 'Computed'}</span></div>
    <p className="exact-count" aria-label={`Exact person count: ${count}`}>{count}</p>
    <p className="count-caption">Exact count · unique, non-null person IDs</p>
    {result.measurement ? <MeasurementView key={manifest.bundle_id} measurement={result.measurement} request={manifest.request}/> : null}
    {result.observation ? <ObservationView observation={result.observation} start={manifest.request.window.start} end={manifest.request.window.end}/> : null}
    <table><caption>Result identity</caption><tbody>
      <tr><th scope="row">Source</th><td>{manifest.source.source_id}</td></tr>
      <tr><th scope="row">Declared CDM</th><td>{manifest.source.declared_cdm_version ?? 'Unknown'}</td></tr>
      <tr><th scope="row">Metric</th><td>person.count · 1.0.0</td></tr>
      <tr><th scope="row">Profile</th><td>{manifest.profile.id} · {manifest.profile.revision}</td></tr>
      <tr><th scope="row">Run</th><td>{manifest.run_id}</td></tr>
    </tbody></table>
    <aside className="limitation"><h3>Partial development result</h3>
      <p>{result.measurement ? 'This measurement report implements 12 outputs. Capabilities, execution status and timing remain unsupported.' : result.observation ? 'This slice implements the passport, person count and three observation outputs. The other 10 outputs are explicitly unsupported.' : 'The passport and person count are implemented. The other 13 outputs are explicitly unsupported.'} This bundle cannot replace a complete alpha report.</p>
      <p>{manifest.reproducibility.limitation}</p>
      <p>Restricted synthetic output. No disclosure policy has been applied.</p>
    </aside>
    <details><summary>Request and integrity</summary><dl>
      <dt>Request window</dt><dd>{manifest.request.window.start} to {manifest.request.window.end}. This count uses all source people.</dd>
      <dt>Manifest SHA-256</dt><dd>{result.context.manifest_sha256}</dd>
      <dt>Bundle</dt><dd>{manifest.bundle_id}</dd>
    </dl></details>
  </article>;
}
