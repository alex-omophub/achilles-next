#!/usr/bin/env python3
"""Independent tiny population/observation oracle plus installed PostgreSQL proof."""
import argparse
from collections import Counter, defaultdict
from datetime import date, timedelta
import calendar
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def fixtures():
    people = [dict(zip(['person_id', 'year_of_birth', 'gender_concept_id', 'race_concept_id', 'ethnicity_concept_id'], row)) for row in [
        ['1', '1981', '1', None, '0'], ['2', '1982', '1', '0', None], ['3', '1980', '0', '-1', '1'],
        ['4', None, None, '1', '1'], ['5', '0', None, '1', '0'], ['6', '2030', '-1', '0', '0'],
        ['7', '1800', '0', '0', '0'], ['8', '-9223372036854775808', '0', None, None],
        ['9007199254740993', '1970', '9007199254740993', '9007199254740993', '0']]]
    intervals = [dict(zip(['person_id', 'observation_period_start_date', 'observation_period_end_date', 'period_type_concept_id'], row)) for row in [
        ['1', '2020-01-01', '2020-02-15', '0'], ['1', '2020-01-01', '2020-02-15', None],
        ['1', '2020-01-10', '2020-03-01', '1'], ['1', '2020-03-02', '2020-03-31', '1'],
        ['2', '2020-01-15', '2020-01-20', '0'], ['2', '2020-02-01', '2020-02-28', '0'],
        ['4', '2020-01-01', '2020-12-31', None], ['5', '2020-02-29', '2020-02-29', '-1'],
        ['6', '2019-12-31', '2020-01-01', '1'], ['7', '2020-01-30', '2020-02-02', '1'],
        ['9007199254740993', '2020-01-01', '2020-12-31', '9007199254740993'],
        [None, None, '2020-01-01', None], ['99', None, None, '0'],
        ['3', None, '2020-02-01', '1'], ['2', '2020-02-20', '2020-02-19', '0']]]
    cases = [dict(id='adversarial', person=people, observation_period=intervals, window=None),
             dict(id='clipped', person=people, observation_period=intervals, window=dict(start='2020-01-15', end='2020-02-15')),
             dict(id='empty', person=[], observation_period=[], window=None),
             dict(id='no_intervals', person=people[:2], observation_period=[], window=dict(start='2020-01-15', end='2020-02-15')),
             dict(id='invalid_only', person=people[:2], observation_period=intervals[-4:], window=None)]
    cases.append(dict(id='streamed',person=[dict(person_id=str(1001+i),year_of_birth=str(1900+i%100),gender_concept_id=str(i),race_concept_id=str(i%2),ethnicity_concept_id=str(i%3)) for i in range(130)],
        observation_period=[dict(person_id='1001',observation_period_start_date='2020-01-01',observation_period_end_date='2020-01-01',period_type_concept_id='0')],window=None))
    for name, year, start, end in [('early', '1', '0001-01-01', '0001-01-03'), ('late', '9999', '9999-12-30', '9999-12-31')]:
        cases.append(dict(id=name,person=[dict(person_id='1',year_of_birth=year,gender_concept_id=None,race_concept_id='0',ethnicity_concept_id=None)],
            observation_period=[dict(person_id='1',observation_period_start_date=start,observation_period_end_date=end,period_type_concept_id=None)],window=None))
    return cases


def day_text(day):
    return f'{day.year:04}-{day.month:02}-{day.day:02}'


def periods(lo, hi):
    result = [('full_scope', lo, hi, False)]
    if lo is None:
        return result
    y, m = lo.year, lo.month
    while True:
        first, last = date(y, m, 1), date(y, m, calendar.monthrange(y, m)[1])
        result.append(('calendar_month', max(first, lo), min(last, hi), lo <= first and hi >= last))
        if (y, m) == (hi.year, hi.month):
            break
        y, m = (y+1, 1) if m == 12 else (y, m+1)
    for y in range(lo.year, hi.year+1):
        first, last = date(y, 1, 1), date(y, 12, 31)
        result.append(('calendar_year', max(first, lo), min(last, hi), lo <= first and hi >= last))
    return result


