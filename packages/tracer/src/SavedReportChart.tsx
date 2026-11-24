import {Component, lazy, Suspense, useState, type ReactNode} from 'react';
import {chartPoints, chartSpec} from './saved-chart';
import type {ReportPage} from './saved-publication';

const Graphic = lazy(() => import('./SavedChartGraphic'));
class GraphicBoundary extends Component<{children: ReactNode}, {failed: boolean}> {
  state = {failed: false};
  static getDerivedStateFromError() { return {failed: true}; }
  render() { return this.state.failed ? <p>The chart could not be displayed. See the saved rows below.</p> : this.props.children; }
}
export function SavedReportChart({report, page, locale, showFallback = false}: {locale?: string; report: ReportPage; page: number; showFallback?: boolean}) {
  const [groupId, setGroupId] = useState('');
  const [measure, setMeasure] = useState<'person_count' | 'record_count'>('record_count');
  const spec = chartSpec(report);
  if (!spec) return showFallback ? <p>A chart is unavailable for this report. Open the exact saved rows below.</p> : null;
  const group = spec.groups.find(item => item.id === groupId) ?? spec.groups[0];
  const points = group ? chartPoints(spec.kind, group, measure) : [];
  const omitted = points.filter(item => item.position === null).length;
  const quantiles = spec.kind === 'quantiles';
  const valueLabel = quantiles ? 'Measurement value' : spec.kind === 'birth' || measure === 'person_count' ? 'Distinct people' : 'Records';
  const eligible = quantiles ? group?.rows[0].values?.n : undefined;
  return <section className="publication-chart" aria-label="Saved chart">
    <h3>{spec.title}</h3>
    <p className="publication-chart-page">Saved rows on page {page}{typeof eligible === 'string' && ` · Eligible values: ${eligible}`}</p>
    {group && spec.kind !== 'birth' && <div className="publication-chart-controls">
      <label>{quantiles ? 'Measurement stratum' : 'Concept and period'}
        <select value={group.id} onChange={event => setGroupId(event.target.value)}>
          {spec.groups.map(item => <option key={item.id} value={item.id}>{item.label}</option>)}
        </select>
      </label>
      {!quantiles && <label>Measure<select value={measure} onChange={event => setMeasure(event.target.value === 'person_count' ? 'person_count' : 'record_count')}>
        <option value="record_count">Records</option><option value="person_count">Distinct people</option>
      </select></label>}
    </div>}
    {points.length > omitted ? <>
      <figure aria-label={spec.title + ' · ' + valueLabel}>
        <figcaption>{valueLabel}</figcaption>
        <GraphicBoundary key={JSON.stringify([report.context.instance_id, report.metric_id, page, group?.id, measure])}><Suspense fallback={<p role="status">Loading chart…</p>}>
          <Graphic locale={locale} points={points} quantiles={quantiles} measure={valueLabel}/>
        </Suspense></GraphicBoundary>
      </figure>
      {omitted > 0 && <p>{omitted} {omitted === 1 ? 'point has' : 'points have'} a missing or unplottable value. See the saved rows below.</p>}
    </> : <p>No plottable values in this selection. See the saved state and exact rows below.</p>}
  </section>;
}
