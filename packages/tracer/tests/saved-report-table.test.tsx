import {renderToStaticMarkup} from 'react-dom/server';
import {expect, it} from 'vitest';
import {SavedReportTable} from '../src/SavedReportTable';
import type {ReportPage} from '../src/saved-publication';

it('keeps exact strings, typed tags, structured metadata, null and omitted fields distinct', () => {
  const exact = '9007199254740993';
  const report: ReportPage = {
    context: {contract_version: '2.0.0', source_id: 'source', release_id: 'release',
      publication_id: 'publication', access_scope_id: 'scope', profile_id: 'profile',
      profile_revision: '1', profile_sha256: 'a'.repeat(64), authorization_epoch: '1', instance_id: 'viewer'},
    metric_id: 'core.source.passport', version: '1.0.0', grain: 'source', population: 'source',
    state: 'available', reason: null, datasetState: 'computed', datasetReason: null, rowKind: 'metadata', cursor: null,
    rows: [
      {row_key: 'a', row_kind: 'metadata', state: 'computed', reason_code: null,
        dimensions: {concept_tag: {kind: 'id', value: exact}},
        values: {coverage: {complete: true, audit: ['<review>', null]}, recorded: null, count: '0'}},
      {row_key: 'b', row_kind: 'metadata', state: 'computed', reason_code: null,
        dimensions: {concept_tag: {kind: 'schema_absent'}}, values: {count: exact}},
      {row_key: 'c', row_kind: 'metadata', state: 'unavailable', reason_code: 'fixture.unavailable',
        dimensions: {}, values: null},
    ],
  };
  const html = renderToStaticMarkup(<SavedReportTable report={report}/>);
  const rows = html.split('<tbody>')[1].split('</tbody>')[0].match(/<tr>.*?<\/tr>/gs)!;
  expect(rows).toHaveLength(3);
  expect(rows[0]).toContain('<span>' + exact + '</span>');
  expect(rows[0]).toContain('<details><summary>View fields</summary>');
  expect(rows[0]).toContain('&lt;review&gt;');
  expect(rows[0]).toContain('>Null<');
  expect(rows[0]).toContain('<td>0</td>');
  expect(rows[1]).toContain('Schema absent');
  expect(rows[1]).toContain('>Not present<');
  expect(rows[1]).toContain('<td>' + exact + '</td>');
  expect(rows[2]).toContain('fixture.unavailable');
  expect(rows[2]).toContain('<td>Unavailable</td>');
  expect(rows[2]).not.toContain('<td>0</td>');
});
