import {useState, type FormEvent} from 'react';
import type {PublicationProvider} from './PublicationView';
import type {ReportPage, SavedFilters} from './saved-publication';
import {SavedConceptFinder, validConceptId} from './SavedConceptFinder';

type Axis = 'concept' | 'unit' | 'operator';
const keys = {concept: 'concept_tag', unit: 'unit_concept_tag', operator: 'raw_operator_tag'} as const;
const labels = {concept: 'Concept', unit: 'Unit', operator: 'Operator'};
const periods: Record<string, string> = {full_scope: 'Full scope', calendar_month: 'Calendar month', calendar_year: 'Calendar year', undated: 'Undated'};
type Capability = NonNullable<ReportPage['capability']>;
type TagChoice = {kind: string; id: string};
function selectedTag(axis: Axis, filters: SavedFilters, zeroOnly: boolean): TagChoice {
  const v = filters[keys[axis]];
  if (!v || typeof v === 'string') return {kind: 'any', id: ''};
  if (v.kind !== 'id') return {kind: v.kind, id: ''};
  return {kind: zeroOnly && v.value === '0' ? 'zero' : 'id', id: v.value};
}
function TagField({axis, choice, change, positive, zeroOnly}: {axis: Axis; choice: TagChoice;
    change: (next: TagChoice) => void; positive: boolean; zeroOnly: boolean}) {
  return <div className="publication-filter-axis">
    <label>{labels[axis]}<select value={choice.kind} onChange={e => change({kind: e.target.value, id: ''})}>
      <option value="any">Any saved value</option>
      {zeroOnly ? <option value="zero">ID 0</option> : <option value="id">Exact ID</option>}
      {!positive && <option value="null">NULL</option>}
      {!positive && !zeroOnly && <><option value="all">All (saved total)</option><option value="schema_absent">Schema absent</option></>}
    </select></label>
    {choice.kind === 'id' && <label>{labels[axis]} ID<input type="text" value={choice.id} required maxLength={513}
      onChange={e => change({kind: 'id', id: e.target.value})}/></label>}
  </div>;
}
function date(value: string) {
  if (!/^(?!0000)\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const d = new Date(value + 'T00:00:00Z');
  return Number.isFinite(d.getTime()) && d.toISOString().slice(0, 10) === value;
}
export function supportsFilters(c: Capability) {
  return c.concept === 'exact_saved_tag' || c.unit === 'exact_saved_tag' || c.operator === 'exact_saved_tag'
    || ['exact_saved_period', 'saved_month', 'saved_year'].includes(c.time);
}
export function SavedReportFilters({provider, report, capability, applied, apply, fail}: {provider: PublicationProvider;
    report: ReportPage; capability: Capability; applied: SavedFilters; apply: (next: SavedFilters) => void; fail: (error: unknown) => void}) {
  const positiveUnit = report.rowKind === 'summary' && ['core.measurement.numeric_summary', 'core.observation.numeric_summary',
    'core.measurement.range_low_summary', 'core.measurement.range_high_summary'].includes(report.metric_id);
  const zeroOperator = report.rowKind === 'summary' && report.metric_id === 'core.measurement.numeric_summary';
  const axes = (Object.keys(keys) as Axis[]).filter(axis => capability[axis] === 'exact_saved_tag');
  const [tags, setTags] = useState(() => ({
    concept: selectedTag('concept', applied, false), unit: selectedTag('unit', applied, false), operator: selectedTag('operator', applied, zeroOperator),
  }));
  const text = (name: string) => typeof applied[name] === 'string' ? applied[name] as string : '';
  const [period, setPeriod] = useState(text('period_kind') || 'any');
  const [start, setStart] = useState(text('period_start') === 'null' ? '' : text('period_start'));
  const [end, setEnd] = useState(text('period_end') === 'null' ? '' : text('period_end'));
  const [month, setMonth] = useState(text('month').slice(0, 7));
  const [year, setYear] = useState(text('year'));
  const [error, setError] = useState('');
  const [chosen, setChosen] = useState('');
  const bounds = period.startsWith('calendar_') || (period === 'full_scope' && capability.period_bounds.full_scope === 'saved_bounds');
  function setTag(axis: Axis, choice: TagChoice) {
    setError('');
    if (axis === 'concept') setChosen('');
    setTags(previous => ({...previous, [axis]: choice}));
  }
  function submit(event: FormEvent) {
    event.preventDefault();
    const filters: Record<string, SavedFilters[string]> = {};
    for (const axis of axes) {
      const {kind, id} = tags[axis];
      if (kind === 'id') {
        if (!validConceptId(id) || (axis === 'unit' && positiveUnit && !/^[1-9]/.test(id))) {
          setError(`Enter ${axis === 'unit' && positiveUnit ? 'a positive' : 'an exact signed integer'} ${labels[axis].toLowerCase()} ID.`); return;
        }
        filters[keys[axis]] = {kind, value: id};
      } else if (kind === 'zero') filters[keys[axis]] = {kind: 'id', value: '0'};
      else if (kind === 'all' || kind === 'schema_absent' || kind === 'null') filters[keys[axis]] = {kind};
    }
    if (capability.time === 'exact_saved_period' && period !== 'any') {
      if (bounds && (!date(start) || !date(end) || start > end ||
          (period === 'calendar_month' && start.slice(0, 7) !== end.slice(0, 7)) ||
          (period === 'calendar_year' && start.slice(0, 4) !== end.slice(0, 4)))) {
        setError('Enter ordered start and end dates within the selected period.'); return;
      }
      Object.assign(filters, {period_kind: period, period_start: bounds ? start : 'null', period_end: bounds ? end : 'null'});
    }
    if (capability.time === 'saved_month' && month) {
      if (!date(month + '-01')) { setError('Enter a valid saved month.'); return; }
      filters.month = month + '-01';
    }
    if (capability.time === 'saved_year' && year) {
      if (!validConceptId(year)) { setError('Enter an exact integer year.'); return; }
      filters.year = year;
    }
    apply(filters);
  }
  return <div className="publication-filter-body">
    <form onSubmit={submit}>
      <div className="publication-filter-fields">
        {axes.map(axis => <TagField key={axis} axis={axis} choice={tags[axis]} change={choice => setTag(axis, choice)}
          positive={axis === 'unit' && positiveUnit} zeroOnly={axis === 'operator' && zeroOperator}/>)}
        {capability.time === 'exact_saved_period' && <>
          <label>Saved period<select value={period} onChange={e => {setPeriod(e.target.value); setError(''); setStart(''); setEnd('');}}>
            <option value="any">Any saved period</option>
            {capability.period_kinds.map(kind => <option key={kind} value={kind}>{periods[kind]}</option>)}
          </select></label>
          {bounds && <>
            <label>Period start<input type="date" required value={start} onChange={e => setStart(e.target.value)}/></label>
            <label>Period end<input type="date" required value={end} onChange={e => setEnd(e.target.value)}/></label>
          </>}
        </>}
        {capability.time === 'saved_month' && <label>Saved month<input type="month" value={month} onChange={e => setMonth(e.target.value)}/></label>}
        {capability.time === 'saved_year' && <label>Saved year<input type="text" value={year} maxLength={513} onChange={e => setYear(e.target.value)}/></label>}
      </div>
      {chosen && <p role="status">Concept ID {chosen} selected. Apply filters to read its saved rows.</p>}
      {error && <p role="alert">{error}</p>}
      <div className="publication-filter-actions">
        <button type="submit">Apply filters</button><button type="button" onClick={() => apply({})}>Clear filters</button>
      </div>
    </form>
    {axes.includes('concept') && (provider.search || provider.lookup) && <SavedConceptFinder provider={provider} context={report.context}
      choose={id => {setTag('concept', {kind: 'id', id}); setChosen(id);}} fail={fail}/>}
  </div>;
}
