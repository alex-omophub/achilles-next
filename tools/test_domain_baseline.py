#!/usr/bin/env python3
"""Independent eight-domain oracle and disposable PostgreSQL integration proof."""
import argparse
from collections import Counter, defaultdict
from datetime import date
from decimal import Decimal
import json
from pathlib import Path
import subprocess
from test_population_baseline import fixtures as population_fixtures, day_text, periods

ROOT = Path(__file__).resolve().parents[1]
PROFILE = json.loads((ROOT/'inst/analysis/core-characterization-v2.json').read_text())
DOMAINS = ['condition','drug','procedure','visit','device','observation','death','specimen']
METRICS = [m for m in PROFILE['metrics'] if m['id'].split('.')[1] in DOMAINS+['density']]
REASONS = PROFILE['contracts']['eligibility-reasons']


def tag(x):
    return {'kind':'null'} if x is None else {'kind':'id','value':str(x)}


def canon(x):
    return json.dumps(x, sort_keys=True, separators=(',',':'))


def dec(x):
    text = format(x, 'f')
    if '.' in text: text = text.rstrip('0').rstrip('.')
    return '0' if text == '-0' else text


def make_fixture(compact_calendar=False):
    pop=population_fixtures()[0]
    pop['person'].append(dict(person_id='10',year_of_birth='1990',gender_concept_id='0',race_concept_id='0',ethnicity_concept_id='0'))
    events=[]
    # Multiple concepts/events in the same month and year for one person prove
    # that domain ALL people must be counted directly, never summed by concept.
    rows=[('1','100','2020-01-10','2'),('1','101','2020-01-11','4'),('1','100','2020-02-10','8'),
          ('2','100','2020-01-16','0'),('2','100','2020-01-25','-1'),('3','100',None,None),
          (None,'0',None,'NaN'),('99',None,'2021-01-01','Infinity'),('4','999','2020-03-01','1.25'),
          ('5','200','2020-02-29','9007199254740993.125'),('6','100','2020-01-01','0.125'),
          ('7','101','2020-02-01','2.5'),('1','100','2020-01-10','2'),('9007199254740993','100','2020-12-31',None)]
    for i,(pid,concept,day,value) in enumerate(rows):
        events.append(dict(person_id=pid,concept=concept,date=day,end=day if i%3 else '2020-02-01',id=str(i if i!=12 else 0),
            source=None if i%3==0 else str(i%2),text=[None,' ','\t','restricted text'][i%4],type=None if i%3==0 else str(i%2),
            value=value,unit=[None,'0','999','201','200'][i%5],coded=[None,'0','200'][i%3],qualifier=str(i%3),
            string=None if i%2 else 'private string',source_value=' ' if i%2 else 'private value',value_date=None if i%2 else '2020-01-01',
            start_datetime=None if i%3 else '2020-01-12 00:00:00',end_datetime=None if i%2 else '2020-01-13 00:00:00'))
    # An allowed known-unit stratum with no eligible values must survive as n=0.
    events += [dict(events[0],id='90',concept='102',unit='200',value=None),
               dict(events[0],id='91',concept='100',unit='200',value='-1.5'),
               dict(events[0],id='92',concept='100',unit='200',value='0.5')]
    if compact_calendar:
        for interval in pop['observation_period']:
            if interval['observation_period_end_date']=='2020-12-31':interval['observation_period_end_date']='2020-03-31'
        for event in events:
            old=event['date']
            if event['person_id']=='99':event['date']='2020-04-01'
            elif event['date']=='2020-12-31':event['date']='2020-03-31'
            if event['end']==old:event['end']=event['date']
    return dict(id='adversarial',person=pop['person'],observation_period=pop['observation_period'],events=events)


