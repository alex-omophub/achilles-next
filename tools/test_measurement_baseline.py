#!/usr/bin/env python3
"""Independent exact whole-source measurement oracle and PostgreSQL proof."""
import argparse
from collections import Counter, defaultdict
from decimal import Decimal, getcontext
from itertools import product
import json
from pathlib import Path
import subprocess
import test_domain_baseline as base

ROOT = base.ROOT
MEASUREMENT = [m for m in base.PROFILE['metrics'] if '.measurement.' in m['id']]
DENSITY = [m for m in base.METRICS if m['id'].startswith('core.density.')]


def fixture():
    c=base.make_fixture(compact_calendar=True)
    for i,e in enumerate(c['events']):
        e.update(operator=[None,'0','999'][i%3],low=[None,'0','NaN','2'][i%4],high=[None,'10','Infinity','1'][i%4])
    def add(**kw):
        e=dict(c['events'][0],id=str(100+len(c['events'])),unit='200',operator='0',value='5',low='0',high='10',coded='0',source_value=' ')
        e.update(kw);c['events'].append(e)
    # Hand-selected same-row reference interval cases and precedence conflicts.
    for kw in [dict(value=None),dict(value='NaN'),dict(unit=None),dict(unit='0'),dict(unit='201'),dict(operator='1'),
               dict(low=None,high=None),dict(low=None),dict(low='Infinity'),dict(low='10',high='0'),
               dict(value='-1'),dict(value='0'),dict(value='10'),dict(value='11'),
               dict(value='9007199254740993.125'),dict(value='0.000000000000000000125'),
               dict(value='-Infinity',unit=None,operator='1'),dict(unit='0',operator='1'),
               dict(concept='102',value=None,low=None,high=None,operator=None)]:add(**kw)
    for numeric,coded,text in product([False,True],repeat=3):
        add(value='2' if numeric else None,coded='999' if coded else '0',source_value='\t' if text else ' ')
    # Uneven duplicate frequencies distinguish weighted nearest rank from an
    # unweighted quantile over distinct values. NULL/zero operators stay separate.
    for value in ['0']*7+['1','2','5','5','9']:
        add(value=value,operator=None)
    return c


def physical(case,version):
    m=base.physical(case,version)
    cols={probe.split('.')[1]: ('date' if probe.endswith('_date') else 'text' if probe.endswith('source_value') else
          'numeric' if probe.split('.')[1] in ['value_as_number','range_low','range_high'] else 'bigint')
          for spec in MEASUREMENT for probe in spec['inputs'] if probe.startswith('measurement.')}
    m['columns']['measurement']=cols
    m['tables']['measurement']=[dict(measurement_id=e['id'],person_id=e['person_id'],measurement_concept_id=e['concept'],
      measurement_date=e['date'],measurement_type_concept_id=e['type'],measurement_source_concept_id=e['source'],measurement_source_value=e['text'],
      value_as_number=e['value'],value_as_concept_id=e['coded'],value_source_value=e['source_value'],unit_concept_id=e['unit'],
      operator_concept_id=e['operator'],range_low=e['low'],range_high=e['high']) for e in case['events']]
    return m


