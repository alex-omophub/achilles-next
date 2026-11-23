import {renderToStaticMarkup} from 'react-dom/server';
import {expect, it} from 'vitest';
import {SavedReportEvidence} from '../src/SavedReportEvidence';
import type {ReportPage, ReportRow} from '../src/saved-publication';

it('matches eligibility to the exact saved concept, unit, operator and metric version', () => {
  const metric = 'core.measurement.numeric_summary';
  const row = (concept: string, unit: string, operator: 'null' | '0', n: string): ReportRow => ({
    row_key: ['summary', concept, unit, operator].join('-'), row_kind: 'summary', state: 'computed', reason_code: null, values: {n},
    dimensions: {concept_tag: {kind: 'id', value: concept}, unit_concept_tag: {kind: 'id', value: unit},
      raw_operator_tag: operator === 'null' ? {kind: 'null'} : {kind: 'id', value: operator}},
  });
  const eligible = (row: ReportRow, count: string, version = '1.0.0') => ({
    metric_id: metric, metric_version: version, row: {...row, row_kind: 'eligibility_counts', row_key: 'eligible-' + row.row_key,
      dimensions: {...row.dimensions, eligibility_reason: 'eligible'}, values: {record_count: count}},
  });
  const unit = '9007199254740993';
  const matched = row('123', unit, 'null', '6');
  const zero = row('123', '777', '0', '0');
  const wrongVersion = row('123', '456', 'null', '9');
  // Each near-match shares the eligible count; only the mismatching dimension can exclude it.
  const rows = [matched, zero, wrongVersion, row('124', unit, 'null', '6'),
    row('123', unit, '0', '6'), row('123', '888', 'null', '6')];
  const report: ReportPage = {
    context: {contract_version: '2.0.0', source_id: 'source', release_id: 'release', publication_id: 'publication',
      access_scope_id: 'scope', profile_id: 'profile', profile_revision: '1', profile_sha256: 'a'.repeat(64),
      authorization_epoch: '1', instance_id: 'viewer'},
    metric_id: metric, version: '1.0.0', grain: 'concept/unit/operator', population: 'all_recorded_rows',
    state: 'available', reason: null, datasetState: 'computed', datasetReason: null, rowKind: 'summary', rows, cursor: null,
    evidence: {definitionSha256: 'a'.repeat(64),
      dependencies: [eligible(zero, '0'), eligible(matched, '6'), eligible(wrongVersion, '9', '2.0.0')]},
  };
  const html = renderToStaticMarkup(<SavedReportEvidence report={report}/>);
  expect(html).toContain('Unit concept 9007199254740993 · Operator NULL');
  expect(html).toContain('Unit concept 777 · Operator concept 0');
  const displayed = Array.from(html.matchAll(/<dt>Eligible records<\/dt><dd>([^<]+)<\/dd>/g), match => match[1]);
  expect(displayed).toEqual(['6', '0', 'Unavailable on this page', 'Unavailable on this page',
    'Unavailable on this page', 'Unavailable on this page']);
});
