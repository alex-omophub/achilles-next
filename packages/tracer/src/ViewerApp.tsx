import {useEffect, useRef, useState} from 'react';
import {CountView} from './CountView';
import {BundleOpenError, openCountBundle, openServedCountBundle, selectedBundleFiles,
  type OpenErrorState, type VerifiedCount} from './file-provider';

const errorText = {
  missing: ['Results not found', 'Check that the folder contains manifest.json and all declared files, then reopen the viewer.'],
  invalid: ['Invalid results', 'Regenerate or restore an unchanged bundle, then reopen the viewer.'],
  incompatible: ['Unsupported results version', 'Use a compatible count-tracer, observation-tracer or measurement reference bundle, or update AchillesNext.'],
  unavailable: ['Local viewer unavailable', 'Keep the R viewer process running, then reopen the viewer.'],
};
export function ResultError({state, message}: {state: OpenErrorState; message: string}) {
  return <section className="error" role="alert" data-state={state}>
    <h2>{errorText[state][0]}</h2><p>{message}</p><p>{errorText[state][1]}</p>
  </section>;
}
export function ViewerApp({servedBase}: {servedBase?: URL}) {
  const [result, setResult] = useState<VerifiedCount | null>(null);
  const [error, setError] = useState<{state: OpenErrorState; message: string} | null>(null);
  const [busy, setBusy] = useState(false);
  const current = useRef<AbortController | null>(null);
  const baseHref = servedBase?.href;
  function report(failure: unknown) {
    setError(failure instanceof BundleOpenError ? {state: failure.state, message: failure.message} : {state: 'invalid',
      message: failure instanceof Error ? failure.message : 'Unable to read this bundle.'});
  }
  useEffect(() => {
    if (!baseHref) return;
    const controller = new AbortController(); current.current = controller;
    setResult(null); setError(null); setBusy(true);
    void openServedCountBundle(new URL(baseHref), controller.signal).then(next => {
      if (!controller.signal.aborted) setResult(next);
    }).catch(failure => {if (!controller.signal.aborted) report(failure);})
      .finally(() => {if (!controller.signal.aborted) setBusy(false);});
    return () => controller.abort();
  }, [baseHref]);
  useEffect(() => () => current.current?.abort(), []);
  async function select(files: FileList | null) {
    if (!files?.length) return;
    current.current?.abort();
    const controller = new AbortController(); current.current = controller;
    setResult(null); setError(null); setBusy(true);
    try {
      const next = await openCountBundle(selectedBundleFiles(files), controller.signal);
      if (!controller.signal.aborted) setResult(next);
    } catch (failure) {if (!controller.signal.aborted) report(failure);}
    finally {if (!controller.signal.aborted) setBusy(false);}
  }
  return <main><header><a className="wordmark" href="#">Achilles<span>Next</span></a><span className="development">Local results · development</span></header>
    <section className="intro"><h1>Explore the data.<br/>Keep the context.</h1>
      <p>Inspect measurement representations, exact distributions and observation opportunity.</p></section>
    {servedBase ? <section className="selection"><div><h2>Selected results</h2>
      <p>Opening the bundle selected in R. Results stay on this computer.</p></div></section> :
      <section className="selection" aria-labelledby="open-title"><div><h2 id="open-title">Open a result bundle</h2>
        <p>Select the folder containing manifest.json. Only declared aggregate files are read. Files stay in this browser.</p></div>
        <label className="file-button">Choose bundle folder<input type="file" multiple {...{webkitdirectory: ''}}
          aria-label="Choose bundle folder" onChange={event => {void select(event.currentTarget.files); event.currentTarget.value = '';}} /></label></section>}
    <div aria-live="polite">{busy ? <p role="status">Checking result identity and file integrity…</p> : null}</div>
    {error ? <ResultError {...error}/> : null}
    {result ? <CountView result={result}/> : null}
    <footer>AchillesNext · Synthetic development tracer · Contract 1.0.0</footer>
  </main>;
}