def oracle(case):
    people = {p['person_id']:p for p in case['person']}
    days = defaultdict(set); integrity = Counter(); types = Counter()
    for op in case['observation_period']:
        pid, start, end = op['person_id'], op['observation_period_start_date'], op['observation_period_end_date']
        types[op['period_type_concept_id'] or 'null'] += 1
        reason = ('null_person' if pid is None else 'orphan_person' if pid not in people else
                  'null_endpoints' if start is None or end is None else 'reversed_interval' if start > end else 'valid')
        integrity[reason] += 1
        if reason == 'valid':
            start, end = date.fromisoformat(start), date.fromisoformat(end)
            days[pid].update(start+timedelta(days=i) for i in range((end-start).days+1))
    islands = {}
    for pid, observed in days.items():
        groups = []
        for day in sorted(observed):
            if groups and (day-groups[-1][1]).days == 1:
                groups[-1][1] = day
            else:
                groups.append([day, day])
        islands[pid] = groups
    all_days = set().union(*days.values()) if days else set()
    bounds = case['window']
    lo, hi = ((date.fromisoformat(bounds['start']),date.fromisoformat(bounds['end'])) if bounds else
              (min(all_days),max(all_days)) if all_days else (None,None))
    outputs = defaultdict(list); states = {}
    profile = json.loads((ROOT/'inst/analysis/core-characterization-v2.json').read_text())
    ids = [m['id'] for m in profile['metrics'] if m['id'].startswith(('core.person.','core.observation_period.'))]
    for mid in ids:
        if mid.startswith('core.person.') or mid.endswith(('person_interval_histogram','total_days_histogram')):
            n = len(people)
        elif mid.endswith(('type_count','integrity_count')):
            n = len(case['observation_period'])
        else:
            n = len(islands)
        states[mid] = ('computed',None) if n else (('empty_source','source.empty') if not people or mid.endswith(('type_count','integrity_count')) else ('empty_population','observation.no_valid_intervals'))
    person_identity = dict(metric_id='core.person.count',metric_version='1.0.0',row_kind='counts',dimensions={})
    person_key = hashlib.sha256((json.dumps(person_identity,sort_keys=True,separators=(',',':'))+'\n').encode()).hexdigest()

    def emit(mid, dims, values, kind='counts'):
        state, reason = states[mid]
        if kind == 'summary' and values['n'] == '0':
            state, reason = 'empty_population','summary.no_eligible'
        refs = []
        if mid.startswith('core.person.') and mid != 'core.person.count':
            refs = [dict(measure='person_count',metric_id='core.person.count',row_key=person_key,field='person_count',value=str(len(people)))]
        outputs[mid].append(dict(dimensions=dims,row_kind=kind,values=values,state=state,reason_code=reason,denominator_refs=refs))

    emit('core.person.count',{},dict(person_count=str(len(people))))
    for suffix, keys in [('gender_count',['gender_concept_id']),('birth_year_count',['year_of_birth']),('race_count',['race_concept_id']),
                         ('ethnicity_count',['ethnicity_concept_id']),('birth_year_gender_count',['year_of_birth','gender_concept_id']),('race_ethnicity_count',['race_concept_id','ethnicity_concept_id'])]:
        groups = Counter(tuple(p[k] if p[k] is not None else 'null' for k in keys) for p in people.values())
        for dims, n in groups.items():
            emit('core.person.'+suffix,dict(zip(keys,dims)),dict(person_count=str(n)))
    for kind, start, end, full in periods(lo, hi):
        observed = {pid:{d for d in ds if start is not None and start <= d <= end} for pid, ds in days.items()}
        dims = dict(period_kind=kind,period_start=day_text(start) if start else 'null',period_end=day_text(end) if end else 'null')
        emit('core.observation_period.coverage_count',dims,dict(person_count=str(sum(bool(ds) for ds in observed.values())),person_days=str(sum(len(ds) for ds in observed.values()))))
        continuous = sum(len(ds)==(end-start).days+1 for ds in observed.values()) if start else 0
        emit('core.observation_period.continuous_person_count',{**dims,'full_calendar_period':str(full).lower()},dict(person_count=str(continuous)))
        if kind == 'calendar_year':
            groups = Counter()
            for pid, ds in observed.items():
                if ds:
                    p = people[pid];birth = int(p['year_of_birth']) if p['year_of_birth'] is not None else 0
                    age = start.year-birth
                    bucket = str(age//10) if 1 <= birth <= 9999 and 0 <= age <= 130 else 'unknown'
                    groups[start.year,p['gender_concept_id'] or 'null',bucket] += 1
            for (year, gender, age), n in groups.items():
                emit('core.observation_period.year_gender_age_count',dict(year=str(year),gender_concept_id=gender,year_age_decile=age),dict(person_count=str(n)))
    first_age = Counter();first_bucket = Counter();interval_hist = Counter();days_hist = Counter();boundaries = defaultdict(lambda:[0,set()]);samples = defaultdict(list)
    for pid,p in people.items():
        groups = islands.get(pid,[]);interval_hist[len(groups)] += 1;days_hist[len(days[pid])//30] += 1
        if not groups:
            continue
        first,last = groups[0];birth = int(p['year_of_birth']) if p['year_of_birth'] is not None else 0
        age = first.year-birth;eligible = 1 <= birth <= 9999 and 0 <= age <= 130;gender = p['gender_concept_id'] or 'null'
        reason = 'eligible' if eligible else 'birth_year_missing_or_invalid' if not 1 <= birth <= 9999 else 'year_age_outside_0_130'
        first_age[gender,str(age) if eligible else 'unknown'] += 1
        first_bucket[((last-first).days+1)//30] += 1
        samples['core.observation_period.first_age_summary',json.dumps(dict(gender_concept_id=gender),sort_keys=True)].append((age if eligible else None,reason))
        samples['core.observation_period.first_interval_days_summary',json.dumps(dict(gender_concept_id=gender,first_year_age_decile=str(age//10) if eligible else 'unknown'),sort_keys=True)].append(((last-first).days+1,'eligible'))
        for start,end in groups:
            for kind,day in [('start',start),('end',end)]:
                key = kind,day_text(date(day.year,day.month,1));boundaries[key][0] += 1;boundaries[key][1].add(pid)
    for (gender,age),n in first_age.items():emit('core.observation_period.first_age_count',dict(gender_concept_id=gender,year_age_or_unknown=age),dict(person_count=str(n)))
    for suffix,key,groups in [('first_interval_30d_count','floor_days_div_30',first_bucket),('person_interval_histogram','interval_count',interval_hist),('total_days_histogram','floor_days_div_30',days_hist)]:
        for value,n in groups.items():emit('core.observation_period.'+suffix,{key:str(value)},dict(person_count=str(n)))
    for (kind,month),(n,pids) in boundaries.items():emit('core.observation_period.boundary_month_count',dict(boundary_kind=kind,month=month),dict(interval_count=str(n),person_count=str(len(pids))))
    for raw,n in types.items():emit('core.observation_period.type_count',dict(period_type_concept_id=raw),dict(record_count=str(n)))
    for reason in ['null_person','orphan_person','null_endpoints','reversed_interval','valid']:emit('core.observation_period.integrity_count',dict(reason=reason),dict(record_count=str(integrity[reason])))
    for (mid,dims),records in samples.items():
        dims = json.loads(dims);values = sorted(v for v,reason in records if reason=='eligible');n = len(values)
        v = dict(n=str(n),sum=str(sum(values)) if n else None,mean_numerator=str(sum(values)) if n else None,mean_denominator=str(n) if n else None,
                 min=str(min(values)) if n else None,max=str(max(values)) if n else None)
        for name,a,b in [('p10',1,10),('p25',1,4),('p50',1,2),('p75',3,4),('p90',9,10)]:v[name] = str(values[(n*a+b-1)//b-1]) if n else None
        emit(mid,dims,v,'summary')
        for reason in (['event_date_missing_or_invalid','birth_year_missing_or_invalid','year_age_outside_0_130','eligible'] if mid.endswith('first_age_summary') else ['eligible']):
            emit(mid,{**dims,'eligibility_reason':reason},dict(person_count=str(sum(r==reason for value,r in records))),'eligibility_counts')
    return {mid:outputs[mid] for mid in ids},states


def canonical(rows):
    return sorted(json.dumps({k:v for k,v in row.items() if k!='row_key'},sort_keys=True,separators=(',',':')) for row in rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,required=True);parser.add_argument('--output-dir',type=Path,required=True)
    args = parser.parse_args();out = args.output_dir.resolve()
    if out.exists() or out.is_relative_to(ROOT):parser.error('Use a new evidence directory outside the checkout')
    out.mkdir(parents=True,mode=0o700);cases=fixtures();(out/'input.json').write_text(json.dumps(cases))
    subprocess.run(['Rscript','--vanilla','tests/tracer/population-baseline.R',str(args.config.resolve(strict=True)),str(out)],cwd=ROOT,check=True)
    report=json.loads((out/'report.json').read_text());assert len(report['snapshots'])==len(cases)*3
    assert {(s['case'],s['version']) for s in report['snapshots']}=={(c['id'],v) for c in cases for v in ('5.3','5.4','5.5')}
    for snapshot in report['snapshots']:
        case=next(c for c in cases if c['id']==snapshot['case']);expected,states=oracle(case)
        if set(snapshot['rows'])!=set(expected):raise ValueError('Wrong generated metric inventory')
        for mid,rows in expected.items():
            if canonical(rows)!=canonical(snapshot['rows'][mid]):raise ValueError(f'Independent oracle mismatch: {case["id"]}/{snapshot["version"]}/{mid}')
            metadata=snapshot['context']['inventory'][mid]
            if metadata['state']!=states[mid][0] or metadata['reason_code']!=states[mid][1]:raise ValueError(f'Dataset state mismatch: {case["id"]}/{mid}')
    report['independent_oracle']='passed_all_19_metrics';report['mismatches']=0
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'PASS: {len(report["snapshots"])} persisted baselines / 19 metrics; independent day-set and integer-rank oracle; no scale claim')


if __name__=='__main__':main()
