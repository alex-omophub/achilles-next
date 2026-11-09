"""Indexed scale-source plans and capped CSV probes, never full-tier execution."""
import argparse
from datetime import date, timedelta
import hashlib
import json
from pathlib import Path
import shutil
import time

import synthetic_cdm as BASE

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT/'tests/fixtures/synthetic-cdm/scale-recipe.json'
MAX_ROWS = 10000
MAX_BYTES = 8 * 1024**2
MAX_SECONDS = 30
MIN_FREE = 16 * 1024**2
SOURCE_SHA = BASE.sha(Path(__file__).read_bytes())
BASE_SHA = BASE.sha(Path(BASE.__file__).read_bytes())
PERIODS = [(0, 0), (0, 1), (1, 0), (1, 1), (2, 0), (2, 1)] + [(i, 0) for i in range(3, 9)]


class Source:
    def __init__(self, tier='S2', version='5.5'):
        raw = RECIPE.read_bytes()
        recipe = json.loads(raw)
        if tier not in ('S1', 'S2') or version not in ('5.3', '5.4', '5.5'):
            raise ValueError('Select S1/S2 and CDM 5.3/5.4/5.5')
        config = recipe['tiers'][tier]
        if (len(recipe['domains']) != 9 or len(set(recipe['domains'])) != 9 or
                set(recipe['domains']) != set(recipe['domain_weights']) or
                any(type(w) is not int or w < 0 for w in recipe['domain_weights'].values()) or
                sum(recipe['domain_weights'].values()) != 10000 or
                recipe['source_fanout'] != 32 or recipe['unit_count'] != 16 or
                config['concepts_per_domain'] not in (5000, 50000)):
            raise ValueError('Unsupported indexed scale recipe')
        for name, maximum in [('people', 1000000), ('events', 100000000), ('seed', 2**32-1)]:
            if type(config[name]) is not int or not (0 if name == 'seed' else 1) <= config[name] <= maximum:
                raise ValueError('Indexed recipe parameter outside bounds')
        parameters = dict(people=config['people'], events=config['events'], seed=config['seed'], cdm_version=version)
        _, self.profile, self.columns, _, pins = BASE.assets(parameters)
        if set(self.profile['domains']) != set(recipe['domains']):
            raise ValueError('Scale domains differ from the frozen profile')
        if pins['generator'] != BASE_SHA or BASE.sha(Path(__file__).read_bytes()) != SOURCE_SHA:
            raise ValueError('Indexed source implementation changed after import')
        self.parameters, self.recipe, self.tier = parameters, recipe, tier
        self.domains = recipe['domains']
        self.concepts = config['concepts_per_domain']
        self.units = list(range(9000001, 9000001+recipe['unit_count']))
        self.start, self.end = date.fromisoformat(recipe['history_start']), date.fromisoformat(recipe['history_end'])
        if not 0 <= (self.end-self.start).days <= 5500:
            raise ValueError('Indexed history range outside bounds')
        self.rows_per_domain = {d: parameters['events']*recipe['domain_weights'][d]//10000 for d in self.domains}
        if sum(self.rows_per_domain.values()) != parameters['events']:
            raise ValueError('Indexed tiers require exact integer domain apportionment')
        self.counts = {table: 0 for table in self.columns}
        self.counts.update(person=parameters['people'],
                           observation_period=12*(parameters['people']//10)+sum(p < parameters['people']%10 for p, _ in PERIODS),
                           concept=1+len(self.domains)*self.concepts*(1+recipe['source_fanout'])+len(self.units),
                           vocabulary=1, care_site=2, cdm_source=1)
        for domain, rows in self.rows_per_domain.items(): self.counts[self.profile['domains'][domain]['table']] = rows
        self.pins = dict(pins, indexed_generator=SOURCE_SHA, scale_recipe=BASE.sha(raw))

    def plan(self):
        return dict(kind='indexed_scale_source_plan', algorithm='splitmix64-indexed-scale-v1',
                    recipe=self.recipe['id'], recipe_revision=self.recipe['revision'], tier=self.tier,
                    parameters=self.parameters, pins=self.pins, rows_per_domain=self.rows_per_domain,
                    table_rows=self.counts, auxiliary_rows=sum(self.counts.values())-self.parameters['events'],
                    concepts_per_domain=self.concepts, source_fanout=32, known_units=16,
                    history_start=str(self.start), history_end=str(self.end), schedule=self.recipe['schedule'],
                    full_tier_generated=False, execution_enabled=False, qualifying=False,
                    probe_limits=dict(rows=MAX_ROWS, bytes=MAX_BYTES, seconds=MAX_SECONDS, min_free_bytes=MIN_FREE))

    def standard(self, domain, index):
        return 1000000+domain*100000+index

    def source_concept(self, domain, index, slot):
        return 100000000+(domain*self.concepts+index)*32+slot

    def row(self, table, index):
        if table not in self.counts or type(index) is not int or not 0 <= index < self.counts[table]:
            raise ValueError('Row index outside the logical table')
        if table == 'person':
            pid = index+1
            return dict(person_id=pid, gender_concept_id=0 if pid%7 == 0 else 8507 if pid%2 else 8532,
                        year_of_birth=2300 if pid%31 == 0 else 0 if pid%37 == 0 else 1950+pid%60,
                        race_concept_id=pid%3, ethnicity_concept_id=pid%2)
        if table == 'observation_period':
            offset, period = PERIODS[index%12]; pid = 10*(index//12)+offset+1
            lo, hi = self.start+timedelta(days=14), self.end-timedelta(days=16)
            if period:
                if pid%10 == 1: lo, hi = self.start+timedelta(days=19), self.start+timedelta(days=45)
                elif pid%10 == 2: lo, hi = self.end-timedelta(days=15), self.end
                else: lo, hi = self.start+timedelta(days=50), self.start+timedelta(days=49)
            return dict(observation_period_id=index+1, person_id=pid,
                        observation_period_start_date=str(lo), observation_period_end_date=str(hi), period_type_concept_id=0)
        if table == 'concept':
            standards = len(self.domains)*self.concepts
            if index == 0: identifier, domain, standard = 0, 'Metadata', None
            elif index <= standards:
                d, c = divmod(index-1, self.concepts)
                identifier, domain, standard = self.standard(d, c), self.domains[d].capitalize(), 'S'
            elif index <= standards+len(self.units):
                identifier, domain, standard = self.units[index-standards-1], 'Unit', 'S'
            else:
                d, rest = divmod(index-standards-len(self.units)-1, self.concepts*32)
                c, slot = divmod(rest, 32)
                identifier, domain, standard = self.source_concept(d, c, slot), self.domains[d].capitalize(), None
            return dict(concept_id=identifier, concept_name=f'Synthetic scale {domain} {identifier}',
                        domain_id=domain, vocabulary_id='NextSyntheticScale', concept_class_id='Synthetic',
                        standard_concept=standard, concept_code=str(identifier),
                        valid_start_date='1970-01-01', valid_end_date='2099-12-31')
        if table == 'vocabulary':
            return dict(vocabulary_id='NextSyntheticScale', vocabulary_name='Invented indexed scale concepts',
                        vocabulary_reference='synthetic:none', vocabulary_version='indexed-1', vocabulary_concept_id=0)
        if table == 'care_site': return dict(care_site_id=index+1, place_of_service_concept_id=index)
        if table == 'cdm_source':
            return dict(cdm_source_name='AchillesNext indexed synthetic source', cdm_source_abbreviation='indexed',
                        cdm_holder='Synthetic', source_description='Invented logical workload; probe files are incomplete slices',
                        source_documentation_reference='synthetic:none', cdm_etl_reference='synthetic:none',
                        source_release_date=str(self.end), cdm_release_date=str(self.end),
                        cdm_version=self.parameters['cdm_version'], cdm_version_concept_id=0, vocabulary_version='indexed-1')
        domain = next(d for d in self.domains if self.profile['domains'][d]['table'] == table)
        d = self.domains.index(domain); spec = self.profile['domains'][domain]
        source = index-1 if index%100 == 99 else index
        def draw(slot, size):
            return BASE.mix(self.parameters['seed'] ^ ((d+1)*0x9e3779b97f4a7c15) ^ (source*0xd1b54a32d192ed03) ^ slot)%size
        hot = self.concepts//5
        concept_index = draw(2, hot) if source%100 < 80 else hot+draw(2, self.concepts-hot)
        concept = 0 if source%97 == 0 else self.standard(d, concept_index)
        recipe = dict(self.recipe, concepts_per_domain=self.concepts, known_unit_ids=self.units)
        row = BASE.event_row(self.parameters, recipe, domain, spec, d, index)
        row[spec['concept']] = concept
        if spec['source_concept']:
            row[spec['source_concept']] = None if source%7 == 0 else 0 if source%43 == 0 else self.source_concept(d, concept_index, draw(6, 32))
        if domain in ('measurement', 'observation'):
            row['value_as_concept_id'] = 0 if source%3 else self.standard(d, 0)
        return row


def window(source, table, start, rows):
    if (table not in source.counts or type(start) is not int or type(rows) is not int or
            start < 0 or not 0 <= rows <= MAX_ROWS or start+rows > source.counts[table]):
        raise ValueError('Probe needs an in-range table window of at most 10000 rows')


def render(source, table, start, rows, stream=None, directory=None):
    window(source, table, start, rows)
    began = time.monotonic(); size = 0; digest = hashlib.sha256(); low = None; high = 0
    nulls = {col['name']: 0 for col in source.columns[table]}
    def emit(raw):
        nonlocal size
        size += len(raw)
        if size > MAX_BYTES: raise ValueError('Probe byte budget exceeded')
        if time.monotonic()-began > MAX_SECONDS: raise ValueError('Probe time budget exceeded')
        digest.update(raw)
        if stream is not None: stream.write(raw)
    emit((','.join(nulls)+'\n').encode())
    for offset, index in enumerate(range(start, start+rows)):
        if directory is not None and offset%64 == 0 and shutil.disk_usage(directory).free < MIN_FREE:
            raise ValueError('Probe free-space floor reached')
        row = source.row(table, index); raw = BASE.encode_row(row, source.columns[table]); emit(raw)
        low = len(raw) if low is None else min(low, len(raw)); high = max(high, len(raw))
        for name in nulls:
            if row.get(name) is None: nulls[name] += 1
    if source.plan() != Source(source.tier, source.parameters['cdm_version']).plan():
        raise ValueError('Indexed source inputs changed during probe')
    return dict(kind='indexed_scale_csv_probe', status='complete', plan=source.plan(), table=table,
                start=start, rows=rows, file=table+'.csv', bytes=size, sha256=digest.hexdigest(),
                row_bytes_min=low, row_bytes_max=high, null_counts=nulls,
                full_tier_generated=False, qualifying=False)


def outside(path):
    path = Path(path)
    if path.resolve().is_relative_to(ROOT): raise ValueError('Use output outside the package checkout')
    return path


def probe(directory, tier, version, table, start, rows):
    source = Source(tier, version); window(source, table, start, rows)
    directory = outside(directory)
    if shutil.disk_usage(directory.parent).free < MIN_FREE: raise ValueError('Probe free-space floor reached')
    directory.mkdir(mode=0o700)
    try:
        with (directory/(table+'.csv')).open('xb') as stream: result = render(source, table, start, rows, stream, directory)
        (directory/'probe.json').write_bytes(BASE.canonical(result))
        return result
    except BaseException as error:
        (directory/'failed.json').write_bytes(BASE.canonical(dict(status='failed', error=str(error), full_tier_generated=False, qualifying=False)))
        raise


def verify(directory):
    directory = Path(directory); path = directory/'probe.json'
    if directory.is_symlink() or path.is_symlink() or path.stat().st_size > 256*1024:
        raise ValueError('Invalid probe receipt')
    with path.open('rb') as stream: raw = stream.read(256*1024+1)
    if len(raw) > 256*1024: raise ValueError('Probe receipt byte budget exceeded')
    result = json.loads(raw)
    source = Source(result['plan']['tier'], result['plan']['parameters']['cdm_version'])
    expected = render(source, result['table'], result['start'], result['rows'])
    if result != expected or raw != BASE.canonical(expected): raise ValueError('Probe receipt/replay mismatch')
    names = set()
    for entry in directory.iterdir():
        names.add(entry.name)
        if len(names) > 2: raise ValueError('Probe directory contains unexpected or incomplete files')
    if names != {'probe.json', expected['file']}:
        raise ValueError('Probe directory contains unexpected or incomplete files')
    data = directory/expected['file']
    if data.is_symlink() or not data.is_file() or data.stat().st_size != expected['bytes']: raise ValueError('Probe CSV type/size mismatch')
    digest = hashlib.sha256()
    with data.open('rb') as stream:
        remaining = expected['bytes']
        while chunk := stream.read(min(65536, remaining+1)):
            remaining -= len(chunk)
            if remaining < 0: raise ValueError('Probe CSV grew during verification')
            digest.update(chunk)
        if remaining: raise ValueError('Probe CSV shrank during verification')
    if digest.hexdigest() != expected['sha256']: raise ValueError('Probe CSV hash mismatch')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    plan = sub.add_parser('plan'); plan.add_argument('--output-file', type=Path, required=True)
    sample = sub.add_parser('probe'); sample.add_argument('--output-dir', type=Path, required=True)
    sample.add_argument('--table', required=True); sample.add_argument('--start', type=int, default=0)
    sample.add_argument('--rows', type=int, default=1000)
    for command in [plan, sample]:
        command.add_argument('--tier', choices=['S1', 'S2'], required=True)
        command.add_argument('--cdm-version', choices=['5.3', '5.4', '5.5'], default='5.5')
    check = sub.add_parser('verify'); check.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == 'plan':
            value = Source(args.tier, args.cdm_version).plan()
            with outside(args.output_file).open('xb') as stream: stream.write(BASE.canonical(value))
        elif args.action == 'probe': value = probe(args.output_dir, args.tier, args.cdm_version, args.table, args.start, args.rows)
        else: value = verify(args.output_dir)
    except (ValueError, OSError, KeyError, TypeError) as error: parser.error(str(error))
    print('Indexed source '+args.action+' complete; full-tier execution disabled; qualifying=false')
    return 0


if __name__ == '__main__': raise SystemExit(main())