def physical(case, version):
    tables={};columns=defaultdict(dict)
    for m in METRICS:
        for probe in m['inputs']+m['conditional_inputs']:
            table,col=probe.split('.')
            if table in ['person','observation_period']: continue
            typ=('timestamp' if col.endswith('_datetime') else 'date' if col.endswith('_date') else
                 'text' if col in ['domain_id','value_as_string','value_source_value'] or col.endswith('source_value') else
                 'numeric' if col in ['quantity','value_as_number'] else 'bigint')
            columns[table][col]=typ
    if version!='5.5':
        for t,c in [('observation','value_as_date'),('specimen','visit_occurrence_id'),('specimen','visit_detail_id')]: columns[t].pop(c,None)
    if version=='5.3':
        for t,c in [('observation','value_source_value'),('procedure_occurrence','procedure_end_date'),('procedure_occurrence','procedure_end_datetime'),('device_exposure','unit_concept_id'),('device_exposure','unit_source_value'),('device_exposure','unit_source_concept_id')]: columns[t].pop(c,None)
        for canonical,old in [('admitted_from_concept_id','admitting_source_concept_id'),('discharged_to_concept_id','discharge_to_concept_id')]:
            columns['visit_occurrence'][old]=columns['visit_occurrence'].pop(canonical)
    tables['concept']=[dict(concept_id='100',domain_id='Condition'),dict(concept_id='100',domain_id='Condition'),dict(concept_id='101',domain_id='Condition'),dict(concept_id='102',domain_id='Condition'),dict(concept_id='200',domain_id='Unit'),dict(concept_id='201',domain_id='Drug')]
    tables['care_site']=[dict(care_site_id='1',place_of_service_concept_id='0')]
    tables['measurement']=[dict(person_id='10'),dict(person_id='10'),dict(person_id='99')]
    for domain in DOMAINS:
        d=PROFILE['domains'][domain];result=[]
        for e in case['events']:
            r=dict.fromkeys(columns[d['table']]);r.update(person_id=e['person_id']);r[d['concept']]=e['concept'];r[d['event_date']]=e['date'];r[d['type_concept']]=e['type'];r[d['source_text']]=e['text']
            if d['source_concept']:r[d['source_concept']]=e['source']
            if d['record_id']:r[d['record_id']]=e['id']
            if d['end_date'] in r:r[d['end_date']]=e['end']
            if domain=='condition':r['condition_status_concept_id']=e['coded']
            if domain=='drug':r.update(days_supply=None if e['value'] in [None,'NaN','Infinity'] else str(int(Decimal(e['value']))),refills='0',quantity=e['value'])
            if domain=='visit':
                r.update(care_site_id='1' if e['id'] in ['0','1'] else '999')
                for col in r:
                    if col in ['admitted_from_concept_id','admitting_source_concept_id']:r[col]=e['coded']
                    if col in ['discharged_to_concept_id','discharge_to_concept_id']:r[col]=e['unit']
            if domain=='procedure':
                r['procedure_datetime']=e['start_datetime']
                if 'procedure_end_datetime' in r:r['procedure_end_datetime']=e['end_datetime']
            if domain in ['device','specimen']:r['quantity']=e['value']
            if 'unit_concept_id' in r:r['unit_concept_id']=e['unit']
            if domain=='device' and 'unit_source_value' in r:r.update(unit_source_value=e['text'],unit_source_concept_id=e['source'])
            if domain=='specimen':
                r.update(anatomic_site_concept_id=e['coded'],disease_status_concept_id=e['unit'])
                if 'visit_occurrence_id' in r:r.update(visit_occurrence_id='123' if e['id']=='0' else None,visit_detail_id=None)
            if domain=='observation':
                r.update(value_as_number=e['value'],value_as_concept_id=e['coded'],value_as_string=e['string'],qualifier_concept_id=e['qualifier'])
                if 'value_source_value' in r:r['value_source_value']=e['source_value']
                if 'value_as_date' in r:r['value_as_date']=e['value_date']
            result.append(r)
        tables[d['table']]=result
    columns['person']={k:'bigint' for k in ['person_id','year_of_birth','gender_concept_id','race_concept_id','ethnicity_concept_id']}
    columns['observation_period']={k:('date' if k.endswith('_date') else 'bigint') for k in ['person_id','observation_period_start_date','observation_period_end_date','period_type_concept_id']}
    tables['person']=case['person'];tables['observation_period']=case['observation_period']
    if not case['events']: tables['measurement']=[]
    return dict(columns=dict(columns),tables=tables)


