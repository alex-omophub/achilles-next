"""Fail-closed small-result comparison, including metadata and complete exports."""
import copy
import hashlib
import json
from pathlib import Path
import re
from matched_reference_sql import PROFILE, PROFILE_PATH, METADATA

IDS={m['id'] for m in PROFILE['metrics']}
TIMING='core.execution.timing'


def need(value,message):
    if not value:raise ValueError(message)


def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False)


def semantic(snapshot):
    """Normalize only declared factual timestamps and timing topology/values.

    Numerical rows retain exact wire strings, keys, states and denominator refs.
    Timing rows are validated as operational facts, not deleted before validation.
    """
    need(set(snapshot['datasets'])==IDS and set(snapshot['rows'])==IDS,'Reference scope must contain all142 outputs')
    data=copy.deepcopy(dict(datasets=snapshot['datasets'],rows=snapshot['rows']))
    for mid,d in data['datasets'].items():
        need(d['metric_id']==mid and d['state']!='not_requested','Unmatched dataset identity/state')
        need(str(len(data['rows'][mid]))==d['rows'],'Dataset row count differs: '+mid)
        keys=[r['row_key'] for r in data['rows'][mid]]
        need(len(keys)==len(set(keys)),'Duplicate result row identity')
    passport=data['rows']['core.source.passport']
    need(len(passport)==1,'Missing source passport')
    generation=passport[0]['values']['generation']
    need(set(generation)=={'started_at','ended_at'} and generation['started_at']<=generation['ended_at'],'Invalid generation facts')
    passport[0]['values']['generation']={'started_at':'<factual>','ended_at':'<factual>'}
    timing=data['rows'][TIMING];operations=[]
    need(bool(timing),'Missing operational timing facts')
    for row in timing:
        need(row['row_kind']=='metadata' and row['state']=='computed' and row['reason_code'] is None and row['denominator_refs']==[],'Invalid timing cell')
        d,v=row['dimensions'],row['values'];operations.append((d['operation_id'],d['phase']))
        need(v['telemetry']==dict(cpu_ms=None,peak_memory_bytes=None,source_rows=None,temp_bytes=None),'Unexpected or fabricated resource telemetry')
        if v['availability']=='measured':need(bool(re.fullmatch('0|[1-9][0-9]*',v['duration_ms'])) and v['reason_code'] is None,'Invalid measured timing')
        else:need(v==dict(duration_ms=None,telemetry=v['telemetry'],availability='unavailable',reason_code='execution.not_started_at_metadata_capture') and d['phase'] in ['validation','projection','export','publication'],'Invalid unavailable timing')
    need(len(set(operations))==len(operations),'Duplicate timing operation')
    need(('core.numeric_generation','generation') in operations,'Missing generation timing')
    for phase in ['validation','projection','export','publication']:
        need(('core.'+phase,phase) in operations,'Missing deferred timing phase')
    data['datasets'][TIMING]['rows']='<factual_timing_row_count>'
    data['rows'][TIMING]=[] # Only after validating each original operational row.
    data['rows']={mid:sorted(rows,key=canonical) for mid,rows in data['rows'].items()}
    return data


def compare_pair(left,right):
    a,b=semantic(left),semantic(right)
    for mid in sorted(IDS):
        need(a['datasets'][mid]==b['datasets'][mid],'Dataset metadata differs: '+mid)
        need(a['rows'][mid]==b['rows'][mid],'Analytical/metadata rows differ: '+mid)
    return dict(metric_count=142,numerical_metrics=138,metadata_metrics=4,normalized_facts=['passport generation timestamps','validated execution timing topology, durations and row count'],rows=sum(len(rs) for rs in left['rows'].values()))


def table_populated(model,table):
    if 'table_rows' not in model:return bool(model['tables'][table])
    counts=model['table_rows']
    need(set(counts)==set(model['columns']) and all(type(n) is int and n>=0 for n in counts.values()),'Invalid source inventory counts')
    return counts[table]>0


def expected_capabilities(model):
    probes=set()
    for m in PROFILE['metrics']:
        probes.update(m['inputs']);probes.update(m['conditional_inputs'])
        for choices in m['input_aliases'].values():probes.update(choices.values())
    result={}
    for p in probes:
        state='available';reason=None;typ=None
        if p in ['capability_probes','schema_metadata']:typ='pg_catalog'
        elif p=='operator_assertions':state='absent';reason='source.no_operator_assertions'
        elif '.' not in p:
            if p not in model['columns']:state='absent';reason='capability.table_absent'
            elif p in model.get('denied_tables',[]):state='inaccessible';reason='capability.select_denied';typ='relation'
            else:state='available' if table_populated(model,p) else 'available_empty';typ='relation'
        else:
            table,column=p.split('.');typ=model['columns'].get(table,{}).get(column)
            if typ is None:state='absent';reason='capability.column_absent'
            else:
                typ=typ.lower()
                typ={'timestamp':'timestamp without time zone','int':'integer'}.get(typ,typ)
                typ=re.sub(r'^varchar', 'character varying',typ)
                if table in model.get('denied_tables',[]):state='inaccessible';reason='capability.select_denied'
                else:state='available' if table_populated(model,table) else 'available_empty'
        result[p]=dict(state=state,reason_code=reason,observed_type=typ)
    return result


