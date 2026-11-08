"""Small-fixture independent bag/count/day-set/exact-sort oracle, not a scale comparator."""
from collections import Counter, defaultdict
import csv
from datetime import date, timedelta
from decimal import Decimal, localcontext
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
# Bound expansion independently of the manifest's byte/row limits. A preview
# needs at most 91 days per valid interval; retain some headroom for small edits.
MAX_PERIOD_DAYS = 366
MAX_EXPANDED_DAYS = 100000


def read_tables(directory):
    # Only the hard-capped preview is eligible for this in-memory test oracle.
    directory=Path(directory);path=directory/'manifest.json'
    if path.stat().st_size>4*1024**2:raise ValueError('Oracle manifest budget exceeded')
    manifest = json.loads(path.read_text())
    if not 0<=manifest['parameters']['events']<=10000 or not 0<=manifest['parameters']['people']<=1000 or len(manifest['tables'])>64:
        raise ValueError('Oracle is restricted to small previews')
    tables = {};total_bytes=0;total_rows=0
    for name, info in manifest['tables'].items():
        if not re.fullmatch('[a-z_]+',name) or info['file']!=name+'.csv':raise ValueError('Invalid preview table path')
        path=directory/info['file'];total_bytes+=path.stat().st_size
        if path.is_symlink() or total_bytes>32*1024**2:raise ValueError('Oracle file budget/type exceeded')
        with path.open(newline='',encoding='utf-8') as stream:
            reader = csv.DictReader(stream)
            data=[]
            for row in reader:
                total_rows+=1
                if len(data)>=10000 or total_rows>20000:raise ValueError('Oracle row budget exceeded')
                data.append({k:None if v=='\\N' else v for k,v in row.items()})
        if len(data)!=info['rows']:raise ValueError('Independent CSV row count differs from manifest')
        tables[name] = data
    return manifest,tables


def key(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'))


def tag(value):
    return dict(kind='null') if value is None else dict(kind='id',value=value)


def decimal_text(value):
    text = format(value,'f')
    return (text.rstrip('0').rstrip('.') if '.' in text else text) if value else '0'


def expected(directory):
    manifest,tables = read_tables(directory)
    profile = json.loads((ROOT/'inst/analysis/core-characterization-v2.json').read_text())
    people = {p['person_id'] for p in tables['person']}
    result = {'core.person.count':{key({}):dict(person_count=str(len(people)))}}
    for field,suffix in [('gender_concept_id','gender_count'),('race_concept_id','race_count'),('ethnicity_concept_id','ethnicity_count')]:
        result['core.person.'+suffix] = {key({field:v}):dict(person_count=str(n)) for v,n in Counter(p[field] for p in tables['person']).items()}
    days = defaultdict(set)
    expanded_days = 0
    for row in tables['observation_period']:
        lo,hi = date.fromisoformat(row['observation_period_start_date']),date.fromisoformat(row['observation_period_end_date'])
        if lo<=hi:
            span = (hi-lo).days+1
            if span>MAX_PERIOD_DAYS or expanded_days+span>MAX_EXPANDED_DAYS:
                raise ValueError('Oracle observation day expansion budget exceeded')
            expanded_days += span
            days[row['person_id']].update(lo+timedelta(days=i) for i in range(span))
    duplicates = {};presence = defaultdict(set)
    for domain,spec in profile['domains'].items():
        data = tables[spec['table']]
        duplicates[domain] = len(data)-len({key(r) for r in data})
        groups = defaultdict(list);observed = defaultdict(list)
        for row in data:
            concept = key(tag(row[spec['concept']]))
            groups[concept].append(row);groups[key(dict(kind='all'))].append(row)
            presence[row['person_id']].add(domain)
            if date.fromisoformat(row[spec['event_date']]) in days.get(row['person_id'],set()):
                observed[concept].append(row);observed[key(dict(kind='all'))].append(row)
        for concept in groups:observed.setdefault(concept,[])
        for prefix,buckets in [('core.',groups),('observed.',observed)]:
            # Full-scope all-concept zero is retained even for an empty domain.
            buckets.setdefault(key(dict(kind='all')),[])
            result[prefix+domain+'.capture_count'] = {
                key(dict(concept_tag=json.loads(c),period_kind='full_scope',period_start='null',period_end='null')):
                dict(record_count=str(len(rs)),person_count=str(len({r['person_id'] for r in rs if r['person_id'] in people})))
                for c,rs in buckets.items()}
    units = {c['concept_id'] for c in tables['concept'] if c['domain_id']=='Unit' and int(c['concept_id'])>0}
    samples = defaultdict(list)
    for row in tables['measurement']:
        if row['unit_concept_id'] in units and row['operator_concept_id'] in (None,'0'):
            dims = dict(concept_tag=tag(row['measurement_concept_id']),unit_concept_tag=tag(row['unit_concept_id']),raw_operator_tag=tag(row['operator_concept_id']))
            values = samples[key(dims)]
            if row['value_as_number'] is not None and Decimal(row['value_as_number']).is_finite():
                values.append(Decimal(row['value_as_number']))
    summaries = {}
    with localcontext() as context:
        context.prec = 256
        for dims,values in samples.items():
            values.sort();n=len(values);total=decimal_text(sum(values)) if n else None
            out = dict(n=str(n),sum=total,mean_numerator=total,mean_denominator=str(n) if n else None,
                       min=decimal_text(values[0]) if n else None,max=decimal_text(values[-1]) if n else None)
            for name,num,den in [('p10',1,10),('p25',1,4),('p50',1,2),('p75',3,4),('p90',9,10)]:
                out[name]=decimal_text(values[(n*num+den-1)//den-1]) if n else None
            summaries[dims] = out
    result['core.measurement.numeric_summary'] = summaries
    density = Counter(len(presence[p]) for p in people)
    result['core.density.domain_count'] = {key(dict(domain_count=str(k))):dict(person_count=str(v)) for k,v in density.items()}
    return dict(selected_metrics=result,source_rows={t:len(rs) for t,rs in tables.items()},
                actual_duplicate_rows=duplicates,observed_people=len(days),person_days=sum(map(len,days.values())),
                scheduled_duplicate_rows=manifest['scheduled_duplicate_rows'])


def check_snapshot(snapshot, oracle):
    checked = 0
    for mid,want in oracle['selected_metrics'].items():
        rows = snapshot['rows'][mid]
        if mid.endswith('.capture_count'):rows=[r for r in rows if r['dimensions']['period_kind']=='full_scope']
        if mid.endswith('.numeric_summary'):rows=[r for r in rows if r['row_kind']=='summary']
        got = {key(r['dimensions']):r['values'] for r in rows}
        if len(got)!=len(rows) or got!=want:raise ValueError('Independent preview oracle mismatch: '+mid)
        checked += len(rows)
    coverage = next(r for r in snapshot['rows']['core.observation_period.coverage_count'] if r['dimensions']['period_kind']=='full_scope')
    if coverage['values'] != dict(person_count=str(oracle['observed_people']),person_days=str(oracle['person_days'])):
        raise ValueError('Independent observation day-set mismatch')
    return dict(metrics=len(oracle['selected_metrics'])+1,rows=checked+1,
                scope='selected counts/day sets/exact measurement summaries; not full142-output independent comparator')
