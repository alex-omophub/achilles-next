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

export function SavedReportTable({report}: {report: ReportPage}) {
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
        {dimensions.map(field => <td key={field}><Field value={valueOf(row.dimensions, field)}/></td>)}
        {measures.map(field => <td key={field}>{row.values === null ? stateLabel(row.state)
          : <Field value={valueOf(row.values, field)}/>}</td>)}
      </tr>)}</tbody>
    </table>
  </div>;
}
