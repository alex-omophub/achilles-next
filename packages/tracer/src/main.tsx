import {useEffect, useRef, useState} from 'react';
import {createRoot} from 'react-dom/client';
import {CountView} from './CountView';
import {openCountBundle, selectedBundleFiles, type VerifiedCount} from './file-provider';
import './style.css';

function App() {
  const [result, setResult] = useState<VerifiedCount | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const current = useRef<AbortController | null>(null);
  useEffect(() => () => current.current?.abort(), []);
  async function select(files: FileList | null) {
    if (!files?.length) return;
    current.current?.abort();
    const controller = new AbortController();
    current.current = controller;
    setResult(null); setError(null); setBusy(true);
    try {
      const next = await openCountBundle(selectedBundleFiles(files), controller.signal);
      if (!controller.signal.aborted) setResult(next);
    } catch (failure) {
      if (!controller.signal.aborted) setError(failure instanceof Error ? failure.message : 'Unable to read this bundle.');
    } finally {if (!controller.signal.aborted) setBusy(false);}
  }
  return <main><header><a className="wordmark" href="#">Achilles<span>Next</span></a><span className="development">Count tracer · development</span></header>
    <section className="intro"><h1>Trace the count.<br/>Keep the context.</h1>
      <p>Open a generated synthetic bundle to inspect its exact PostgreSQL count and source identity.</p></section>
    <section className="selection" aria-labelledby="open-title"><div><h2 id="open-title">Open a count bundle</h2>
      <p>Select the folder containing manifest.json. Only declared aggregate files are read. Files stay in this browser.</p></div>
      <label className="file-button">Choose bundle folder<input type="file" multiple {...{webkitdirectory: ''}}
        aria-label="Choose bundle folder" onChange={event => {void select(event.currentTarget.files); event.currentTarget.value = '';}} /></label></section>
    <div aria-live="polite">{busy ? <p role="status">Checking bundle identity and file integrity…</p> : null}</div>
    {error ? <div className="error" role="alert"><h2>Bundle could not be opened</h2><p>{error}</p><p>Regenerate and validate the count bundle, then choose its folder again.</p></div> : null}
    {result ? <CountView result={result}/> : null}
    <footer>AchillesNext · Local synthetic tracer · Contract 1.0.0</footer>
  </main>;
}
createRoot(document.getElementById('root')!).render(<App/>);
