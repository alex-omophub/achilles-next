"""Independent per-output PostgreSQL reference compiler for the frozen core profile.

Contributor tooling, not an installed engine. No production report/classification
SQL is imported. Each output rereads sources; range aggregation replaces islands,
and individual eligible rows (never value frequencies) supply exact ranks.
"""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT/'inst/analysis/core-characterization-v2.json'
PROFILE = json.loads(PROFILE_PATH.read_bytes())
DOMAINS = ('condition','drug','procedure','visit','device','observation','death','specimen','measurement')
METADATA = ('core.source.passport','core.source.capabilities','core.execution.output_status','core.execution.timing')


def ident(value):
    if not isinstance(value,str) or not re.fullmatch('[a-z][a-z0-9_]{0,62}',value):
        raise ValueError('Invalid reference identifier')
    return '"'+value+'"'


def lit(value):
    return "'"+value.replace("'","''")+"'"


def obj(**fields):
    return 'jsonb_build_object('+','.join(lit(k)+','+v for k,v in fields.items())+')' if fields else "'{}'::jsonb"


def tag(expr):
    return f"CASE WHEN {expr} IS NULL THEN jsonb_build_object('kind','null') ELSE jsonb_build_object('kind','id','value',({expr})::text) END"


def text(expr,missing='null'):
    return f'COALESCE(({expr})::text,{lit(missing)})'


def finite(expr):
    return f"({expr} IS NOT NULL AND ({expr})::text NOT IN ('NaN','Infinity','-Infinity'))"


def valid_date(expr):
    return f"(({expr}) BETWEEN DATE '0001-01-01' AND DATE '9999-12-31') IS TRUE"


def grouped(source,dimensions,values):
    return f"SELECT 'counts'::text AS row_kind,dimensions,{obj(**values)} AS values FROM (SELECT *,{dimensions} AS dimensions FROM {source}) q GROUP BY dimensions"


def count_rows(source,dimensions,persons=True):
    values={'record_count':'count(*)::text'}
    if persons:values['person_count']='count(DISTINCT person_id) FILTER(WHERE linked)::text'
    return grouped(source,dimensions,values)


def summary(samples,reasons,measure='record_count',extra=None):
    categories=','.join('('+lit(r)+')' for r in reasons)
    values=dict(n='n::text',sum='total::text',mean_numerator='total::text',mean_denominator='CASE WHEN n>0 THEN n::text END',
                min='minimum::text',max='maximum::text')
    for k,num,den in [('p10',1,10),('p25',1,4),('p50',1,2),('p75',3,4),('p90',9,10)]:
        values[k]=f'max(value) FILTER(WHERE rank=div(n*{num}+{den-1},{den}))::text'
    sql=f"""WITH samples AS ({samples}), strata AS (
        SELECT dimensions,count(*) FILTER(WHERE reason='eligible')::numeric AS n,
               sum(value) FILTER(WHERE reason='eligible') AS total FROM samples GROUP BY dimensions
      ), ranked AS (
        SELECT dimensions,value,row_number() OVER(PARTITION BY dimensions ORDER BY value)::numeric AS rank
        FROM samples WHERE reason='eligible'
      ), stats AS (
        SELECT s.dimensions,s.n,s.total,min(r.value) AS minimum,max(r.value) AS maximum
        FROM strata s LEFT JOIN ranked r USING(dimensions) GROUP BY s.dimensions,s.n,s.total
      ) SELECT 'summary'::text AS row_kind,s.dimensions,{obj(**values)} AS values
      FROM stats s LEFT JOIN ranked r USING(dimensions) GROUP BY s.dimensions,n,total,minimum,maximum
      UNION ALL SELECT 'eligibility_counts',s.dimensions||jsonb_build_object('eligibility_reason',c.reason),
        jsonb_build_object({lit(measure)},count(v.reason)::text)
      FROM strata s CROSS JOIN (VALUES {categories}) c(reason)
      LEFT JOIN samples v ON v.dimensions=s.dimensions AND v.reason=c.reason GROUP BY s.dimensions,c.reason"""
    if extra:sql=f'SELECT * FROM ({sql}) summaries UNION ALL {extra}'
    return sql


