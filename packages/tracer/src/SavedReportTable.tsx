import {useState} from 'react';
import type {PublicationConceptEvent} from './mount-publication';
import type {ReportFields, ReportPage, ReportValue} from './saved-publication';

export function stateLabel(state: string) {
  const text = state.replaceAll('_', ' ');
  return text.charAt(0).toUpperCase() + text.slice(1);
}
function Field({value}: {value: ReportValue | undefined}) {
  if (value === undefined) return <span className="publication-muted">Not present</span>;
  if (value === null) return <span className="publication-muted">Null</span>;
  if (typeof value !== 'object') return <>{value === '' ? 'Empty string' : String(value)}</>;
  if ('kind' in value && typeof value.kind === 'string') {
    const keys = Object.keys(value);
    if (keys.length === 1) return <>{stateLabel(value.kind)}</>;
    if (keys.length === 2 && 'value' in value && typeof value.value === 'string')
      return <><span>{value.value}</span><small className="publication-field-kind">{value.kind}</small></>;
  }
  return <details><summary>View fields</summary><pre>{JSON.stringify(value, null, 2)}</pre></details>;
}
function valueOf(fields: ReportFields | null, key: string) {
  return fields && Object.hasOwn(fields, key) ? fields[key] : undefined;
}

export type ConceptAction = (type: PublicationConceptEvent['type'], payload: PublicationConceptEvent['payload'], correlationId: string) => void;

function savedConceptId(field: string, value: ReportValue | undefined) {
  const scalar = field.endsWith('_concept_id');
  const tagged = field === 'concept_tag' || field.endsWith('_concept_tag') || field === 'raw_operator_tag';
  const id = scalar ? value : tagged && value && typeof value === 'object' && 'kind' in value && value.kind === 'id'
    && 'value' in value ? value.value : undefined;
  return typeof id === 'string' && /^[1-9]\d*$/.test(id) ? id : null;
}

export function SavedReportTable({report, onConcept}: {report: ReportPage; onConcept?: ConceptAction}) {
  const [selected, setSelected] = useState<{field: string; id: string; correlation: string; rowKey: string} | null>(null);
  function emit(type: PublicationConceptEvent['type'], field: string, id: string, correlation: string) {
    onConcept?.(type, {target: 'concept', concept_id: id, dimension: field,
      metric_id: report.metric_id, metric_version: report.version}, correlation);
  }
  const {rows} = report;
  if (!rows.length) return <p className="publication-empty">No saved rows in this selection.</p>;
  const dimensions = [...new Set(rows.flatMap(row => Object.keys(row.dimensions)))];
  const measures = [...new Set(rows.flatMap(row => Object.keys(row.values ?? {})))];
  return <div className="publication-scroll" role="region" tabIndex={0} aria-label="Scrollable saved rows">
    <table aria-label={'Saved rows for ' + report.metric_id}>
      <thead><tr><th scope="col">Row state</th>
        {dimensions.map(field => <th scope="col" key={field}><small>Dimension</small>{field}</th>)}
        {measures.map(field => <th scope="col" key={field}><small>Value</small>{field}</th>)}
      </tr></thead>
      <tbody>{rows.map(row => <tr key={row.row_key}>
        <th scope="row">{stateLabel(row.state)}{row.reason_code && <small>{row.reason_code}</small>}</th>
        {dimensions.map(field => {
          const value = valueOf(row.dimensions, field);
          const id = onConcept && row.values !== null ? savedConceptId(field, value) : null;
          return <td key={field}>{id ? <button type="button" className="publication-metric"
            aria-label={'Select concept ' + id + ' from ' + field}
            aria-pressed={selected?.rowKey === row.row_key && selected.field === field}
            onClick={() => {
              const correlation = crypto.randomUUID();
              setSelected({field, id, correlation, rowKey: row.row_key});
              emit('concept_selected', field, id, correlation);
            }}><Field value={value}/></button> : <Field value={value}/>}</td>;
        })}
        {measures.map(field => <td key={field}>{row.values === null ? stateLabel(row.state)
          : <Field value={valueOf(row.values, field)}/>}</td>)}
      </tr>)}</tbody>
    </table>
    {onConcept && selected && <button type="button" onClick={() =>
      emit('navigation_requested', selected.field, selected.id, selected.correlation)}>Open concept {selected.id} in host</button>}
  </div>;
}