def metadata_values(rows,dimension):
    result={}
    for row in rows:
        key=row['dimensions'][dimension]
        need(key not in result,'Duplicate metadata dimension: '+dimension)
        result[key]=row['values']
    return result


def check_metadata(snapshot,model):
    semantic(snapshot)
    rows=snapshot['rows'];datasets=snapshot['datasets']
    got=metadata_values(rows['core.source.capabilities'],'probe_id')
    need(got==expected_capabilities(model),'Independent physical capability expectations differ')
    passport=rows['core.source.passport'][0]['values']
    need(passport['source_id']==snapshot['source_id'] and passport['declared_cdm_version']==snapshot['version'],'Source passport mismatch')
    need(passport['observed_schema']==dict(sha256=snapshot['schema_sha256'],reason_code=None),'Schema passport mismatch')
    need(passport['coverage']==dict(scope_kind='standard_full',complete=True,excluded_record_count='0',reason_code=None),'Incomplete source scope')
    need(passport['consistency']==dict(within_run='single_repeatable_read',reusable=False,reason_code='source.no_verified_release'),'Unexpected source consistency claim')
    unknown=dict(state='unknown',value=None,basis=None,assertion_id=None,reason_code='source.no_verified_release')
    need(passport['source_release']==unknown and passport['vocabulary_release']==unknown,'Unverified source identity claimed')
    need(passport['profile']==dict(id=PROFILE['profile_id'],revision=PROFILE['revision'],sha256=hashlib.sha256(PROFILE_PATH.read_bytes()).hexdigest()),'Profile passport mismatch')
    ledger=metadata_values(rows['core.execution.output_status'],'metric_id')
    need(set(ledger)==IDS,'Incomplete output ledger')
    for mid,d in datasets.items():
        need(ledger[mid]==dict(state=d['state'],reason_code=d['reason_code'],required=d['required'],coverage=d['completeness'],integrity=dict(state='not_validated',sha256=None,reason_code='validation.pending_receipt')),'Output ledger differs: '+mid)


def artifact(directory,publication,snapshot):
    """Traverse every content-addressed object and compare all projected rows."""
    directory=Path(directory);pointer=json.loads((directory/'publication.json').read_text())
    need(pointer['root']==publication['root'] and pointer['publication_id']==publication['publication_id'],'Export pointer mismatch')
    context=dict(contract_version='2.0.0',source_id=snapshot['source_id'],publication_id=publication['publication_id'],release_id=publication['release_id'],access_scope_id=publication['access_scope_id'],profile_id=PROFILE['profile_id'],profile_revision=PROFILE['revision'],profile_sha256=hashlib.sha256(PROFILE_PATH.read_bytes()).hexdigest())
    seen=set();datasets={};rows={mid:[] for mid in IDS};concepts=[];terminology=[]
    def visit(descriptor):
        sha=descriptor['sha256'];need(bool(re.fullmatch('[0-9a-f]{64}',sha)) and sha not in seen,'Invalid/repeated export object')
        seen.add(sha);raw=(directory/'objects'/(sha+'.json')).read_bytes()
        need(hashlib.sha256(raw).hexdigest()==sha and str(len(raw))==descriptor['bytes'],'Export object digest mismatch')
        doc=json.loads(raw);need(doc['kind']==descriptor['kind'],'Object kind mismatch')
        for key,value in context.items():need(doc[key]==value,'Export context differs: '+key)
        kind=doc['kind']
        if kind=='root':
            need(doc['scope_kind']==publication['policy']['scope_kind'] and doc['expected_metric_count']=='142','Export scope differs')
            for k in ['catalogue','data','concepts','terminology']:visit(doc[k])
        elif kind=='index':
            for child in doc['children']:visit(child['object'])
        elif kind=='metric_catalogue':
            for entry in doc['entries']:
                need(entry['metric_id'] not in datasets,'Duplicate export dataset');datasets[entry['metric_id']]=entry
        elif kind=='data':
            need(doc['metric_id'] in IDS,'Unknown export metric');rows[doc['metric_id']].extend(doc['rows'])
        elif kind=='concept_catalogue':concepts.extend(doc['entries'])
        elif kind=='terminology':terminology.extend(doc['entries'])
        else:raise ValueError('Unexpected export kind')
    visit(pointer['root'])
    need({p.name for p in (directory/'objects').iterdir()}=={sha+'.json' for sha in seen},'Extra/missing export objects')
    need(set(datasets)==IDS,'Incomplete export inventory')
    allowed=set(publication['policy']['allow_metrics']);need(allowed<=IDS,'Unknown policy metric')
    for mid,d in datasets.items():
        want=snapshot['datasets'][mid] if mid in allowed else dict(snapshot['datasets'][mid],state='suppressed',reason_code='policy.output_omitted',rows='0')
        need(d==want,'Projected dataset differs: '+mid)
        need(sorted(rows[mid],key=canonical)==sorted(snapshot['rows'][mid] if mid in allowed else [],key=canonical),'Projected rows differ: '+mid)
    ids=set()
    for mid in allowed:
        for r in rows[mid]:
            if r['state']=='suppressed':continue
            for k,v in r['dimensions'].items():
                if k.endswith('_tag') and isinstance(v,dict) and v['kind']=='id':ids.add(v['value'])
                elif k.endswith('_concept_id') and isinstance(v,str) and v!='null':ids.add(v)
    want=[dict(concept_tag=dict(kind='id',value=v),label=None,label_state='unavailable') for v in sorted(ids,key=int)]
    need(concepts==want and terminology==[dict(e,domain_id=None) for e in want],'Scope-exact concept/terminology inventory differs')
    return dict(objects=len(seen),retained_metrics=len(allowed),rows=sum(len(rs) for rs in rows.values()))