def oracle(case,version):
    result=base.oracle(case,version)
    # Each source domain now has the same independent event fixture, including
    # measurement, rather than the older density-only PERSON=10 sentinel.
    density=Counter()
    people={p['person_id'] for p in case['person']}
    for pid in people:density[('1' if any(e['person_id']==pid for e in case['events']) else '0')*9]+=1
    result['core.density.domain_presence_count']={base.canon(dict(presence_bits=b)):dict(person_count=str(n)) for b,n in density.items()}
    counts=Counter()
    for b,n in density.items():counts[b.count('1')]+=n
    result['core.density.domain_count']={base.canon(dict(domain_count=str(k))):dict(person_count=str(n)) for k,n in counts.items()}
    extra=base.oracle(case,version,['measurement'],MEASUREMENT+DENSITY,physical(case,version))
    result.update({mid:rows for mid,rows in extra.items() if '.measurement.' in mid})
    core='core.measurement.'
    def put(suffix,dims,values):
        target=result[core+suffix];key=base.canon(dims);assert key not in target;target[key]=values
    def grouped(suffix,dim,persons=True):
        groups=defaultdict(list)
        for e in case['events']:groups[base.canon(dim(e))].append(e)
        for key,es in groups.items():
            v=dict(record_count=str(len(es)))
            if persons:v['person_count']=str(len({e['person_id'] for e in es if e['person_id'] in people}))
            put(suffix,json.loads(key),v)
    def dim(e):return dict(concept_tag=base.tag(e['concept']))
    def finite(v):return v is not None and Decimal(v).is_finite()
    def known(e):return e['unit']=='200'
    def numeric(e):
        return ('numeric_missing' if e['value'] is None else 'numeric_non_finite' if not finite(e['value']) else
                'unit_null' if e['unit'] is None else 'unit_zero' if e['unit']=='0' else 'unit_unrecognized' if not known(e) else
                'operator_explicit_measurement_only' if e['operator'] not in [None,'0'] else 'eligible')
    def status(e):
        if e['value'] is None:return 'numeric_missing'
        if not finite(e['value']):return 'numeric_non_finite'
        if not known(e):return 'unit_unavailable_or_unrecognized'
        if e['operator'] not in [None,'0']:return 'operator_explicit'
        lo,hi=e['low'],e['high']
        if lo is None and hi is None:return 'both_bounds_missing'
        if lo is None or hi is None:return 'one_bound_missing'
        if not finite(lo) or not finite(hi):return 'bound_non_finite'
        lo,hi,v=Decimal(lo),Decimal(hi),Decimal(e['value'])
        if lo>hi:return 'bounds_reversed'
        return 'below' if v<lo else 'above' if v>hi else 'within'
    for suffix,key,label in [('unit_count','unit','unit_concept_tag'),('coded_value_count','coded','value_concept_tag'),('operator_count','operator','raw_operator_tag')]:
        grouped(suffix,lambda e:dict(dim(e),**{label:base.tag(e[key])}))
    grouped('numeric_eligibility_count',lambda e:dict(dim(e),reason=numeric(e)),False)
    grouped('range_status_count',lambda e:dict(dim(e),unit_concept_tag=base.tag(e['unit']),raw_operator_tag=base.tag(e['operator']),reason=status(e)),False)
    for concept in {e['concept'] for e in case['events']}:
        for bits in product('01',repeat=3):
            flags=''.join(bits)
            es=[e for e in case['events'] if e['concept']==concept and
                ''.join(str(int(x)) for x in [e['value'] is not None,e['coded'] not in [None,'0'],e['source_value'] is not None and bool(e['source_value'].strip(' '))])==flags]
            put('representation_count',dict(concept_tag=base.tag(concept),representation_flags=flags),dict(record_count=str(len(es)),person_count=str(len({e['person_id'] for e in es if e['person_id'] in people}))))
    for suffix,key in [('numeric_summary','value'),('range_low_summary','low'),('range_high_summary','high')]:
        groups=defaultdict(list)
        for e in case['events']:
            if not known(e) or (suffix=='numeric_summary' and e['operator'] not in [None,'0']):continue
            d=dict(dim(e),unit_concept_tag=base.tag(e['unit']))
            if suffix=='numeric_summary':d['raw_operator_tag']=base.tag(e['operator']);reason=numeric(e)
            else:reason='bound_missing' if e[key] is None else 'bound_non_finite' if not finite(e[key]) else 'eligible'
            groups[base.canon(d)].append((reason,e[key]))
        reasons=base.REASONS['numeric_summary_order' if suffix=='numeric_summary' else 'range_boundary_order']
        for d,samples in groups.items():
            good=sorted(Decimal(v) for r,v in samples if r=='eligible');n=len(good);total=base.dec(sum(good)) if n else None
            values=dict(n=str(n),sum=total,mean_numerator=total,mean_denominator=str(n) if n else None,min=base.dec(good[0]) if n else None,max=base.dec(good[-1]) if n else None)
            for name,num,den in [('p10',1,10),('p25',1,4),('p50',1,2),('p75',3,4),('p90',9,10)]:values[name]=base.dec(good[(n*num+den-1)//den-1]) if n else None
            put(suffix,json.loads(d),values)
            for reason in reasons:put(suffix,dict(json.loads(d),eligibility_reason=reason),dict(record_count=str(sum(r==reason for r,v in samples))))
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--config',type=Path,required=True);parser.add_argument('--output-dir',type=Path,required=True);parser.add_argument('--full-matrix',action='store_true');a=parser.parse_args()
    try:out=base.create_evidence_dir(a.output_dir)
    except ValueError as e:parser.error(str(e))
    getcontext().prec=256
    case=fixture();empty=dict(case,id='empty',events=[],observation_period=[]);all_empty=dict(empty,id='empty_source',person=[]);unobserved=dict(case,id='unobserved',observation_period=[])
    cases={c['id']:c for c in [case,empty,all_empty,unobserved]}
    matrix=[(case,v) for v in (['5.3','5.4','5.5'] if a.full_matrix else ['5.5'])]+[(all_empty,'5.5')]
    if a.full_matrix:matrix += [(empty,'5.5'),(unobserved,'5.5')]
    inputs=[dict(case=c['id'],version=v,**physical(c,v)) for c,v in matrix]
    (out/'input.json').write_text(json.dumps(inputs))
    subprocess.run(['Rscript','--vanilla','tests/tracer/measurement-baseline.R',str(a.config.resolve()),str(out)],cwd=ROOT,check=True)
    report=json.loads((out/'report.json').read_text());checked=0
    assert len(report['snapshots'])==len(inputs)
    for snap in report['snapshots']:
        c=cases[snap['case']];expected=oracle(c,snap['version']);assert len(expected)==119
        for mid,want in expected.items():
            state,reason=base.dataset_state(mid,c,snap['version']);meta=snap['context']['inventory'][mid]
            assert (meta['state'],meta['reason_code'],meta['rows'])==(state,reason,str(len(want))),(snap['case'],snap['version'],mid,meta,state,reason)
            got={base.canon(r['dimensions']):{k:r[k] for k in ['values','state','reason_code']} for r in snap['rows'].get(mid,[])}
            wanted={k:base.cell(v,state,reason) for k,v in want.items()}
            if got!=wanted:
                for key in set(got)|set(wanted):
                    if got.get(key)!=wanted.get(key):raise AssertionError((snap['case'],snap['version'],mid,key,got.get(key),wanted.get(key)))
            checked+=len(want)
        # Population has independent day-set scopes, including the new calendars.
        population,states=base.population_expected(c,expected)
        for mid,rows in population.items():
            assert sorted(base.canon(r) for r in rows)==sorted(base.canon({k:v for k,v in r.items() if k!='row_key'}) for r in snap['rows'][mid]),mid
    summary=dict(status='passed',measurement_metrics=19,total_numeric_metrics=138,cases=len(inputs),domain_and_measurement_rows=checked,
                 exact_reference_weighted_parity=report['parity'],source_denied=report['source_denied'],full_profile_gate=report['full_profile_gate'])
    (out/'oracle.json').write_text(json.dumps(summary,indent=2)+'\n');print(summary)

if __name__=='__main__':main()
