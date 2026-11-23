import {canonical} from '../../contracts/src/index.mjs';
import type {ReportPage, ReportRow, ReportValue} from './saved-publication';

function tag(value: ReportValue | undefined) {
  if (!value || typeof value !== 'object' || !('kind' in value)) return null;
  if (value.kind === 'id' && typeof value.value === 'string') return 'concept ' + value.value;
  if (value.kind === 'null') return 'NULL';
  if (value.kind === 'all') return 'all';
  if (value.kind === 'schema_absent') return 'absent from schema';
  return null;
}

export function SavedReportEvidence({report}: {report: ReportPage}) {
  if (!report.evidence) return null;
  const measurement = report.metric_id.startsWith('core.measurement.') && report.rowKind === 'summary';
  const eligibleByDimensions = new Map<string, ReportRow>();
  if (measurement) {
    for (const dep of report.evidence.dependencies) {
      if (dep.metric_id !== report.metric_id || dep.metric_version !== report.version || dep.row.row_kind !== 'eligibility_counts') continue;
      const {eligibility_reason, ...dimensions} = dep.row.dimensions;
      if (eligibility_reason === 'eligible') eligibleByDimensions.set(canonical(dimensions), dep.row);
    }
  }
  return <details className="publication-evidence">
    <summary>Report evidence</summary>
    <dl className="publication-metadata">
      <div><dt>Definition SHA-256</dt><dd><code>{report.evidence.definitionSha256}</code></dd></div>
      {['counts', 'summary', 'eligibility_counts'].includes(report.rowKind) && <div><dt>Table precision</dt>
        <dd>Exact published numeric strings</dd></div>}
    </dl>
    {measurement && <p>{eligibleByDimensions.size ? 'Other eligibility reasons are unavailable on this page.'
      : 'Eligibility counts are unavailable on this page.'}</p>}
    {report.rows.map((row, index) => {
      const refs = row.denominator_refs ?? [];
      if (!refs.length && (!measurement || row.values === null)) return null;
      const unit = tag(row.dimensions.unit_concept_tag);
      const operator = tag(row.dimensions.raw_operator_tag);
      const eligible = measurement ? eligibleByDimensions.get(canonical(row.dimensions)) : undefined;
      const count = eligible?.values?.record_count;
      return <div key={row.row_key}>
        <h3>Row {index + 1}{unit && ' · Unit ' + unit}{operator && ' · Operator ' + operator}</h3>
        <dl className="publication-metadata">
          {measurement && <div><dt>Eligible records</dt>
            <dd>{typeof count === 'string' && count === row.values?.n ? count : 'Unavailable on this page'}</dd></div>}
          {refs.map(ref => <div key={[ref.measure, ref.metric_id, ref.row_key, ref.field].join('|')}>
            <dt>Denominator for {ref.measure.replaceAll('_', ' ')}</dt>
            <dd>{ref.value} <small>{ref.metric_id} · {ref.field}</small></dd>
          </div>)}
        </dl>
      </div>;
    })}
  </details>;
}