class Reference:
    def __init__(self,schema,columns,denied_tables=()):
        self.schema=ident(schema)
        self.columns=columns
        self.care_reason=('capability.care_site_absent' if any(c not in columns.get('care_site',{}) for c in ['care_site_id','place_of_service_concept_id']) else 'capability.care_site_denied' if 'care_site' in denied_tables else None)
        for table,cols in columns.items():
            ident(table)
            for col in cols:ident(col)
        profile_hash=hashlib.sha256(PROFILE_PATH.read_bytes()).hexdigest()
        if profile_hash!=json.loads((ROOT/'inst/contracts/v2/rows.json').read_bytes())['profile_sha256']:
            raise ValueError('Reference requires the pinned core profile')
        self.ids=[m['id'] for m in PROFILE['metrics']]
        if len(self.ids)!=142 or len(set(self.ids))!=142:raise ValueError('Incomplete reference profile')

    def table(self,name):return self.schema+'.'+ident(name)

    def col(self,domain,name,default='NULL::bigint'):
        if name is None:return default
        table=PROFILE['domains'][domain]['table']
        choices={'admitted_from_concept_id':['admitted_from_concept_id','admitting_source_concept_id'],
                 'discharged_to_concept_id':['discharged_to_concept_id','discharge_to_concept_id']}.get(name,[name])
        found=['e.'+ident(c) for c in choices if c in self.columns.get(table,{})]
        return ('COALESCE('+','.join(found)+')' if len(found)>1 else found[0]) if found else default

    def supported(self,mid):
        needs={'core.procedure.end_precision_count':('procedure_occurrence',['procedure_end_date','procedure_end_datetime'],'capability.procedure_end_absent'),
               'core.device.unit_count':('device_exposure',['unit_concept_id','unit_source_value','unit_source_concept_id'],'capability.device_unit_absent'),
               'core.specimen.visit_link_presence_count':('specimen',['visit_occurrence_id','visit_detail_id'],'capability.specimen_links_absent')}
        if mid in needs:
            table,cols,reason=needs[mid]
            if any(c not in self.columns.get(table,{}) for c in cols):return reason
        return None

    def common(self):
        # PostgreSQL multirange union is independent of the producer's ordered
        # MAX/island implementation; adjacent and overlapping ranges coalesce.
        p=self.table('person');o=self.table('observation_period')
        dates=' UNION ALL '.join(f'SELECT {ident(d["event_date"])} AS day FROM {self.table(d["table"])} WHERE {valid_date(ident(d["event_date"]))}' for d in PROFILE['domains'].values())
        return f"""people AS (SELECT person_id,year_of_birth,gender_concept_id,race_concept_id,ethnicity_concept_id FROM {p}), raw AS (
          SELECT o.person_id,observation_period_start_date AS lo,observation_period_end_date AS hi,period_type_concept_id,
            CASE WHEN o.person_id IS NULL THEN 'null_person' WHEN NOT EXISTS(SELECT FROM people p WHERE p.person_id=o.person_id) THEN 'orphan_person'
            WHEN observation_period_start_date IS NULL OR observation_period_end_date IS NULL THEN 'null_endpoints'
            WHEN observation_period_start_date>observation_period_end_date THEN 'reversed_interval' ELSE 'valid' END AS reason FROM {o} o
        ), multiranges AS (SELECT person_id,range_agg(daterange(lo,hi,'[]')) AS spans FROM raw WHERE reason='valid' GROUP BY person_id),
        unions AS (SELECT person_id,lower(span) AS lo,upper(span)-1 AS hi FROM multiranges CROSS JOIN LATERAL unnest(spans) span),
        person_stats AS (
          SELECT p.*,count(u.lo)::numeric AS intervals,COALESCE(sum((u.hi-u.lo+1)::numeric),0) AS total_days,min(u.lo) AS first_start,
            (SELECT hi FROM unions x WHERE x.person_id=p.person_id ORDER BY lo LIMIT 1) AS first_end
          FROM people p LEFT JOIN unions u USING(person_id) GROUP BY p.person_id,p.year_of_birth,p.gender_concept_id,p.race_concept_id,p.ethnicity_concept_id
        ), population_bounds AS (SELECT min(lo) AS lo,max(hi) AS hi FROM unions),
        all_dates AS (SELECT lo AS day FROM unions UNION ALL SELECT hi FROM unions UNION ALL {dates}),
        domain_bounds AS (SELECT min(day) AS lo,max(day) AS hi FROM all_dates),
        pop_periods AS ({self.periods('population_bounds',True)}),
        periods AS ({self.periods('domain_bounds',False)})"""

    @staticmethod
    def periods(bounds,clipped):
        full='lo,hi' if clipped else 'NULL::date,NULL::date'
        monthlo="GREATEST(d::date,lo)" if clipped else 'd::date'
        monthhi="LEAST((d+interval '1 month - 1 day')::date,hi)" if clipped else "(d+interval '1 month - 1 day')::date"
        yearlo='GREATEST(d::date,lo)' if clipped else 'd::date'
        yearhi="LEAST((d+interval '1 year - 1 day')::date,hi)" if clipped else "(d+interval '1 year - 1 day')::date"
        monthfull="lo<=d::date AND hi>=(d+interval '1 month - 1 day')::date" if clipped else 'true'
        yearfull="lo<=d::date AND hi>=(d+interval '1 year - 1 day')::date" if clipped else 'true'
        return f"""SELECT 'full_scope'::text AS period_kind,{full},false AS full_calendar_period FROM {bounds}
          UNION ALL SELECT 'calendar_month',{monthlo},{monthhi},{monthfull} FROM {bounds} CROSS JOIN LATERAL generate_series(date_trunc('month',lo),date_trunc('month',hi),interval '1 month') d
          UNION ALL SELECT 'calendar_year',{yearlo},{yearhi},{yearfull} FROM {bounds} CROSS JOIN LATERAL generate_series(date_trunc('year',lo),date_trunc('year',hi),interval '1 year') d""".replace(f"{full},false",f"{full.split(',')[0]} AS lo,{full.split(',')[1]} AS hi,false",1)

    def facts(self,domain):
        d=PROFILE['domains'][domain];c=lambda name,default='NULL::bigint':self.col(domain,name,default)
        concept=c(d['concept']);day=c(d['event_date']);end=c(d['end_date'],'NULL::date')
        rid='e.person_id' if domain=='death' else c(d['record_id'])
        known=f'EXISTS(SELECT FROM {self.table("concept")} v WHERE v.concept_id={concept})'
        right=f'EXISTS(SELECT FROM {self.table("concept")} v WHERE v.concept_id={concept} AND v.domain_id IN ({",".join(lit(s) for s in d["expected_concept_domains"])}))'
        observed=f'EXISTS(SELECT FROM unions u WHERE u.person_id=e.person_id AND {day} BETWEEN u.lo AND u.hi)'
        valid=valid_date(day)
        fields=dict(person_id='e.person_id',concept_id=concept,concept_tag=tag(concept),event_date=day,end_date=end,
                    linked='p.person_id IS NOT NULL',gender_concept_id='p.gender_concept_id',year_of_birth='p.year_of_birth',
                    valid_date=valid,observed=observed,known_concept=known,right_domain=right,
                    duplicated=f'{rid} IS NOT NULL AND {rid} IN (SELECT duplicate_id FROM duplicates)',
                    qualification=f"CASE WHEN p.person_id IS NULL THEN 'null_or_orphan_person' WHEN NOT ({valid}) THEN 'undated' WHEN NOT EXISTS(SELECT FROM unions u WHERE u.person_id=e.person_id) THEN 'no_valid_intervals' WHEN {observed} THEN 'inside_valid_union' ELSE 'outside_valid_union' END",
                    source_tag="jsonb_build_object('kind','schema_absent')" if d['source_concept'] is None else tag(c(d['source_concept'])),
                    source_state=f"CASE WHEN {c(d['source_text'],'NULL::text')} IS NULL THEN 'null' WHEN btrim({c(d['source_text'],'NULL::text')},' ')='' THEN 'blank' ELSE 'nonblank' END",type_tag=tag(c(d['type_concept'])))
        extra_names=['condition_status_concept_id','days_supply','refills','quantity','care_site_id','value_as_number','value_as_concept_id','unit_concept_id','operator_concept_id','range_low','range_high','qualifier_concept_id','anatomic_site_concept_id','disease_status_concept_id','visit_occurrence_id','visit_detail_id']
        for name in extra_names:
            default='NULL::numeric' if name in ['quantity','value_as_number','range_low','range_high'] else 'NULL::bigint'
            fields[name]=c(name,default)
        for name in ['value_source_value','value_as_string','unit_source_value']:fields[name]=c(name,'NULL::text')
        for name in ['procedure_datetime','procedure_end_datetime']:fields[name]=c(name,'NULL::timestamp')
        fields['value_as_date']=c('value_as_date','NULL::date')
        fields['admitted']=c('admitted_from_concept_id');fields['discharged']=c('discharged_to_concept_id')
        fields['known_unit']=f'EXISTS(SELECT FROM {self.table("concept")} v WHERE v.concept_id={c("unit_concept_id")} AND v.concept_id>0 AND v.domain_id=\'Unit\')'
        return f"duplicates AS (SELECT {rid} AS duplicate_id FROM {self.table(d['table'])} e WHERE {rid} IS NOT NULL GROUP BY {rid} HAVING count(*)>1), facts AS (SELECT {','.join(v+' AS '+ident(k) for k,v in fields.items())} FROM {self.table(d['table'])} e LEFT JOIN people p ON p.person_id=e.person_id)"

    def compile(self,mid):
        if mid not in self.ids or mid in METADATA:raise ValueError('Not a numerical reference output')
        if self.supported(mid):return "SELECT NULL::text AS row_kind,NULL::jsonb AS dimensions,NULL::jsonb AS values WHERE false"
        prefix,domain,suffix=mid.split('.')
        if domain=='person':query=self.person(suffix)
        elif domain=='observation_period':query=self.observation(suffix)
        elif domain=='density':query=self.density(suffix)
        else:query=self.domain(domain,suffix,prefix=='observed')
        ctes=self.common()
        if domain in DOMAINS:ctes+=','+self.facts(domain)
        return f'WITH {ctes} SELECT * FROM ({query}) reference_output'

    def person(self,suffix):
        fields={'count':[],'gender_count':['gender_concept_id'],'birth_year_count':['year_of_birth'],'race_count':['race_concept_id'],'ethnicity_count':['ethnicity_concept_id'],'birth_year_gender_count':['year_of_birth','gender_concept_id'],'race_ethnicity_count':['race_concept_id','ethnicity_concept_id']}[suffix]
        if not fields:return "SELECT 'counts'::text AS row_kind,'{}'::jsonb AS dimensions,jsonb_build_object('person_count',count(*)::text) AS values FROM people"
        return grouped('people',obj(**{k:text(k) for k in fields}),dict(person_count='count(*)::text'))

    @staticmethod
    def age_reason(day):
        age=f'(extract(year FROM {day})::numeric-year_of_birth::numeric)'
        reason=f"CASE WHEN {day} IS NULL THEN 'event_date_missing_or_invalid' WHEN year_of_birth IS NULL OR year_of_birth NOT BETWEEN 1 AND 9999 THEN 'birth_year_missing_or_invalid' WHEN {age} NOT BETWEEN 0 AND 130 THEN 'year_age_outside_0_130' ELSE 'eligible' END"
        return age,reason

    def observation(self,suffix):
        age,reason=self.age_reason('first_start');good=f"({reason})='eligible'"
        first=f'(SELECT *,CASE WHEN {good} THEN {age} END AS age FROM person_stats) first_people'
        if suffix in ['coverage_count','continuous_person_count']:
            dims=dict(period_kind='period_kind',period_start=text('s.lo'),period_end=text('s.hi'))
            if suffix=='continuous_person_count':dims['full_calendar_period']='full_calendar_period::text'
            if suffix=='coverage_count':values=dict(person_count='count(DISTINCT u.person_id)::text',person_days="COALESCE(sum((LEAST(u.hi,COALESCE(s.hi,u.hi))-GREATEST(u.lo,COALESCE(s.lo,u.lo))+1)::numeric) FILTER(WHERE u.person_id IS NOT NULL),0)::text")
            else:values=dict(person_count="count(DISTINCT u.person_id) FILTER(WHERE u.lo<=COALESCE(s.lo,(SELECT min(lo) FROM unions)) AND u.hi>=COALESCE(s.hi,(SELECT max(hi) FROM unions)))::text")
            return f"SELECT 'counts'::text AS row_kind,{obj(**dims)} AS dimensions,{obj(**values)} AS values FROM (SELECT * FROM pop_periods UNION SELECT * FROM periods) s LEFT JOIN unions u ON s.lo IS NULL OR (u.lo<=s.hi AND u.hi>=s.lo) GROUP BY period_kind,s.lo,s.hi,full_calendar_period"
        if suffix=='year_gender_age_count':
            age='extract(year FROM s.lo)::numeric-p.year_of_birth::numeric'
            dims=obj(year='extract(year FROM s.lo)::integer::text',gender_concept_id=text('p.gender_concept_id'),year_age_decile=f"CASE WHEN year_of_birth BETWEEN 1 AND 9999 AND {age} BETWEEN 0 AND 130 THEN div({age},10)::text ELSE 'unknown' END")
            return grouped("(SELECT p.*,s.lo FROM people p CROSS JOIN pop_periods s WHERE s.period_kind='calendar_year' AND EXISTS(SELECT FROM unions u WHERE u.person_id=p.person_id AND u.lo<=s.hi AND u.hi>=s.lo)) p",dims.replace('s.lo','p.lo'),dict(person_count='count(*)::text'))
        if suffix=='type_count':return grouped('raw',obj(period_type_concept_id=text('period_type_concept_id')),dict(record_count='count(*)::text'))
        if suffix=='integrity_count':
            reasons=['null_person','orphan_person','null_endpoints','reversed_interval','valid']
            return f"SELECT 'counts'::text AS row_kind,jsonb_build_object('reason',r.reason) AS dimensions,jsonb_build_object('record_count',count(o.reason)::text) AS values FROM (VALUES {','.join('('+lit(r)+')' for r in reasons)}) r(reason) LEFT JOIN raw o USING(reason) GROUP BY r.reason"
        if suffix=='boundary_month_count':return grouped("(SELECT person_id,b.kind,date_trunc('month',b.day)::date AS month FROM unions CROSS JOIN LATERAL (VALUES('start',lo),('end',hi)) b(kind,day)) b",obj(boundary_kind='kind',month='month::text'),dict(interval_count='count(*)::text',person_count='count(DISTINCT person_id)::text'))
        if suffix in ['person_interval_histogram','total_days_histogram']:
            dims=obj(interval_count='intervals::text') if suffix=='person_interval_histogram' else obj(floor_days_div_30='div(total_days,30)::text')
            return grouped('person_stats',dims,dict(person_count='count(*)::text'))
        if suffix=='first_age_count':return grouped(f'(SELECT * FROM {first} WHERE first_start IS NOT NULL) q',obj(gender_concept_id=text('gender_concept_id'),year_age_or_unknown=text('age','unknown')),dict(person_count='count(*)::text'))
        if suffix=='first_interval_30d_count':return grouped('(SELECT * FROM person_stats WHERE first_start IS NOT NULL) q',obj(floor_days_div_30='div((first_end-first_start+1)::numeric,30)::text'),dict(person_count='count(*)::text'))
        if suffix=='first_age_summary':return summary(f'SELECT {obj(gender_concept_id=text("gender_concept_id"))} AS dimensions,age AS value,{reason} AS reason FROM {first} WHERE first_start IS NOT NULL',PROFILE['contracts']['eligibility-reasons']['age_order'],'person_count')
        if suffix=='first_interval_days_summary':
            dims=obj(gender_concept_id=text('gender_concept_id'),first_year_age_decile=f"CASE WHEN age IS NULL THEN 'unknown' ELSE div(age,10)::text END")
            return summary(f"SELECT {dims} AS dimensions,(first_end-first_start+1)::numeric AS value,'eligible'::text AS reason FROM {first} WHERE first_start IS NOT NULL",['eligible'],'person_count')
        raise ValueError('Unimplemented observation reference: '+suffix)

    def density(self,suffix):
        bits='||'.join(f'(EXISTS(SELECT FROM {self.table(PROFILE["domains"][d]["table"])} e WHERE e.person_id=p.person_id))::integer::text' for d in DOMAINS)
        dims=obj(presence_bits='bits') if suffix=='domain_presence_count' else obj(domain_count="length(replace(bits,'0',''))::text")
        return grouped(f'(SELECT {bits} AS bits FROM people p) b',dims,dict(person_count='count(*)::text'))

    def domain(self,domain,suffix,observed):
        concept={'concept_tag':'concept_tag'};reasons=PROFILE['contracts']['eligibility-reasons']
        if suffix=='capture_count':
            scopes='periods' if observed else "(SELECT * FROM periods UNION ALL SELECT 'undated',NULL::date,NULL::date,false)"
            cond="(s.period_kind='full_scope' OR (s.period_kind='undated' AND e.event_date IS NULL) OR (s.period_kind IN ('calendar_month','calendar_year') AND e.valid_date AND e.event_date BETWEEN s.lo AND s.hi))"
            if observed:cond+=' AND e.observed'
            dims=obj(concept_tag='g.concept_tag',period_kind='s.period_kind',period_start=text('s.lo'),period_end=text('s.hi'))
            return f"SELECT 'counts'::text AS row_kind,{dims} AS dimensions,jsonb_build_object('record_count',count(e.concept_tag)::text,'person_count',count(DISTINCT e.person_id) FILTER(WHERE e.linked)::text) AS values FROM (SELECT DISTINCT concept_tag FROM facts UNION ALL SELECT jsonb_build_object('kind','all')) g CROSS JOIN {scopes} s LEFT JOIN facts e ON (g.concept_tag->>'kind'='all' OR g.concept_tag=e.concept_tag) AND {cond} GROUP BY g.concept_tag,s.period_kind,s.lo,s.hi"
        if observed and suffix=='year_gender_age_count':
            age='extract(year FROM event_date)::numeric-year_of_birth::numeric'
            fields=dict(year='extract(year FROM event_date)::integer::text',gender_concept_id=text('gender_concept_id'),year_age_decile=f"CASE WHEN year_of_birth BETWEEN 1 AND 9999 AND {age} BETWEEN 0 AND 130 THEN div({age},10)::text ELSE 'unknown' END")
            return ' UNION ALL '.join(grouped('(SELECT * FROM facts WHERE observed) q',obj(concept_tag=ct,**fields),dict(person_count='count(DISTINCT person_id)::text')) for ct in ['concept_tag',"jsonb_build_object('kind','all')"])
        dimensions={'source_count':dict(source_concept_tag='source_tag',source_value_state='source_state'),
                    'type_count':dict(type_concept_tag='type_tag'),'observation_qualification_count':dict(reason='qualification'),
                    'status_type_count':dict(status_concept_tag=tag('condition_status_concept_id'),type_concept_tag='type_tag'),
                    'unit_count':dict(unit_concept_tag=tag('unit_concept_id')),'coded_value_count':dict(value_concept_tag=tag('value_as_concept_id')),
                    'operator_count':dict(raw_operator_tag=tag('operator_concept_id')),'qualifier_count':dict(qualifier_concept_tag=tag('qualifier_concept_id'))}
        if suffix in dimensions:
            fields=dimensions[suffix]
            if domain=='device' and suffix=='unit_count':fields=dict(fields,source_unit_presence="CASE WHEN unit_source_value IS NULL THEN 'null' WHEN btrim(unit_source_value,' ')='' THEN 'blank' ELSE 'nonblank' END")
            return count_rows('facts',obj(**concept,**fields))
        if suffix=='frequency_histogram':
            return f"""WITH frequency AS (SELECT concept_tag,person_id,count(*)::numeric AS n FROM facts WHERE linked GROUP BY concept_tag,person_id)
              SELECT 'counts'::text AS row_kind,jsonb_build_object('concept_tag',concept_tag,'event_count',n::text) AS dimensions,jsonb_build_object('person_count',count(*)::text) AS values FROM frequency GROUP BY concept_tag,n
              UNION ALL SELECT 'counts',jsonb_build_object('concept_tag',g.concept_tag,'event_count','0'),jsonb_build_object('person_count',((SELECT count(*) FROM people)-count(f.person_id))::text) FROM (SELECT DISTINCT concept_tag FROM facts) g LEFT JOIN frequency f USING(concept_tag) GROUP BY g.concept_tag"""
        if suffix=='distinct_concepts_histogram':return grouped('(SELECT p.person_id,count(DISTINCT e.concept_id)::numeric AS n FROM people p LEFT JOIN facts e USING(person_id) GROUP BY p.person_id) q',obj(concept_count='n::text'),dict(person_count='count(*)::text'))
        if suffix=='integrity_count':
            flags=dict(null_person='person_id IS NULL',orphan_person='person_id IS NOT NULL AND NOT linked',missing_date='event_date IS NULL',invalid_date='event_date IS NOT NULL AND NOT valid_date',null_concept='concept_id IS NULL',zero_concept='concept_id=0',unknown_concept='concept_id IS NOT NULL AND concept_id<>0 AND NOT known_concept',wrong_domain_concept='concept_id<>0 AND known_concept AND NOT right_domain')
            d=PROFILE['domains'][domain]
            if d['end_date'] and d['end_date'] in self.columns[d['table']]:flags.update(missing_end='end_date IS NULL',reversed_end=f'valid_date AND {valid_date("end_date")} AND end_date<event_date')
            flags['repeated_person_rows' if domain=='death' else 'duplicate_record_id']='duplicated'
            return ' UNION ALL '.join(f"SELECT 'counts'::text AS row_kind,jsonb_build_object('flag',{lit(flag)},'present',b.present::text) AS dimensions,jsonb_build_object('record_count',(SELECT count(*)::text FROM facts WHERE ({expr}) IS NOT DISTINCT FROM b.present)) AS values FROM (VALUES(true),(false)) b(present)".replace(f'({expr}) IS NOT DISTINCT FROM b.present',f'(({expr}) IS TRUE)=b.present') for flag,expr in flags.items())
        if suffix=='first_age_summary':
            age,reason=self.age_reason('first_date')
            source='(SELECT concept_tag,person_id,gender_concept_id,year_of_birth,min(event_date) FILTER(WHERE valid_date) AS first_date FROM facts WHERE linked GROUP BY concept_tag,person_id,gender_concept_id,year_of_birth) f'
            return summary(f'SELECT {obj(**concept,gender_concept_id=text("gender_concept_id"))} AS dimensions,CASE WHEN ({reason})=\'eligible\' THEN {age} END AS value,{reason} AS reason FROM {source}',reasons['age_order'],'person_count')
        if suffix in ['days_supply_summary','refills_summary','quantity_summary','duration_summary']:
            value=suffix.removesuffix('_summary');fields=dict(concept)
            if domain in ['device','specimen']:fields['unit_concept_tag']=tag('unit_concept_id') if 'unit_concept_id' in self.columns[PROFILE['domains'][domain]['table']] else "jsonb_build_object('kind','schema_absent')"
            order=reasons['nonnegative_scalar_order']
            why=f"CASE WHEN {value} IS NULL THEN 'value_missing' WHEN NOT {finite(value)} THEN 'value_non_finite' WHEN {value}<0 THEN 'value_negative' ELSE 'eligible' END"
            if value=='duration':
                value='(end_date-event_date)::numeric';order=reasons['elapsed_duration_order']
                why=f"CASE WHEN NOT valid_date THEN 'start_missing_or_invalid' WHEN NOT {valid_date('end_date')} THEN 'end_missing_or_invalid' WHEN end_date<event_date THEN 'end_before_start' ELSE 'eligible' END"
            return summary(f'SELECT {obj(**fields)} AS dimensions,{value} AS value,{why} AS reason FROM facts',order)
        if suffix=='representation_count':
            names=['value_as_number','value_as_concept_id','value_source_value']+(['value_as_string','value_as_date'] if domain=='observation' else [])
            expr=[];grids=[]
            for i,name in enumerate(names):
                absent=name not in self.columns[PROFILE['domains'][domain]['table']]
                grids.append(f"(VALUES('X')) f{i}(v)" if absent else f"(VALUES('0'),('1')) f{i}(v)")
                present=f'{name} IS NOT NULL'+(f' AND {name}<>0' if name=='value_as_concept_id' else f" AND btrim({name},' ')<>''" if name in ['value_source_value','value_as_string'] else '')
                expr.append("'X'" if absent else f'({present})::integer::text')
            flags='||'.join(expr);grid=' CROSS JOIN '.join(grids);combos='||'.join(f'f{i}.v' for i in range(len(names)))
            return f"SELECT 'counts'::text AS row_kind,jsonb_build_object('concept_tag',g.concept_tag,'representation_flags',b.flags) AS dimensions,jsonb_build_object('record_count',count(e.concept_tag)::text,'person_count',count(DISTINCT e.person_id) FILTER(WHERE e.linked)::text) AS values FROM (SELECT DISTINCT concept_tag FROM facts) g CROSS JOIN (SELECT {combos} AS flags FROM {grid}) b LEFT JOIN (SELECT *,{flags} AS flags FROM facts) e ON e.concept_tag=g.concept_tag AND e.flags=b.flags GROUP BY g.concept_tag,b.flags"
        numeric=f"CASE WHEN value_as_number IS NULL THEN 'numeric_missing' WHEN NOT {finite('value_as_number')} THEN 'numeric_non_finite' WHEN unit_concept_id IS NULL THEN 'unit_null' WHEN unit_concept_id=0 THEN 'unit_zero' WHEN NOT known_unit THEN 'unit_unrecognized' "+("WHEN operator_concept_id IS NOT NULL AND operator_concept_id<>0 THEN 'operator_explicit_measurement_only' " if domain=='measurement' else '')+"ELSE 'eligible' END"
        if suffix=='numeric_eligibility_count':return count_rows('facts',obj(**concept,reason=numeric),False)
        if suffix=='numeric_summary':
            fields=dict(concept,unit_concept_tag=tag('unit_concept_id'));where='known_unit';order=list(reasons['numeric_summary_order'])
            if domain=='measurement':fields['raw_operator_tag']=tag('operator_concept_id');where+=' AND (operator_concept_id IS NULL OR operator_concept_id=0)'
            else:order.remove('operator_explicit_measurement_only')
            return summary(f'SELECT {obj(**fields)} AS dimensions,value_as_number::numeric AS value,{numeric} AS reason FROM facts WHERE {where}',order)
        if suffix in ['range_low_summary','range_high_summary']:
            value=suffix.removesuffix('_summary');fields=dict(concept,unit_concept_tag=tag('unit_concept_id'))
            why=f"CASE WHEN {value} IS NULL THEN 'bound_missing' WHEN NOT {finite(value)} THEN 'bound_non_finite' WHEN unit_concept_id IS NULL THEN 'unit_null' WHEN unit_concept_id=0 THEN 'unit_zero' WHEN NOT known_unit THEN 'unit_unrecognized' ELSE 'eligible' END"
            extra=f"SELECT 'eligibility_counts' AS row_kind,dimensions,jsonb_build_object('record_count',count(*)::text) AS values FROM (SELECT {obj(**fields,eligibility_reason=why)} AS dimensions FROM facts WHERE NOT known_unit) q GROUP BY dimensions"
            return summary(f'SELECT {obj(**fields)} AS dimensions,{value}::numeric AS value,{why} AS reason FROM facts WHERE known_unit',reasons['range_boundary_order'],extra=extra)
        if suffix=='range_status_count':
            why=f"CASE WHEN value_as_number IS NULL THEN 'numeric_missing' WHEN NOT {finite('value_as_number')} THEN 'numeric_non_finite' WHEN NOT known_unit THEN 'unit_unavailable_or_unrecognized' WHEN operator_concept_id IS NOT NULL AND operator_concept_id<>0 THEN 'operator_explicit' WHEN range_low IS NULL AND range_high IS NULL THEN 'both_bounds_missing' WHEN range_low IS NULL OR range_high IS NULL THEN 'one_bound_missing' WHEN NOT {finite('range_low')} OR NOT {finite('range_high')} THEN 'bound_non_finite' WHEN range_low>range_high THEN 'bounds_reversed' WHEN value_as_number<range_low THEN 'below' WHEN value_as_number>range_high THEN 'above' ELSE 'within' END"
            return count_rows('facts',obj(**concept,unit_concept_tag=tag('unit_concept_id'),raw_operator_tag=tag('operator_concept_id'),reason=why),False)
        if suffix=='care_setting_count':
            care=self.table('care_site');place=f'(SELECT s.place_of_service_concept_id FROM {care} s WHERE s.care_site_id=facts.care_site_id)'
            place_tag="jsonb_build_object('kind','schema_absent')" if self.care_reason else tag(place)
            return ' UNION ALL '.join(count_rows('facts',obj(**concept,setting_kind=lit(k),setting_concept_tag=v)) for k,v in [('visit','concept_tag'),('admitted_from',tag('admitted')),('discharged_to',tag('discharged')),('place_of_service',place_tag)])
        if suffix=='site_status_count':return ' UNION ALL '.join(count_rows('facts',obj(**concept,dimension_kind=lit(k),dimension_concept_tag=tag(v))) for k,v in [('anatomic_site','anatomic_site_concept_id'),('disease_status','disease_status_concept_id')])
        if suffix=='visit_link_presence_count':return ' UNION ALL '.join(count_rows('facts',obj(**concept,link_kind=lit(k),present=f'({k}_id IS NOT NULL)::text')) for k in ['visit_occurrence','visit_detail'])
        if suffix=='end_precision_count':
            tests=[("CASE WHEN event_date IS NULL AND procedure_datetime IS NULL THEN 'start_absent' WHEN event_date IS NULL THEN 'start_datetime_only' WHEN procedure_datetime IS NULL THEN 'start_date_only' ELSE 'start_date_and_datetime' END",'true'),("CASE WHEN end_date IS NULL AND procedure_end_datetime IS NULL THEN 'end_absent' WHEN end_date IS NULL THEN 'end_datetime_only' WHEN procedure_end_datetime IS NULL THEN 'end_date_only' ELSE 'end_date_and_datetime' END",'true')]+[(lit(k),v) for k,v in [('missing_duration','event_date IS NULL OR end_date IS NULL'),('negative_duration','end_date<event_date'),('start_disagreement','event_date<>procedure_datetime::date'),('end_disagreement','end_date<>procedure_end_datetime::date')]]
            return ' UNION ALL '.join(count_rows(f'(SELECT * FROM facts WHERE ({v}) IS TRUE) q',obj(**concept,reason=k)) for k,v in tests)
        raise ValueError('Unimplemented domain reference: '+domain+'.'+suffix)

    def stats(self):
        fields=dict(person_count='(SELECT count(*)::text FROM people)',raw_observation_count='(SELECT count(*)::text FROM raw)',merged_interval_count='(SELECT count(*)::text FROM unions)')
        for domain in DOMAINS:
            d=PROFILE['domains'][domain];table=self.table(d['table']);day=ident(d['event_date'])
            fields[domain+'_raw']=f'(SELECT count(*)::text FROM {table})'
            fields[domain+'_observed']=f'(SELECT count(*)::text FROM {table} e WHERE EXISTS(SELECT FROM unions u WHERE u.person_id=e.person_id AND e.{day} BETWEEN u.lo AND u.hi))'
        return 'WITH '+self.common()+' SELECT '+obj(**fields)+'::text'

    def manifest(self):
        return dict(profile_sha256=hashlib.sha256(PROFILE_PATH.read_bytes()).hexdigest(),
                    compiler_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),care_reason=self.care_reason,
                    stats_sql=self.stats(),
                    queries={mid:dict(sql=self.compile(mid),unsupported_reason=self.supported(mid)) for mid in self.ids if mid not in METADATA})