def check_expectations(snapshot,expectations):
    if expectations['kind']=='source_inventory':
        from matched_reference_sql import DOMAINS
        counts=expectations['table_rows']
        need(all(type(n) is int and n>=0 for n in counts.values()),'Invalid source inventory counts')
        need(snapshot['rows']['core.person.count'][0]['values']['person_count']==str(counts['person']),'Source inventory person count differs')
        for domain in DOMAINS:
            rows=[r for r in snapshot['rows']['core.'+domain+'.capture_count'] if r['dimensions']['concept_tag']=={'kind':'all'} and r['dimensions']['period_kind']=='full_scope']
            need(len(rows)==1 and rows[0]['values']['record_count']==str(counts[PROFILE['domains'][domain]['table']]),'Source inventory domain count differs: '+domain)
        return dict(metrics=10,scope='physical source counts only; paired SQL covers all138 numerical outputs')
    if expectations['kind']=='generated':
        from synthetic_cdm_oracle import check_snapshot
        return check_snapshot(snapshot,expectations['oracle'])
    need(expectations['kind']=='adversarial','Unknown independent expectation kind')
    expected=expectations['rows']
    need(set(expected)==IDS-set(METADATA),'Incomplete independent numerical expectations')
    for mid,want in expected.items():
        got=[dict(dimensions=r['dimensions'],values=r['values'],state=r['state'],reason_code=r['reason_code']) for r in snapshot['rows'][mid]]
        need(sorted(got,key=canonical)==sorted(want,key=canonical),'Independent adversarial expectations differ: '+mid)
    return dict(metrics=138,rows=sum(len(rs) for rs in expected.values()))


def check_candidates(path):
    """Fail before publication; a candidate check is not a native validation receipt."""
    path=Path(path)
    need(path.stat().st_size<=128*1024**2,'Small candidate comparison budget exceeded')
    payload=json.loads(path.read_text());paths=payload['paths']
    need(set(paths)=={'optimized','reference'},'Missing execution path')
    def sibling(name):
        need(isinstance(name,str) and Path(name).name==name and bool(re.fullmatch('[a-z0-9.-]+[.]json',name)),'Invalid candidate input path')
        p=path.parent/name;need(not p.is_symlink() and p.stat().st_size<=32*1024**2,'Invalid candidate input budget/type')
        return json.loads(p.read_text())
    model=sibling(payload['model']);expectations=sibling(payload['expectations'])
    result=compare_pair(paths['optimized']['snapshot'],paths['reference']['snapshot'])
    for one in paths.values():
        check_metadata(one['snapshot'],model);check_expectations(one['snapshot'],expectations)
    return result


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description='Check matched candidates before publication; no native-validation claim')
    parser.add_argument('candidates',type=Path)
    args=parser.parse_args()
    checked=check_candidates(args.candidates)
    print('Matched candidate comparison passed: all142 outputs and independent fixture expectations; native validation/publication still pending')