def oracle(case,version):
    # Build observation membership independently as day sets, not SQL islands.
    people={p['person_id']:p for p in case['person']};days=defaultdict(set)
    from datetime import timedelta
    for o in case['observation_period']:
        pid,lo,hi=o['person_id'],o['observation_period_start_date'],o['observation_period_end_date']
        if pid not in people or not lo or not hi or lo>hi:continue
        lo,hi=date.fromisoformat(lo),date.fromisoformat(hi)
        days[pid].update(lo+timedelta(days=i) for i in range((hi-lo).days+1))
    dates=[date.fromisoformat(e['date']) for e in case['events'] if e['date']]+[d for s in days.values() for d in s]
    scopes=[('full_scope',None,None,False)]
    if dates:
        for kind,lo,hi,_ in periods(date(min(dates).year,1,1),date(max(dates).year,12,31)):
            if kind=='calendar_year' or (kind=='calendar_month' and (lo.year,lo.month)>=(min(dates).year,min(dates).month) and (lo.year,lo.month)<=(max(dates).year,max(dates).month)):scopes.append((kind,lo,hi,True))
    output={m['id']:{} for m in METRICS}
    def put(mid,dims,values):
        key=canon(dims)
        assert key not in output[mid],(mid,dims)
        output[mid][key]=values
    def grouped(mid,rows,dim,person=True):
        groups=defaultdict(list)
        for e in rows:groups[canon(dim(e))].append(e)
        for dims,es in groups.items():
            v={'record_count':str(len(es))}
            if person:v['person_count']=str(len({e['person_id'] for e in es if e['person_id'] in people}))
            put(mid,json.loads(dims),v)
    def summary(mid,groups,reasons,measure):
        for dims,samples in groups.items():
            good=sorted(v for reason,v in samples if reason=='eligible');n=len(good);s=dec(sum(good)) if n else None
            vals=dict(n=str(n),sum=s,mean_numerator=s,mean_denominator=str(n) if n else None,min=dec(good[0]) if n else None,max=dec(good[-1]) if n else None)
            for name,num,den in [('p10',1,10),('p25',1,4),('p50',1,2),('p75',3,4),('p90',9,10)]:vals[name]=dec(good[(n*num+den-1)//den-1]) if n else None
            put(mid,json.loads(dims),vals)
            for reason in reasons:put(mid,dict(json.loads(dims),eligibility_reason=reason),{measure:str(sum(r==reason for r,v in samples))})
    def scalar(mid,rows,dim,key):
        groups=defaultdict(list)
        for e in rows:
            v=None if e[key] is None else Decimal(e[key]);reason='value_missing' if v is None else 'value_non_finite' if not v.is_finite() else 'value_negative' if v<0 else 'eligible'
            groups[canon(dim(e))].append((reason,v))
        summary(mid,groups,REASONS['nonnegative_scalar_order'],'record_count')
    model=physical(case,version)
    density=Counter()
    for domain in DOMAINS:
        core='core.'+domain+'.';observed='observed.'+domain+'.';d=PROFILE['domains'][domain];rows=[]
        for e,r in zip(case['events'],model['tables'][d['table']]):
            x=dict(e);x['record']=r
            x['observed']=e['person_id'] in people and e['date'] is not None and date.fromisoformat(e['date']) in days[e['person_id']]
            x['qualification']='null_or_orphan_person' if e['person_id'] not in people else 'undated' if e['date'] is None else 'no_valid_intervals' if not days[e['person_id']] else 'inside_valid_union' if x['observed'] else 'outside_valid_union'
            rows.append(x)
        concepts={e['concept'] for e in rows}
        for concept in [*concepts,'ALL']:
            es=[e for e in rows if concept=='ALL' or e['concept']==concept];ct={'kind':'all'} if concept=='ALL' else tag(concept)
            for kind,lo,hi,_ in scopes+[('undated',None,None,False)]:
                subset=[e for e in es if kind=='full_scope' or (kind=='undated' and e['date'] is None) or (kind.startswith('calendar') and e['date'] and lo<=date.fromisoformat(e['date'])<=hi)]
                dims=dict(concept_tag=ct,period_kind=kind,period_start=day_text(lo) if lo else 'null',period_end=day_text(hi) if hi else 'null')
                put(core+'capture_count',dims,dict(record_count=str(len(subset)),person_count=str(len({e['person_id'] for e in subset if e['person_id'] in people}))))
                if kind!='undated':
                    valid=[e for e in subset if e['observed']];put(observed+'capture_count',dims,dict(record_count=str(len(valid)),person_count=str(len({e['person_id'] for e in valid}))))
        grouped(core+'source_count',rows,lambda e:dict(concept_tag=tag(e['concept']),source_concept_tag={'kind':'schema_absent'} if domain=='specimen' else tag(e['source']),source_value_state='null' if e['text'] is None else 'blank' if e['text'].strip(' ')=='' else 'nonblank'))
        grouped(core+'type_count',rows,lambda e:dict(concept_tag=tag(e['concept']),type_concept_tag=tag(e['type'])))
        grouped(core+'observation_qualification_count',rows,lambda e:dict(concept_tag=tag(e['concept']),reason=e['qualification']))
        linked=[e for e in rows if e['person_id'] in people]
        first=defaultdict(list)
        for e in linked:first[(e['concept'],e['person_id'])].append(e)
        ages=defaultdict(list)
        for (concept,pid),es in first.items():
            ds=[date.fromisoformat(e['date']) for e in es if e['date']];birth=people[pid]['year_of_birth'];age=min(ds).year-int(birth) if ds and birth is not None else None
            reason='event_date_missing_or_invalid' if not ds else 'birth_year_missing_or_invalid' if birth is None or not 1<=int(birth)<=9999 else 'year_age_outside_0_130' if not 0<=age<=130 else 'eligible'
            ages[canon(dict(concept_tag=tag(concept),gender_concept_id=people[pid]['gender_concept_id'] or 'null'))].append((reason,Decimal(age) if reason=='eligible' else None))
        summary(core+'first_age_summary',ages,REASONS['age_order'],'person_count')
        for concept in concepts:
            counts=Counter(e['person_id'] for e in linked if e['concept']==concept);hist=Counter(counts.values());hist[0]=len(people)-len(counts)
            for n,total in hist.items():put(core+'frequency_histogram',dict(concept_tag=tag(concept),event_count=str(n)),dict(person_count=str(total)))
        hist=Counter(len({e['concept'] for e in linked if e['person_id']==pid and e['concept'] is not None}) for pid in people)
        for n,total in hist.items():put(core+'distinct_concepts_histogram',dict(concept_count=str(n)),dict(person_count=str(total)))
        duplicates=Counter(e['person_id'] if domain=='death' else e['id'] for e in rows)
        vocab={'100':'Condition','101':'Condition','102':'Condition','200':'Unit','201':'Drug'}
        flags=dict(null_person=lambda e:e['person_id'] is None,orphan_person=lambda e:e['person_id'] is not None and e['person_id'] not in people,missing_date=lambda e:e['date'] is None,invalid_date=lambda e:False,null_concept=lambda e:e['concept'] is None,zero_concept=lambda e:e['concept']=='0',unknown_concept=lambda e:e['concept'] not in [None,'0'] and e['concept'] not in vocab,wrong_domain_concept=lambda e:e['concept'] not in [None,'0'] and e['concept'] in vocab and vocab[e['concept']] not in d['expected_concept_domains'])
        if d['end_date'] and not(domain=='procedure' and version=='5.3'):flags.update(missing_end=lambda e:e['end'] is None,reversed_end=lambda e:e['date'] is not None and e['end'] is not None and e['end']<e['date'])
        flags['repeated_person_rows' if domain=='death' else 'duplicate_record_id']=lambda e:(e['person_id'] if domain=='death' else e['id']) is not None and duplicates[e['person_id'] if domain=='death' else e['id']]>1
        for flag,pred in flags.items():
            for present in [False,True]:put(core+'integrity_count',dict(flag=flag,present=str(present).lower()),dict(record_count=str(sum(pred(e)==present for e in rows))))
        years=defaultdict(set)
        for e in linked:
            if not e['observed']:continue
            year=int(e['date'][:4]);p=people[e['person_id']];birth=p['year_of_birth'];age=year-int(birth) if birth is not None else None
            dims=dict(year=str(year),gender_concept_id=p['gender_concept_id'] or 'null',year_age_decile=str(age//10) if birth is not None and 1<=int(birth)<=9999 and 0<=age<=130 else 'unknown')
            for ct in [tag(e['concept']),{'kind':'all'}]:years[canon(dict(dims,concept_tag=ct))].add(e['person_id'])
        for dims,pids in years.items():put(observed+'year_gender_age_count',json.loads(dims),dict(person_count=str(len(pids))))
        cdim=lambda e:dict(concept_tag=tag(e['concept']))
        if domain=='condition':grouped(core+'status_type_count',rows,lambda e:dict(cdim(e),status_concept_tag=tag(e['coded']),type_concept_tag=tag(e['type'])))
        if domain=='drug':
            for key in ['days_supply','refills','quantity']:
                adapted=[dict(e,scalar=e['record'][key]) for e in rows];scalar(core+key+'_summary',adapted,cdim,'scalar')
        if domain=='visit':
            samples=defaultdict(list)
            for e in rows:
                reason='start_missing_or_invalid' if not e['date'] else 'end_missing_or_invalid' if not e['end'] else 'end_before_start' if e['end']<e['date'] else 'eligible'
                samples[canon(cdim(e))].append((reason,Decimal((date.fromisoformat(e['end'])-date.fromisoformat(e['date'])).days) if reason=='eligible' else None))
            summary(core+'duration_summary',samples,REASONS['elapsed_duration_order'],'record_count')
            for kind in ['visit','admitted_from','discharged_to','place_of_service']:
                grouped(core+'care_setting_count',rows,lambda e:dict(cdim(e),setting_kind=kind,setting_concept_tag=tag(e['concept'] if kind=='visit' else e['coded'] if kind=='admitted_from' else e['unit'] if kind=='discharged_to' else '0' if e['record']['care_site_id']=='1' else None)))
        if domain=='procedure' and version!='5.3':
            expanded=[]
            for e in rows:
                start=e['date'];sd=e['start_datetime'];end=e['end'];ed=e['end_datetime']
                for prefix,a,b in [('start',start,sd),('end',end,ed)]:expanded.append(dict(e,reason=prefix+('_date_and_datetime' if a and b else '_date_only' if a else '_datetime_only' if b else '_absent')))
                for reason,test in [('missing_duration',not start or not end),('negative_duration',start and end and end<start),('start_disagreement',start and sd and start!=sd[:10]),('end_disagreement',end and ed and end!=ed[:10])]:
                    if test:expanded.append(dict(e,reason=reason))
            grouped(core+'end_precision_count',expanded,lambda e:dict(cdim(e),reason=e['reason']))
        if domain in ['device','specimen']:
            unitdim=lambda e:dict(cdim(e),unit_concept_tag={'kind':'schema_absent'} if domain=='device' and version=='5.3' else tag(e['unit']))
            scalar(core+'quantity_summary',rows,unitdim,'value')
        if domain=='device' and version!='5.3':grouped(core+'unit_count',rows,lambda e:dict(cdim(e),unit_concept_tag=tag(e['unit']),source_unit_presence='null' if e['text'] is None else 'blank' if e['text'].strip(' ')=='' else 'nonblank'))
        if domain=='specimen':
            for kind,key in [('anatomic_site','coded'),('disease_status','unit')]:grouped(core+'site_status_count',rows,lambda e:dict(cdim(e),dimension_kind=kind,dimension_concept_tag=tag(e[key])))
            if version=='5.5':
                for kind in ['visit_occurrence','visit_detail']:grouped(core+'visit_link_presence_count',rows,lambda e:dict(cdim(e),link_kind=kind,present=str(kind=='visit_occurrence' and e['id']=='0').lower()))
        if domain=='observation':
            for suffix,key,label in [('unit_count','unit','unit_concept_tag'),('coded_value_count','coded','value_concept_tag'),('qualifier_count','qualifier','qualifier_concept_tag')]:grouped(core+suffix,rows,lambda e:dict(cdim(e),**{label:tag(e[key])}))
            def numreason(e):
                v=e['value'];unit=e['unit']
                return 'numeric_missing' if v is None else 'numeric_non_finite' if not Decimal(v).is_finite() else 'unit_null' if unit is None else 'unit_zero' if unit=='0' else 'unit_unrecognized' if unit!='200' else 'eligible'
            grouped(core+'numeric_eligibility_count',rows,lambda e:dict(cdim(e),reason=numreason(e)),False)
            groups=defaultdict(list)
            for e in rows:
                if e['unit']=='200':groups[canon(dict(cdim(e),unit_concept_tag=tag(e['unit'])))].append((numreason(e),Decimal(e['value']) if e['value'] is not None else None))
            summary(core+'numeric_summary',groups,[r for r in REASONS['numeric_summary_order'] if r!='operator_explicit_measurement_only'],'record_count')
            from itertools import product
            for concept in concepts:
                byflags=defaultdict(list)
                for e in rows:
                    if e['concept']!=concept:continue
                    flags=str(int(e['value'] is not None))+str(int(e['coded'] not in [None,'0']))+('X' if version=='5.3' else str(int(e['source_value'] is not None and bool(e['source_value'].strip(' ')))))+str(int(e['string'] is not None and bool(e['string'].strip(' '))))+('X' if version!='5.5' else str(int(e['value_date'] is not None)))
                    byflags[flags].append(e)
                for bits in product('01','01','X' if version=='5.3' else '01','01','01' if version=='5.5' else 'X'):
                    flags=''.join(bits);es=byflags[flags];put(core+'representation_count',dict(concept_tag=tag(concept),representation_flags=flags),dict(record_count=str(len(es)),person_count=str(len({e['person_id'] for e in es if e['person_id'] in people}))))
    for pid in people:
        bit='1' if any(e['person_id']==pid for e in case['events']) else '0'
        density[bit*8+('1' if case['events'] and pid=='10' else '0')]+=1
    for bits,n in density.items():put('core.density.domain_presence_count',dict(presence_bits=bits),dict(person_count=str(n)))
    dh=Counter()
    for bits,n in density.items():dh[bits.count('1')]+=n
    for n,total in dh.items():put('core.density.domain_count',dict(domain_count=str(n)),dict(person_count=str(total)))
    return output


def dataset_state(mid, case, version):
    domain=mid.split('.')[1]
    probes={'core.procedure.end_precision_count':('procedure_occurrence',['procedure_end_date','procedure_end_datetime'],'capability.procedure_end_absent'),
            'core.device.unit_count':('device_exposure',['unit_concept_id','unit_source_value','unit_source_concept_id'],'capability.device_unit_absent'),
            'core.specimen.visit_link_presence_count':('specimen',['visit_occurrence_id','visit_detail_id'],'capability.specimen_links_absent')}
    if mid in probes:
        table,columns,reason=probes[mid]
        if not set(columns)<=physical(case,version)['columns'][table].keys():return 'unsupported',reason
    base=len(case['person']) if domain=='density' else len(case['events'])
    state,reason=('computed',None) if base else ('empty_source','source.empty')
    if mid.endswith('.distinct_concepts_histogram') and case['person']:state,reason='computed',None
    if mid.startswith('observed.') and base:
        people={p['person_id'] for p in case['person']}
        inside=any(e['person_id'] in people and e['date'] and any(o['person_id']==e['person_id'] and o['observation_period_start_date'] and o['observation_period_end_date'] and o['observation_period_start_date']<=e['date']<=o['observation_period_end_date'] for o in case['observation_period']) for e in case['events'])
        if not inside:state,reason='empty_population','population.no_qualifying_events'
    return state,reason


def cell(values,state,reason):
    kind='summary' if values is not None and 'n' in values else 'counts'
    if kind=='summary' and values['n']=='0':state,reason='empty_population','summary.no_eligible'
    return dict(values=values,state=state,reason_code=reason)


def population_expected(case, domain_expected):
    from test_population_baseline import oracle as population_oracle
    from datetime import timedelta
    base,states=population_oracle(dict(case,window=None));people={p['person_id'] for p in case['person']};days=defaultdict(set)
    for o in case['observation_period']:
        pid,lo,hi=o['person_id'],o['observation_period_start_date'],o['observation_period_end_date']
        if pid not in people or not lo or not hi or lo>hi:continue
        lo,hi=date.fromisoformat(lo),date.fromisoformat(hi)
        days[pid].update(lo+timedelta(days=i) for i in range((hi-lo).days+1))
    all_days=set().union(*days.values()) if days else set()
    # B-05's 19 outputs are retained. Canonical coverage/continuity targets are
    # additional scopes, not a replacement for clipped observation-bound scopes.
    for dims in domain_expected['core.condition.capture_count']:
        d=json.loads(dims)
        if d['concept_tag']['kind']!='all' or d['period_kind']=='undated':continue
        d.pop('concept_tag');lo=date.fromisoformat(d['period_start']) if d['period_start']!='null' else None;hi=date.fromisoformat(d['period_end']) if d['period_end']!='null' else None
        bounded=[{day for day in ds if lo is None or lo<=day<=hi} for ds in days.values()]
        scope_lo,scope_hi=(lo,hi) if lo else (min(all_days),max(all_days)) if all_days else (None,None)
        continuous=sum(len(ds)==(scope_hi-scope_lo).days+1 for ds in bounded) if scope_lo else 0
        values=[('core.observation_period.coverage_count',d,dict(person_count=str(sum(bool(ds) for ds in bounded)),person_days=str(sum(map(len,bounded))))),
                ('core.observation_period.continuous_person_count',dict(d,full_calendar_period=str(d['period_kind']!='full_scope').lower()),dict(person_count=str(continuous)))]
        for mid,dimensions,v in values:
            state,reason=states[mid];row=dict(dimensions=dimensions,row_kind='counts',values=v,state=state,reason_code=reason,denominator_refs=[])
            if not any(r['dimensions']==dimensions for r in base[mid]):base[mid].append(row)
    return base,states


def verify_snapshot(snap, case):
    expected=oracle(case,snap['version']);checked=0
    for mid,want in expected.items():
        state,reason=dataset_state(mid,case,snap['version'])
        metadata=snap['context']['inventory'][mid]
        assert (metadata['state'],metadata['reason_code'],metadata['rows'])==(state,reason,str(len(want))),(snap['case'],snap['version'],mid,metadata,state,reason)
        actual=snap['rows'].get(mid,[])
        got={canon(r['dimensions']):{k:r[k] for k in ['values','state','reason_code']} for r in actual}
        assert len(got)==len(actual),(mid,'duplicate dimensions')
        wanted={key:cell(value,state,reason) for key,value in want.items()}
        if got!=wanted:
            for key in set(got)|set(wanted):
                if got.get(key)!=wanted.get(key):raise AssertionError((snap['case'],snap['version'],mid,key,got.get(key),wanted.get(key)))
        checked+=len(want)
    population,states=population_expected(case,expected)
    for mid,rows in population.items():
        wanted=sorted(canon(r) for r in rows)
        actual=sorted(canon({k:v for k,v in r.items() if k!='row_key'}) for r in snap['rows'][mid])
        assert actual==wanted,(snap['case'],snap['version'],mid,'population values/scopes/states changed')
        meta=snap['context']['inventory'][mid]
        assert (meta['state'],meta['reason_code'],meta['rows'])==(*states[mid],str(len(rows)))
    return checked


def verify_care(case, rows, reason):
    expected=oracle(case,'5.5')['core.visit.care_setting_count'];wanted={}
    for dims,value in expected.items():
        d=json.loads(dims)
        if d['setting_kind']=='place_of_service':
            d['setting_concept_tag']={'kind':'schema_absent'}
            wanted[canon(d)]=cell(None,'unsupported' if reason=='capability.care_site_absent' else 'unavailable',reason)
        else:wanted[dims]=cell(value,'computed',None)
    got={canon(r['dimensions']):{k:r[k] for k in ['values','state','reason_code']} for r in rows}
    assert len(got)==len(rows) and got==wanted,('CARE_SITE availability/state mismatch',reason)


def create_evidence_dir(path, root=ROOT):
    resolved=path.resolve()
    if path.is_symlink() or resolved.exists() or resolved.is_relative_to(root.resolve()):
        raise ValueError('Use a new evidence directory outside the checkout')
    resolved.mkdir(parents=True,mode=0o700)
    return resolved


def compare_legacy(report, legacy):
    snap=next(x for x in report['snapshots'] if x['case']=='adversarial' and x['version']=='5.5')
    checked=0
    for domain, rows in legacy['counts'].items():
        want={canon(tag(r['concept'])):r['person_count'] for r in rows}
        got={canon(r['dimensions']['concept_tag']):r['values']['person_count'] for r in snap['rows']['observed.'+domain+'.capture_count'] if r['dimensions']['period_kind']=='full_scope' and r['dimensions']['concept_tag']['kind']!='all' and r['values']['person_count']!='0'}
        assert got==want,(domain,got,want)
        checked+=len(want)
    return dict(domains=len(legacy['counts']),cells=checked,status='passed',scope=legacy['lock']['scope'])


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--compact-calendar',action='store_true',help='Use a shorter synthetic calendar; all reports, schema variants and edge categories still run');p.add_argument('--legacy',action='store_true',help='Also verify installed pinned Achilles/SqlRender distinct-person subset');p.add_argument('--config',type=Path,required=True);p.add_argument('--output-dir',type=Path,required=True);a=p.parse_args()
    try:a.output_dir=create_evidence_dir(a.output_dir)
    except ValueError as error:p.error(str(error))
    case=make_fixture(compact_calendar=a.compact_calendar);empty=dict(id='empty',person=case['person'],observation_period=[],events=[]);all_empty=dict(id='empty_source',person=[],observation_period=[],events=[])
    unobserved=dict(case,id='unobserved',observation_period=[])
    inputs=[dict(case=c['id'],version=v,**physical(c,v)) for c in [case,empty,all_empty] for v in ['5.3','5.4','5.5']]
    inputs.append(dict(case=unobserved['id'],version='5.5',**physical(unobserved,'5.5')))
    (a.output_dir/'input.json').write_text(json.dumps(inputs))
    subprocess.run(['Rscript','--vanilla',str(ROOT/'tests/tracer/domain-baseline.R'),str(a.config.resolve()),str(a.output_dir.resolve())],cwd=ROOT,check=True)
    report=json.loads((a.output_dir/'report.json').read_text());checked=0
    assert len(report['snapshots'])==len(inputs)
    assert {(x['case'],x['version']) for x in report['snapshots']}=={(x['case'],x['version']) for x in inputs}
    cases={c['id']:c for c in [case,empty,all_empty,unobserved]}
    for snap in report['snapshots']:
        checked+=verify_snapshot(snap,cases[snap['case']])
    for care in report['care_cases']:verify_care(case,care['rows'],care['reason'])
    if a.legacy:
        subprocess.run(['Rscript','--vanilla',str(ROOT/'tests/tracer/domain-legacy.R'),str(a.config.resolve()),str(a.output_dir.resolve()/'input.json'),str(a.output_dir.resolve())],cwd=ROOT,check=True)
        legacy_result=compare_legacy(report,json.loads((a.output_dir/'legacy.json').read_text()))
        (a.output_dir/'legacy-parity.json').write_text(json.dumps(legacy_result,indent=2)+'\n')
    print(f'PASS: independent exact oracle for 100 domain/density outputs, {len(inputs)} schema/data cases, {checked} rows')
    (a.output_dir/'oracle.json').write_text(json.dumps(dict(metrics=100,cases=len(inputs),rows=checked,fixture_calendar='compact' if a.compact_calendar else 'wide',verified_population_metrics=19,cell_states_and_reasons='passed',care_availability_cases=len(report['care_cases']),status='passed'),indent=2)+'\n')

if __name__=='__main__':main()
