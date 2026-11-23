import {describe, expect, it} from 'vitest';
import {chartPoints, chartSpec} from '../src/saved-chart';
import type {ReportFields} from '../src/saved-publication';

const row = (row_key: string, dimensions: ReportFields, values: ReportFields | null, state = 'computed') =>
  ({row_key, dimensions, values, state});
const page = (metric_id: string, rows: ReturnType<typeof row>[], rowKind = 'counts') =>
  ({metric_id, rows, rowKind, version: '1.0.0'});

describe('charts projected from a saved report page', () => {
  it('keeps distinct recorded years, raw zero, missing years and unplottable exact counts', () => {
    const report = page('core.person.birth_year_count', [
      row('a', {year_of_birth: '0'}, {person_count: '1'}),
      row('b', {year_of_birth: 'null'}, {person_count: '2'}),
      row('c', {year_of_birth: '1980'}, {person_count: '9007199254740993'}),
      row('d', {year_of_birth: '1970'}, null, 'suppressed'),
    ]);
    const spec = chartSpec(report)!;
    const points = chartPoints(spec.kind, spec.groups[0], 'person_count');
    expect(points.map(p => [p.label, p.exact, p.position])).toEqual([
      ['0', '1', 1], ['1970', null, null], ['1980', '9007199254740993', null], ['Not recorded', '2', 2],
    ]);
  });

  it('keeps typed concepts and period kinds separate and uses only saved intervals and the selected measure', () => {
    const capture = (concept: ReportFields, period: string, start: string, end: string, records = '10') =>
      row(JSON.stringify([concept, period, start]), {concept_tag: concept, period_kind: period, period_start: start, period_end: end},
        {record_count: records, person_count: '3'});
    const id = {kind: 'id', value: '0'};
    const report = page('core.measurement.capture_count', [
      capture({kind: 'all'}, 'calendar_month', '2020-01-01', '2020-01-31'),
      capture(id, 'full_scope', 'null', 'null', '20'), capture(id, 'calendar_year', '2020-01-01', '2020-12-31', '20'),
      capture(id, 'calendar_month', '2020-03-01', '2020-03-31'), capture(id, 'calendar_month', '2020-01-01', '2020-01-31'),
      capture({kind: 'null'}, 'undated', 'undated', 'undated'),
    ]);
    const spec = chartSpec(report)!;
    expect(spec.groups).toHaveLength(5);
    const month = spec.groups.find(g => g.label === 'Concept ID 0 · Calendar month')!;
    expect(chartPoints(spec.kind, month, 'person_count')).toEqual([
      {label: '2020-01', detail: '2020-01-01 – 2020-01-31', exact: '3', position: 3},
      {label: '2020-03', detail: '2020-03-01 – 2020-03-31', exact: '3', position: 3},
    ]);
    expect(chartPoints(spec.kind, month, 'record_count').map(p => p.exact)).toEqual(['10', '10']);
  });

  it('keeps observed dated counts and an explicitly empty core source as separate projections', () => {
    const all = {kind: 'all'};
    const observed = chartSpec(page('observed.measurement.capture_count', [
      row('jan', {concept_tag: all, period_kind: 'calendar_month', period_start: '2020-01-01', period_end: '2020-01-31'},
        {person_count: '2', record_count: '5'}),
    ]))!;
    expect(chartPoints(observed.kind, observed.groups[0], 'person_count')[0]).toMatchObject({label: '2020-01', exact: '2', position: 2});
    const empty = chartSpec(page('core.specimen.capture_count', [
      row('full', {concept_tag: all, period_kind: 'full_scope', period_start: 'null', period_end: 'null'},
        {person_count: '0', record_count: '0'}, 'empty_source'),
    ]))!;
    expect(chartPoints(empty.kind, empty.groups[0], 'record_count')[0]).toMatchObject({label: 'Full scope', exact: '0', position: 0});
  });

  it('plots only supplied order statistics for one measurement, unit and operator', () => {
    const dimensions = {concept_tag: {kind: 'id', value: '1'}, unit_concept_tag: {kind: 'id', value: '2'}, raw_operator_tag: {kind: 'null'}};
    // 20 observations: -2.5, -0.0000001, seven zeros, the median below, five 0.5s, three ones and two fives.
    const sum = '13.09999990000000000001';
    const stats = {n: '20', min: '-2.5', p10: '-0.0000001', p25: '0', p50: '0.10000000000000000001',
      p75: '0.5', p90: '1', max: '5', sum, mean_numerator: sum, mean_denominator: '20'};
    const empty = {n: '0', min: null, p10: null, p25: null, p50: null, p75: null, p90: null, max: null,
      sum: null, mean_numerator: null, mean_denominator: null};
    const spec = chartSpec(page('core.measurement.numeric_summary', [
      row('first', dimensions, stats),
      row('second', {...dimensions, unit_concept_tag: {kind: 'id', value: '3'}}, empty, 'empty_population'),
    ], 'summary'))!;
    expect(spec.groups.map(g => g.label)).toEqual(['Concept ID 1 · Unit ID 2 · Operator null', 'Concept ID 1 · Unit ID 3 · Operator null']);
    const points = chartPoints(spec.kind, spec.groups[0], 'value');
    expect(points.map(p => p.label)).toEqual(['Min', 'P10', 'P25', 'Median', 'P75', 'P90', 'Max']);
    expect(points.map(p => p.position)).toEqual([-2.5, -1e-7, 0, null, 0.5, 1, 5]);
    expect(points[3].exact).toBe(stats.p50);
    expect(chartPoints(spec.kind, spec.groups[1], 'value').every(p => p.exact === null && p.position === null)).toBe(true);
  });

  it.each([
    ['2.50', 2.5], ['10.000', 10], ['0.00', 0], ['-0.0000001000', -1e-7],
    ['0.1000000000000000000100', null], ['9007199254740993.00', null],
  ] as const)('preserves published decimal %s when projecting quantile positions', (exact, position) => {
    const values = {n: '1', sum: exact, mean_numerator: exact, mean_denominator: '1', min: exact,
      p10: exact, p25: exact, p50: exact, p75: exact, p90: exact, max: exact};
    const dimensions = {concept_tag: {kind: 'id', value: '1'}, unit_concept_tag: {kind: 'id', value: '2'}, raw_operator_tag: {kind: 'null'}};
    const spec = chartSpec(page('core.measurement.numeric_summary', [row('summary', dimensions, values)], 'summary'))!;
    const points = chartPoints(spec.kind, spec.groups[0], 'value');
    expect(points.every(point => point.position === position && point.exact === exact)).toBe(true);
  });

  it('leaves unsupported reports, versions and row kinds in the exact table', () => {
    expect(chartSpec(page('core.person.count', []))).toBeNull();
    expect(chartSpec({...page('core.person.birth_year_count', []), version: '2.0.0'})).toBeNull();
    expect(chartSpec(page('core.measurement.numeric_summary', [], 'eligibility_counts'))).toBeNull();
    expect(chartSpec(page('core.extension.capture_count', []))).toBeNull();
  });
});
