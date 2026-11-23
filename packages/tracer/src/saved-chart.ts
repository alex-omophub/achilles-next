import type {ReportPage, ReportRow, ReportValue} from './saved-publication';

type ChartRow = Pick<ReportRow, 'dimensions' | 'values' | 'state' | 'row_key'>;
type ChartPage = Pick<ReportPage, 'version' | 'rowKind' | 'metric_id'> & {rows: ChartRow[]};
type Kind = 'birth' | 'capture' | 'quantiles';
type Measure = 'person_count' | 'record_count' | 'value';
export interface ChartPoint {
  label: string;
  detail: string;
  exact: string | null;
  position: number | null;
}
interface Group {id: string; label: string; rows: ChartRow[]}
export interface ChartSpec {kind: Kind; title: string; groups: Group[]}
const capture = /^(core|observed)\.(condition|drug|procedure|visit|device|observation|death|specimen|measurement)\.capture_count$/;
const periods: Record<string, string> = {full_scope: 'Full scope', undated: 'Undated', calendar_month: 'Calendar month', calendar_year: 'Calendar year'};
const statistics = [['min', 'Min'], ['p10', 'P10'], ['p25', 'P25'], ['p50', 'Median'], ['p75', 'P75'], ['p90', 'P90'], ['max', 'Max']] as const;

function tag(value: ReportValue | undefined): string | null {
  if (!value || typeof value !== 'object' || !('kind' in value)) return null;
  if (value.kind === 'id' && typeof value.value === 'string') return 'ID ' + value.value;
  if (value.kind === 'all') return 'all';
  if (value.kind === 'null') return 'null';
  if (value.kind === 'schema_absent') return 'schema absent';
  return null;
}
export function chartSpec(report: ChartPage): ChartSpec | null {
  if (report.version !== '1.0.0') return null;
  if (report.metric_id === 'core.person.birth_year_count' && report.rowKind === 'counts')
    return {kind: 'birth', title: 'People by recorded birth year', groups: [{id: 'year', label: 'Recorded birth year', rows: report.rows}]};
  if (report.metric_id === 'core.measurement.numeric_summary' && report.rowKind === 'summary') {
    const groups: Group[] = [];
    for (const row of report.rows) {
      const {concept_tag, unit_concept_tag, raw_operator_tag} = row.dimensions;
      const concept = tag(concept_tag), unit = tag(unit_concept_tag), operator = tag(raw_operator_tag);
      if (concept && unit && operator) groups.push({id: row.row_key, label: `Concept ${concept} · Unit ${unit} · Operator ${operator}`, rows: [row]});
    }
    return {kind: 'quantiles', title: 'Measurement distribution', groups};
  }
  if (!capture.test(report.metric_id) || report.rowKind !== 'counts') return null;
  const groups = new Map<string, Group>();
  for (const row of report.rows) {
    const {concept_tag, period_kind} = row.dimensions;
    const concept = tag(concept_tag);
    if (!concept || typeof period_kind !== 'string' || !Object.hasOwn(periods, period_kind)) continue;
    const id = JSON.stringify([concept, period_kind]);
    if (!groups.has(id)) groups.set(id, {id, label: `Concept ${concept} · ${periods[period_kind]}`, rows: []});
    groups.get(id)!.rows.push(row);
  }
  return {kind: 'capture', title: 'Capture by saved period', groups: [...groups.values()]};
}

function coordinate(exact: string, count: boolean): number | null {
  // Recharts positions are binary floats. Require an exact decimal-text round
  // trip, including small decimals that JavaScript prints in exponential form.
  if (exact.length > 350 || !(count ? /^(0|[1-9]\d*)$/ : /^-?(0|[1-9]\d*)(\.\d+)?$/).test(exact)) return null;
  const value = Number(exact);
  if (!Number.isFinite(value) || Math.abs(value) > Number.MAX_SAFE_INTEGER) return null;
  const [mantissa, exponent] = String(value).split('e');
  if (!exponent) return mantissa === exact ? value : null;
  // All permitted positive exponents here use ordinary decimal notation.
  const digits = mantissa.replace('-', '').replace('.', '');
  const decimal = (value < 0 ? '-' : '') + '0.' + '0'.repeat(-Number(exponent) - 1) + digits;
  return decimal === exact ? value : null;
}
function point(row: ChartRow, key: string, label: string, detail: string, count: boolean): ChartPoint {
  const visible = ['computed', 'empty_source', 'empty_population'].includes(row.state);
  const raw = visible ? row.values?.[key] : null;
  const exact = typeof raw === 'string' ? raw : null;
  return {label, detail, exact, position: exact === null ? null : coordinate(exact, count)};
}
export function chartPoints(kind: Kind, group: Group, measure: Measure): ChartPoint[] {
  if (kind === 'quantiles') {
    const row = group.rows[0];
    return statistics.map(([key, label]) => point(row, key, label, label, false));
  }
  if (kind === 'birth') {
    return group.rows.map(row => {
      const raw = row.dimensions.year_of_birth;
      const label = raw === 'null' ? 'Not recorded' : typeof raw === 'string' ? raw : 'Unknown';
      return point(row, 'person_count', label, label, true);
    }).sort((a, b) => a.label.localeCompare(b.label, 'en', {numeric: true}));
  }
  return group.rows.map(row => {
    const {period_kind, period_start, period_end} = row.dimensions;
    if (period_kind === 'full_scope' || period_kind === 'undated') return point(row, measure, periods[period_kind], periods[period_kind], true);
    const start = String(period_start), end = String(period_end);
    return point(row, measure, period_kind === 'calendar_month' ? start.slice(0, 7) : start.slice(0, 4), start + ' – ' + end, true);
  }).sort((a, b) => a.detail.localeCompare(b.detail));
}
