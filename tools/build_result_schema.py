#!/usr/bin/env python3
"""Build finite shipped row schemas from the public numerical/type registries."""
import json
import hashlib
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'inst/contracts/v2'
load = lambda p: json.loads(p.read_text())
profile = load(ROOT / 'inst/analysis/core-characterization-v2.json')
registry = load(OUT / 'rows.json')
metadata = load(OUT / 'metadata.schema.json')

def obj(properties):
    return {'type': 'object', 'properties': properties, 'required': list(properties), 'additionalProperties': False}

def string(pattern):
    return {'type': 'string', 'pattern': pattern}

count = string(r'^(0|[1-9][0-9]*)$')
integer = string(r'^(0|[1-9][0-9]*|-[1-9][0-9]*)$')
decimal = string(r'^(0|[1-9][0-9]*|-[1-9][0-9]*)(\.[0-9]*[1-9])?$|^-0\.[0-9]*[1-9]$')
sha = string(r'^[0-9a-f]{64}$')
reason = {'anyOf': [string(r'^[a-z0-9_.:-]{1,96}$'), {'type': 'null'}]}
tag = {'oneOf': [obj({'kind': {'enum': ['all','null','schema_absent']}}), obj({'kind': {'const':'id'}, 'value':integer})]}
nullable = lambda s: {'anyOf':[s,{'type':'null'}]}
enums = dict(period_kind=['full_scope','calendar_month','calendar_year','undated'],boundary_kind=['start','end'],
    source_value_state=['null','blank','nonblank','schema_absent'],source_unit_presence=['null','blank','nonblank','schema_absent'],
    setting_kind=['visit','admitted_from','discharged_to','place_of_service'],dimension_kind=['anatomic_site','disease_status'],
    link_kind=['visit_occurrence','visit_detail'],phase=['planning','source_read','materialization','aggregation','validation','projection','export','publication','execution','generation'])
reasons = sum([v for k,v in profile['contracts']['eligibility-reasons'].items() if k.endswith('_order')], [])
reasons += ['null_person','orphan_person','null_endpoints','reversed_interval','valid','undated','no_valid_intervals','outside_valid_union','inside_valid_union','null_or_orphan_person','start_date_only','start_datetime_only','start_date_and_datetime','start_absent','end_date_only','end_datetime_only','end_date_and_datetime','end_absent','missing_duration','negative_duration','start_disagreement','end_disagreement']
enums['reason'] = enums['eligibility_reason'] = sorted(set(reasons))
enums['flag'] = ['null_person','orphan_person','missing_date','invalid_date','null_concept','zero_concept','unknown_concept','wrong_domain_concept','missing_end','reversed_end','duplicate_record_id','repeated_person_rows']
all_dims = set(d for m in registry['metrics'] for d in m['dimensions']) | set(d for m in registry['metrics'] for ds in m['extra_dimensions_by_row_kind'].values() for d in ds)
dimensions = {}
for name in sorted(all_dims):
    if name in enums: schema = {'enum': enums[name]}
    elif name.endswith('_tag'): schema = tag
    elif name in ['period_start','period_end','month']:
        schema = {'anyOf': [{'type':'string','format':'date'}, {'enum':['null','undated']}]}
    elif name in ['year','year_of_birth','event_count','concept_count','interval_count','domain_count','floor_days_div_30'] or name.endswith('_concept_id'): schema = integer
    elif name in ['present','full_calendar_period']: schema = {'enum':['true','false']}
    elif name in ['presence_bits','representation_flags']: schema = string(r'^[01X]{1,16}$')
    else: schema = string(r'^[A-Za-z0-9._:-]{1,128}$')
    dimensions[name] = schema
(OUT / 'dimensions.json').write_text(json.dumps(dimensions,indent=2)+'\n')
refs = obj({'measure': {'enum':['record_count','person_count','person_days','interval_count','n']}, 'metric_id':{'enum':[m['id'] for m in registry['metrics']]},'row_key':sha,'field':{'enum':['record_count','person_count','person_days','interval_count','n']},'value':count})
definitions = dict(metadata['$defs'])
definitions.update({'wire_sha256':sha, 'wire_reason':reason, 'wire_count':count, 'wire_decimal':decimal, 'wire_ref':refs,
    'wire_state':{'enum':['computed','empty_source','empty_population','suppressed','unsupported','unavailable']}})
ref = lambda name: {'$ref':'#/$defs/'+name}
for name, schema in dimensions.items(): definitions['dimension.'+name] = schema
variants = []
value_variants = {}

for metric in registry['metrics']:
    kinds = []
    for kind, keys in metric['value_keys_by_row_kind'].items():
        names = metric['dimensions'] + metric['extra_dimensions_by_row_kind'].get(kind,[])
        values = {'$ref':'#/$defs/'+metric['id']} if kind=='metadata' else obj({k: count if kind in ['counts','eligibility_counts'] or k=='n' else nullable(count if k=='mean_denominator' else decimal) for k in keys})
        signature = json.dumps(values,sort_keys=True)
        if signature not in value_variants:
            name = 'values.'+str(len(value_variants))
            value_variants[signature] = name;definitions[name] = values
        row = obj({'row_key':ref('wire_sha256'),'dimensions':obj({d:ref('dimension.'+d) for d in names}),'row_kind':{'const':kind},'state':ref('wire_state'),'reason_code':ref('wire_reason'),'values':nullable(ref(value_variants[signature])),'denominator_refs':{'type':'array','maxItems':2,'items':ref('wire_ref')}})
        kinds.append(row)
    variants.append(obj({'metric_id':{'const':metric['id']},'row':{'oneOf':kinds}}))
schema = {'$schema':'https://json-schema.org/draft/2020-12/schema','$id':'urn:achilles-next:rows:2.0.0','$defs':definitions,'oneOf':variants}
(OUT / 'row.schema.json').write_text(json.dumps(schema,separators=(',',':'))+'\n')
lock = {'contract_version':'2.0.0','sha256':{name:hashlib.sha256((OUT/name).read_bytes()).hexdigest() for name in ['rows.json','dimensions.json','metadata.schema.json','row.schema.json']}}
(OUT / 'schema-lock.json').write_text(json.dumps(lock,indent=2)+'\n')
