"""Bounded, stateless synthetic CDM preview with deterministic CSV manifests."""
from collections import Counter
from datetime import date, timedelta
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / 'tests/fixtures/synthetic-cdm/recipe.json'
DDL = ROOT / 'tests/fixtures/postgresql/ddl'
LOCK = ROOT / 'tests/fixtures/postgresql/lock.json'
PROFILE = ROOT / 'inst/analysis/core-characterization-v2.json'
MAX_PEOPLE = 1000
MAX_EVENTS = 10000
MAX_BYTES = 32 * 1024**2
MASK = (1 << 64) - 1


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n').encode()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def mix(value):
    # Fixed SplitMix64 finalizer; never Python's process-randomized hash().
    value &= MASK
    value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9 & MASK
    value = (value ^ (value >> 27)) * 0x94d049bb133111eb & MASK
    return value ^ (value >> 31)


def plan(people=20, events=1000, seed=2026110801, version='5.5'):
    if (type(people) is not int or not 0 <= people <= MAX_PEOPLE or
        type(events) is not int or not 0 <= events <= MAX_EVENTS or
        type(seed) is not int or not 0 <= seed <= 2**32-1 or
        version not in ('5.3', '5.4', '5.5') or (not people and events)):
        raise ValueError('Preview requires 0..1000 people, 0..10000 events, a uint32 seed and CDM 5.3/5.4/5.5; events need people')
    return dict(people=people, events=events, seed=seed, cdm_version=version)


