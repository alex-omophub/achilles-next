import {renderToStaticMarkup} from 'react-dom/server';
import {expect, it} from 'vitest';
import {SavedReportEvidence} from '../src/SavedReportEvidence';
import type {ReportPage, ReportRow} from '../src/saved-publication';

it('matches eligibility to the exact saved concept, unit, operator and metric version', () => {
  const metric = 'core.measurement.numeric_summary';
  const row = (id: string, n: string): ReportRow => ({
    row_key: 'summary-' + id, row_kind: 'summary', state: 'computed', reason_code: null, values: {n},
    dimensions: {unit_concept_tag: {kind: 'id', value: id}, raw_operator_tag: {kind: 'null'}},
  });
  const eligible = (row: ReportRow, count: string, version = '1.0.0') => ({
    metric_id: metric, metric_version: version, row: {...row, row_kind: 'eligibility_counts',
      dimensions: {...row.dimensions, eligibility_reason: 'eligible'}, values: {record_count: count}},
  });
  const rows = [row('9007199254740993', '6'), row('777', '0'), row('456', '9')];
  const report: ReportPage = {
    context: {contract_version: '2.0.0', source_id: 'source', release_id: 'release', publication_id: 'publication',
      access_scope_id: 'scope', profile_id: 'profile', profile_revision: '1', profile_sha256: 'a'.repeat(64),
      authorization_epoch: '1', instance_id: 'viewer'},
    metric_id: metric, version: '1.0.0', grain: 'concept/unit/operator', population: 'all_recorded_rows',
    state: 'available', reason: null, datasetState: 'computed', datasetReason: null, rowKind: 'summary', rows, cursor: null,
    evidence: {definitionSha256: 'a'.repeat(64),
      dependencies: [eligible(rows[1], '0'), eligible(rows[0], '6'), eligible(rows[2], '9', '2.0.0')]},
  };
  const html = renderToStaticMarkup(<SavedReportEvidence report={report}/>);
  expect(html).toContain('Unit concept 9007199254740993 · Operator NULL');
  expect(html).toMatch(/<dt>Eligible records<\/dt><dd>6<\/dd>/);
  expect(html).toMatch(/<dt>Eligible records<\/dt><dd>0<\/dd>/);
  expect(html).toContain('Unavailable on this page');
  expect(html).not.toContain('>9<');
});
