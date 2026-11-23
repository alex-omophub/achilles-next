import {useEffect, useRef, useState, type FormEvent} from 'react';
import type {PublicationProvider} from './PublicationView';
import {assertSamePublication, PublicationReadError, type ConceptPage, type ReportPage} from './saved-publication';

export function validConceptId(text: string) {
  return /^(?:0|-?[1-9][0-9]{0,511})$/.test(text);
}
export function SavedConceptFinder({provider, context, choose, fail}: {provider: PublicationProvider;
    context: ReportPage['context']; choose: (id: string) => void; fail: (error: unknown) => void}) {
  const [mode, setMode] = useState(provider.search ? 'name' : 'id');
  const [query, setQuery] = useState('');
  const [message, setMessage] = useState('');
  const [matches, setMatches] = useState<ConceptPage | null>(null);
  const [history, setHistory] = useState<(string | null)[]>([null]);
  const [busy, setBusy] = useState(false);
  const active = useRef<AbortController | null>(null);
  const status = useRef<HTMLParagraphElement>(null);
  const movedPage = useRef(false);
  useEffect(() => () => active.current?.abort(), []);
  useEffect(() => {
    if (matches && movedPage.current && document.activeElement === document.body) status.current?.focus();
  }, [matches]);
  function reset() {
    active.current?.abort();
    setMatches(null);
    setMessage('');
    setBusy(false);
    setHistory([null]);
  }
  async function find(starts: (string | null)[], movingPage = false) {
    reset();
    movedPage.current = movingPage;
    const text = query.trim();
    if (mode === 'id' ? !validConceptId(text) : !text || /[\u0000-\u001f\u007f-\u009f]/u.test(query) || new TextEncoder().encode(text).length > 256) {
      setMessage(mode === 'id' ? 'Enter an exact signed integer ID with up to 512 digits.' : 'Enter a name prefix of 1 to 256 UTF-8 bytes without control characters.');
      return;
    }
    const controller = new AbortController();
    active.current = controller;
    setBusy(true);
    try {
      const page = mode === 'id' ? await provider.lookup!(text, controller.signal)
        : await provider.search!(text, starts.at(-1) ?? null, controller.signal);
      if (controller.signal.aborted) return;
      assertSamePublication(context, page.context);
      if (page.cursor !== null && starts.includes(page.cursor))
        throw new PublicationReadError('The saved publication returned an invalid response.');
      setMatches(page);
      setHistory(starts);
    } catch (error) {
      if (!controller.signal.aborted) fail(error);
    } finally {
      if (!controller.signal.aborted) setBusy(false);
    }
  }
  function submit(event: FormEvent) { event.preventDefault(); void find([null]); }
  return <fieldset className="publication-finder">
    <legend>Find a saved concept</legend>
    <form onSubmit={submit} className="publication-filter-fields">
      <label>Find by<select value={mode} onChange={e => {reset(); setMode(e.target.value); setQuery('');}}>
        {provider.search && <option value="name">Saved name prefix</option>}
        {provider.lookup && <option value="id">Exact concept ID</option>}
      </select></label>
      <label>{mode === 'name' ? 'Name prefix' : 'Exact concept ID'}<input value={query}
        onChange={e => {reset(); setQuery(e.target.value);}} maxLength={mode === 'id' ? 513 : 256}/></label>
      <button type="submit">{mode === 'name' ? 'Search saved names' : 'Look up ID'}</button>
    </form>
    {message && <p role="alert">{message}</p>}
    {busy && <p role="status">Reading saved concepts…</p>}
    {matches && <>
      <p ref={status} tabIndex={-1} role="status">{matches.state !== 'available' ? 'Saved names unavailable' :
        (mode === 'id' ? 'Exact ID lookup' : `${matches.concepts.length} matches on page ${history.length}`)}
        {matches.reason && <> · <span>{matches.reason}</span></>}</p>
      {!!matches.concepts.length && <ul>{matches.concepts.map(item => <li key={item.id}>
        <div><strong>{item.label ?? 'Name unavailable'}</strong> <span>ID {item.id}</span>
          {item.reason && <small>{item.reason}</small>}</div>
        {item.state === 'available' && <button type="button" onClick={() => choose(item.id)}>Use ID {item.id}</button>}
      </li>)}</ul>}
      {mode === 'name' && (history.length > 1 || matches.cursor !== null) && <nav aria-label="Concept match pages">
        <button type="button" disabled={history.length === 1} onClick={() => void find(history.slice(0, -1), true)}>Previous matches</button>
        <button type="button" disabled={matches.cursor === null} onClick={() => void find([...history, matches.cursor], true)}>Next matches</button>
      </nav>}
    </>}
  </fieldset>;
}