def assets(parameters):
    recipe = json.loads(RECIPE.read_bytes())
    lock = json.loads(LOCK.read_bytes())
    version = parameters['cdm_version']
    raw = (DDL / (version + '.sql')).read_bytes()
    keys = (DDL / (version + '-primary-keys.sql')).read_bytes()
    for name, value in [(version + '.sql', raw), (version + '-primary-keys.sql', keys)]:
        if sha(value) != lock['cdm']['files'][name]:
            raise ValueError('Pinned CDM DDL hash mismatch')
    profile = json.loads(PROFILE.read_bytes())
    if sha(PROFILE.read_bytes()) != json.loads((ROOT / 'inst/contracts/v2/rows.json').read_bytes())['profile_sha256']:
        raise ValueError('Profile hash differs from row contract')
    if sum(recipe['domain_weights'].values()) != 10000 or set(recipe['domain_weights']) != set(profile['domains']):
        raise ValueError('Recipe domain weights differ from profile')
    tables = {}
    for table, body in re.findall(r'CREATE TABLE @cdmDatabaseSchema\.(\w+)\s*\((.*?)\);', raw.decode(), re.S):
        columns = []
        for line in body.strip().splitlines():
            match = re.fullmatch(r'\s*"?(\w+)"?\s+(.+?)\s+(NOT NULL|NULL)\s*,?\s*', line)
            if not match:
                raise ValueError('Unrecognized locked DDL column')
            columns.append(dict(name=match[1].lower(), type=match[2], required=match[3] == 'NOT NULL'))
        tables[table] = columns
    if len(tables) < 35:
        raise ValueError('Incomplete locked DDL inventory')
    weights = recipe['domain_weights']
    counts = {d: parameters['events'] * w // 10000 for d, w in weights.items()}
    remainder = parameters['events'] - sum(counts.values())
    for d in sorted(weights, key=lambda d: (-(parameters['events'] * weights[d] % 10000), d))[:remainder]:
        counts[d] += 1
    pins = dict(generator=sha(Path(__file__).read_bytes()), recipe=sha(RECIPE.read_bytes()),
                DDL=sha(raw), primary_keys=sha(keys), lock=sha(LOCK.read_bytes()), profile=sha(PROFILE.read_bytes()))
    return recipe, profile, tables, counts, pins


def event_row(parameters, recipe, domain, spec, domain_index, index):
    # Every 100th physical row repeats the preceding complete row, including ID.
    source = index - 1 if index % 100 == 99 else index
    def draw(slot, size):
        return mix(parameters['seed'] ^ ((domain_index+1) * 0x9e3779b97f4a7c15) ^ (source * 0xd1b54a32d192ed03) ^ slot) % size
    people = parameters['people']; hot_people = max(1, people // 5)
    pid = 1 + draw(1, hot_people) if source % 5 != 4 else 1 + draw(1, people)
    concept_index = draw(2, 2) if source % 100 < 80 else 2 + draw(2, recipe['concepts_per_domain']-2)
    concept = 0 if source % 97 == 0 else 1000 * (domain_index+1) + concept_index
    start = date.fromisoformat(recipe['history_start']); end = date.fromisoformat(recipe['history_end'])
    day = start + timedelta(days=draw(3, (end-start).days+1))
    value = (None if source % 10 == 0 else 'NaN' if source % 50 == 7 else 'Infinity' if source % 50 == 17 else
             '2.5' if source % 5 != 4 else f'{int(draw(4,17))-8}.000125')
    unit = None if source % 29 == 0 else 0 if source % 31 == 0 else 999 if source % 37 == 0 else recipe['known_unit_ids'][draw(5,len(recipe['known_unit_ids']))]
    operator = 4172703 if source % 20 == 3 else None if source % 2 else 0
    text = [None, '', ' ', '\t', 'synthetic,"quote"', 'synthetic\\path'][source % 6]
    row = dict(person_id=str(pid))
    for name, val in [(spec['record_id'], source+1), (spec['concept'], concept), (spec['event_date'], day.isoformat()),
                      (spec['end_date'], day.isoformat()), (spec['type_concept'], 0 if source%3==0 else 1),
                      (spec['source_concept'], None if source%7==0 else 0 if source%43==0 else concept*32+draw(6,32)),
                      (spec['source_text'], text)]:
        if name:
            row[name] = val
    if domain == 'condition':
        row['condition_status_concept_id'] = source % 3
    if domain == 'drug':
        row.update(quantity=value,days_supply=source%8-1,refills=source%3)
    if domain == 'procedure':
        row.update(procedure_datetime=day.isoformat()+' 00:00:00',procedure_end_datetime=None)
    if domain == 'visit':
        row.update(care_site_id=1+source%2,admitted_from_concept_id=source%3,admitting_source_concept_id=source%3,
                   discharged_to_concept_id=source%2,discharge_to_concept_id=source%2)
    if domain in ('device','specimen'):
        row.update(quantity=(None if source%10==0 else source%7-1) if domain=='device' else value,
                   unit_concept_id=unit,unit_source_value=text,unit_source_concept_id=0)
    if domain == 'specimen':
        row.update(anatomic_site_concept_id=source%3,disease_status_concept_id=source%2,
                   visit_occurrence_id=None,visit_detail_id=None)
    if domain in ('measurement','observation'):
        row.update(value_as_number=value,value_as_concept_id=0 if source%3 else 1000*(domain_index+1),
                   unit_concept_id=unit,value_source_value=text,unit_source_value=text)
    if domain == 'measurement':
        row.update(operator_concept_id=operator,range_low=None if source%7==0 else '0',
                   range_high='-1' if source%11==0 else '10')
    if domain == 'observation':
        row.update(value_as_string=text,qualifier_concept_id=source%3,
                   value_as_date=day.isoformat() if source%2 else None)
    return row


def rows(parameters, recipe, profile, counts, table):
    if table == 'person':
        for pid in range(1, parameters['people']+1):
            yield dict(person_id=pid,gender_concept_id=0 if pid%7==0 else 8507 if pid%2 else 8532,
                       year_of_birth=2300 if pid%31==0 else 0 if pid%37==0 else 1950+pid%60,
                       race_concept_id=pid%3,ethnicity_concept_id=pid%2)
    elif table == 'observation_period':
        identifier = 0
        start=date.fromisoformat(recipe['history_start']);end=date.fromisoformat(recipe['history_end'])
        text=lambda d:d.isoformat()
        for pid in range(1, parameters['people']+1):
            if pid%10 == 0:
                continue
            periods = [(start+timedelta(days=14),end-timedelta(days=16))]
            if pid%10==1:periods.append((start+timedelta(days=19),start+timedelta(days=45)))
            if pid%10==2:periods.append((end-timedelta(days=15),end))
            if pid%10==3:periods.append((start+timedelta(days=50),start+timedelta(days=49)))
            for lo,hi in periods:
                identifier += 1
                yield dict(observation_period_id=identifier,person_id=pid,observation_period_start_date=text(lo),
                           observation_period_end_date=text(hi),period_type_concept_id=0)
    elif table == 'concept':
        values = [(0,'Metadata')] + [(1000*(i+1)+j,d.capitalize()) for i,d in enumerate(recipe['domain_weights']) for j in range(recipe['concepts_per_domain'])]
        values += [(i,'Unit') for i in recipe['known_unit_ids']]
        for identifier,domain in values:
            yield dict(concept_id=identifier,concept_name=f'Synthetic {domain} {identifier}',domain_id=domain,
                       vocabulary_id='NextSynthetic',concept_class_id='Synthetic',standard_concept='S' if identifier else None,
                       concept_code=str(identifier),valid_start_date='1970-01-01',valid_end_date='2099-12-31')
    elif table == 'vocabulary':
        yield dict(vocabulary_id='NextSynthetic',vocabulary_name='Synthetic preview reference concepts',
                   vocabulary_reference='synthetic:none',vocabulary_version='preview-1',vocabulary_concept_id=0)
    elif table == 'care_site':
        for i in (1,2):yield dict(care_site_id=i,place_of_service_concept_id=i-1)
    elif table == 'cdm_source':
        yield dict(cdm_source_name='AchillesNext generated synthetic preview',cdm_source_abbreviation='preview',
                   cdm_holder='Synthetic',source_description='Invented bounded fixture',
                   source_documentation_reference='synthetic:none',cdm_etl_reference='synthetic:none',
                   source_release_date=recipe['history_end'],cdm_release_date=recipe['history_end'],
                   cdm_version=parameters['cdm_version'],cdm_version_concept_id=0,vocabulary_version='preview-1')
    else:
        for i,domain in enumerate(recipe['domain_weights']):
            spec = profile['domains'][domain]
            if table == spec['table']:
                for index in range(counts[domain]):
                    yield event_row(parameters, recipe, domain, spec, i, index)


def encode_row(row, columns):
    values = []
    for col in columns:
        value = row.get(col['name'])
        if value is None:
            if col['required']:
                raise ValueError('Missing required fixture field: '+col['name'])
            values.append('\\N')
        else:
            text = str(value)
            if '\n' in text or '\r' in text:
                raise ValueError('Multiline preview values are not supported')
            values.append('"'+text.replace('"','""')+'"')
    return (','.join(values)+'\n').encode()


def materialize(parameters, directory=None):
    checked=plan(parameters['people'],parameters['events'],parameters['seed'],parameters['cdm_version'])
    if parameters!=checked:raise ValueError('Unexpected preview parameters')
    recipe, profile, tables, counts, pins = assets(parameters)
    files = {}; total = 0
    for table, columns in tables.items():
        digest = hashlib.sha256(); size = 0; number = 0; lo = None; hi = 0
        nulls = Counter(); marginal = Counter(); joint = Counter()
        histogram_columns = [c['name'] for c in columns if c['name'].endswith(('_concept_id','source_value','_date')) or
                             c['name'] in ('year_of_birth','value_as_number','range_low','range_high','quantity','days_supply','refills','value_as_string')]
        header = (','.join(c['name'] for c in columns)+'\n').encode()
        stream = (directory/(table+'.csv')).open('xb') if directory else None
        def emit(raw):
            nonlocal total, size
            total += len(raw);size += len(raw)
            if total > MAX_BYTES:raise ValueError('Preview output byte budget exceeded')
            digest.update(raw)
            if stream:stream.write(raw)
        try:
            emit(header)
            for row in rows(parameters, recipe, profile, counts, table):
                raw = encode_row(row, columns);emit(raw);number += 1
                lo = len(raw) if lo is None else min(lo,len(raw));hi = max(hi,len(raw))
                for c in columns:
                    if row.get(c['name']) is None:nulls[c['name']] += 1
                selected = {k:row.get(k) for k in histogram_columns}
                for k,v in selected.items():marginal[json.dumps([k,v],ensure_ascii=False,separators=(',',':'))] += 1
                numeric = row.get('value_as_number')
                joint[json.dumps([row.get('measurement_concept_id',row.get('observation_concept_id')),
                                 row.get('unit_concept_id'),row.get('operator_concept_id'),
                                 'missing' if numeric is None else 'non_finite' if numeric in ('NaN','Infinity','-Infinity') else 'finite',
                                 'hot_person' if row.get('person_id') is not None and int(row['person_id'])<=max(1,parameters['people']//5) else 'other_or_no_person'],separators=(',',':'))] += 1
                if len(marginal)>8192 or len(joint)>8192:raise ValueError('Preview histogram budget exceeded')
        finally:
            if stream:stream.close()
        files[table] = dict(file=table+'.csv',sha256=digest.hexdigest(),bytes=size,rows=number,
                            columns=[c['name'] for c in columns],row_bytes_min=lo,row_bytes_max=hi,
                            null_counts=dict(nulls),histogram_columns=histogram_columns,
                            marginal_histograms=dict(marginal),joint_histogram=dict(joint))
    if pins != assets(parameters)[-1]:raise ValueError('Generator inputs changed during generation')
    return dict(kind='synthetic_cdm_preview',algorithm='splitmix64-row-index-v1',recipe=recipe['id'],
                recipe_revision=recipe['revision'],parameters=parameters,pins=pins,tables=files,bytes=total,
                rows_per_domain=counts,scheduled_duplicate_rows={d:n//100 for d,n in counts.items()},
                rounding='largest remainder for domain rows; per-table floor(n/100) identical scheduled repeats',
                joint_histogram_fields=['measurement_or_observation_concept','unit','operator','numeric_state','person_bucket'],
                constraints_applied='locked table DDL NOT NULL/types only; no PK/FK installation so bag duplicates remain',
                limits=dict(people=MAX_PEOPLE,events=MAX_EVENTS,bytes=MAX_BYTES),
                qualification='bounded_preview_only_not_large_tier_or_clinical_validation')


def generate(directory, people=20, events=1000, seed=2026110801, version='5.5'):
    parameters = plan(people,events,seed,version) # Reject large work before any output.
    assets(parameters) # Check pinned inputs before creating the new directory.
    directory = Path(directory);directory.mkdir(mode=0o700)
    try:
        manifest = materialize(parameters,directory)
        raw = canonical(manifest)
        if len(raw)>4*1024**2:raise ValueError('Preview manifest budget exceeded')
        (directory/'manifest.json').write_bytes(raw)
        return manifest
    except BaseException:
        shutil.rmtree(directory)
        raise


def verify(directory):
    directory = Path(directory)
    if directory.is_symlink():raise ValueError('Symlinked preview directory')
    path = directory/'manifest.json'
    if path.is_symlink() or path.stat().st_size>4*1024**2:raise ValueError('Preview manifest size/type mismatch')
    raw = path.read_bytes()
    manifest = json.loads(raw)
    p = manifest['parameters'];parameters = plan(p['people'],p['events'],p['seed'],p['cdm_version'])
    if p != parameters:raise ValueError('Unexpected preview parameters')
    expected = materialize(parameters)
    if manifest != expected or raw != canonical(expected):raise ValueError('Preview manifest/replay mismatch')
    if {p.name for p in directory.iterdir()} != {'manifest.json'} | {t['file'] for t in expected['tables'].values()}:
        raise ValueError('Unexpected preview files')
    for t in expected['tables'].values():
        path = directory/t['file']
        if path.is_symlink() or not path.is_file() or path.stat().st_size != t['bytes']:
            raise ValueError('Preview file size/type mismatch')
        with path.open('rb') as stream:
            digest = hashlib.sha256()
            while chunk := stream.read(65536):digest.update(chunk)
        if digest.hexdigest()!=t['sha256']:raise ValueError('Preview CSV hash mismatch')
    return manifest
