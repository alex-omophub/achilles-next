import {useLayoutEffect, useRef, useState} from 'react';
import type {PublicationProvider} from './PublicationView';
import {pageEvidenceJson, type ReportPage, type SavedFilters} from './saved-publication';

interface Props {
  readEvidence: NonNullable<PublicationProvider['exportEvidence']>;
  report: ReportPage;
  filters: SavedFilters;
  cursor: string | null;
  page: number;
  view: AbortSignal;
  fail: (failure: unknown) => void;
}
export function SavedEvidenceDownload({readEvidence, report, filters, cursor, page, view, fail}: Props) {
  const [status, setStatus] = useState<'idle' | 'reading' | 'ready'>('idle');
  const pending = useRef<AbortController | null>(null);
  // A host rebind must cancel the download during the unmount commit.
  useLayoutEffect(() => () => pending.current?.abort(), []);
  async function download() {
    if (pending.current || view.aborted) return;
    const controller = new AbortController();
    pending.current = controller;
    const abort = () => controller.abort();
    view.addEventListener('abort', abort, {once: true});
    setStatus('reading');
    try {
      const raw = await readEvidence(report.metric_id, filters, cursor, controller.signal);
      controller.signal.throwIfAborted();
      const json = await pageEvidenceJson(raw, report, filters, page);
      controller.signal.throwIfAborted();
      const url = URL.createObjectURL(new Blob([json], {type: 'application/json'}));
      try {
        const link = document.createElement('a');
        link.href = url;
        link.download = `achillesnext-${report.metric_id}-page-${page}.json`;
        link.click();
      } finally {
        setTimeout(() => URL.revokeObjectURL(url), 0);
      }
      setStatus('ready');
    } catch (error) {
      if (!controller.signal.aborted) fail(error);
    } finally {
      view.removeEventListener('abort', abort);
      pending.current = null;
    }
  }
  return <div className="publication-download">
    <button type="button" disabled={status === 'reading'} onClick={() => void download()}>Download page evidence (JSON)</button>
    {status !== 'idle' && <span role="status">{status === 'reading' ? 'Verifying selected page…' : 'Download started.'}</span>}
  </div>;
}
