"""Deterministic synthetic saved inventory; contributor tooling, no CDM access."""
import hashlib
import json
from pathlib import Path


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                       allow_nan=False) + '\n').encode('utf-8')


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def id_key(value):
    # This fixture uses positive integers only; signed-codec tests live elsewhere.
    value = str(value)
    return f'I1{len(value):06d}:{value}'


def label(value):
    return f'Synthetic concept {value:07d}'


def name_key(value):
    return 'T:' + label(value).lower().encode().hex() + '!' + id_key(value)


def build(directory, count, page_rows=512):
    """Build real closed 2.1.0 pages; full native admission is still mandatory."""
    if type(count) is not int or not 1 <= count <= 1_000_000:
        raise ValueError('Fixture entry count must be between 1 and 1000000')
    if type(page_rows) is not int or not 1 <= page_rows <= 512:
        raise ValueError('Fixture page rows must be between 1 and 512')
    directory = Path(directory)
    directory.mkdir(mode=0o700)  # Refuse replacement, including existing exports.
    artifact = directory / 'artifact'; artifact.mkdir(mode=0o700)
    objects = artifact / 'objects'; objects.mkdir(mode=0o700)
    package = Path(__file__).resolve().parents[2]
    profile_raw = (package / 'inst/analysis/core-characterization-v2.json').read_bytes()
    profile = json.loads(profile_raw)
    rows = json.loads((package / 'inst/contracts/v2/rows.json').read_bytes())
    definitions = {m['id']: m for m in profile['metrics']}
    row_schemas = {m['id']: m for m in rows['metrics']}
    if sha(profile_raw) != rows['profile_sha256']:
        raise ValueError('Profile hash does not match the row contract')
    context = dict(contract_version='2.1.0',
                   publication_id='00000000-0000-4000-8000-000000000061',
                   release_id='00000000-0000-4000-8000-000000000062',
                   source_id='fixture:saved-inventory', profile_id=profile['profile_id'],
                   profile_revision=profile['revision'], profile_sha256=sha(profile_raw),
                   access_scope_id='fixture-inventory')
    totals = dict(objects=0, bytes=0, leaf_rows={})

    def emit(document, kind, n):
        raw = canonical(document); digest = sha(raw)
        limit = 262144 if kind in ('root', 'index') else 4194304 if kind == 'data' else 1048576
        if len(raw) > limit:
            raise ValueError('Fixture page exceeds physical byte limit')
        (objects / (digest + '.json')).write_bytes(raw)
        totals['objects'] += 1; totals['bytes'] += len(raw)
        if kind not in ('root', 'index'):
            totals['leaf_rows'][kind] = totals['leaf_rows'].get(kind, 0) + n
        return dict(sha256=digest, bytes=str(len(raw)), kind=kind, rows=str(n))

    def tree(kind, nodes):
        while len(nodes) > 1:
            parents = []
            for start in range(0, len(nodes), 128):
                children = nodes[start:start+128]
                descriptor = emit(dict(context, kind='index', index_kind=kind, children=children),
                                  'index', sum(int(c['object']['rows']) for c in children))
                parents.append(dict(lower_key=children[0]['lower_key'],
                                    upper_key=children[-1]['upper_key'], object=descriptor))
            nodes = parents
        return nodes[0]['object']

    def row(metric, dimensions, values, refs):
        identity = dict(metric_id=metric, metric_version=definitions[metric]['version'],
                        row_kind='counts', dimensions=dimensions)
        return dict(row_key=sha(canonical(identity)), dimensions=dimensions, values=values,
                    row_kind='counts', state='computed', reason_code=None, denominator_refs=refs)

    person_metric = 'core.person.count'; gender_metric = 'core.person.gender_count'
    person = row(person_metric, {}, dict(person_count=str(count)), [])
    person_page = emit(dict(context, kind='data', metric_id=person_metric,
                            metric_version=definitions[person_metric]['version'], rows=[person]), 'data', 1)
    person_key = person_metric + '|E:counts'
    data = [dict(lower_key=person_key, upper_key=person_key, object=person_page)]
    concept_nodes = []; name_nodes = []; gender_nodes = []
    # Synthetic provenance placeholder, NOT a captureConceptSnapshot file digest.
    # Keep the deterministic entries-only hash; this fixture performs no capture.
    snapshot = hashlib.sha256()
    # Pages and per-page lists only; never allocate a million-row/name map.
    for start in range(1, count+1, page_rows):
        end = min(start+page_rows, count+1)
        entries = [dict(concept_tag=dict(kind='id', value=str(i)), label=label(i),
                        label_state='available', label_reason_code=None,
                        domain_id='Synthetic', vocabulary_id='Fixture') for i in range(start, end)]
        for entry in entries:
            snapshot.update(canonical(entry))
        for kind, nodes, key in [('concept_catalogue', concept_nodes, id_key),
                                 ('terminology', name_nodes, name_key)]:
            d = emit(dict(context, kind=kind, entries=entries), kind, len(entries))
            nodes.append(dict(lower_key=key(start), upper_key=key(end-1), object=d))
        refs = [dict(measure='person_count', metric_id=person_metric, row_key=person['row_key'],
                     field='person_count', value=str(count))]
        gender_rows = [row(gender_metric, dict(gender_concept_id=str(i)), dict(person_count='1'), refs)
                       for i in range(start, end)]
        d = emit(dict(context, kind='data', metric_id=gender_metric,
                      metric_version=definitions[gender_metric]['version'], rows=gender_rows), 'data', len(gender_rows))
        gender_nodes.append(dict(lower_key=gender_metric+'|'+id_key(start)+'|E:counts',
                                 upper_key=gender_metric+'|'+id_key(end-1)+'|E:counts', object=d))
    gender_tree = tree('data', gender_nodes)
    data.append(dict(lower_key=gender_metric+'|'+id_key(1)+'|E:counts',
                     upper_key=gender_metric+'|'+id_key(count)+'|E:counts', object=gender_tree))
    coverage = dict(scope_kind='standard_full', complete=True, excluded_record_count='0', reason_code=None)
    catalogue = []
    for metric, definition in sorted(definitions.items()):
        active = metric in (person_metric, gender_metric)
        catalogue.append(dict(metric_id=metric, version=definition['version'], population=definition['population'],
                              grain=definition['grain'], row_schema_id=row_schemas[metric]['row_schema_id'],
                              definition_sha256=sha(canonical(definition)), state='computed' if active else 'suppressed',
                              reason_code=None if active else 'policy.output_omitted', required=True,
                              conditional_support=dict(state='supported', reason_code=None),
                              rows=str(count if metric == gender_metric else 1 if active else 0), completeness=coverage))
    catalogue_page = emit(dict(context, kind='metric_catalogue', entries=catalogue), 'metric_catalogue', len(catalogue))
    policy = dict(id='fixture-inventory', revision='1', scope_kind='restricted',
                  allow_metrics=[person_metric, gender_metric])
    unknown = dict(state='unknown', value=None, basis=None, assertion_id=None, reason_code='fixture.synthetic')
    metadata = dict(extension_version='1.0.0', matching='ascii-fold-prefix-v1',
                    label_source=dict(state='known', value='synthetic-inventory-v1', basis='deterministic-fixture',
                                      assertion_id='fixture-review', reason_code=None),
                    vocabulary_release=unknown, snapshot_sha256=snapshot.hexdigest(),
                    capture=dict(captured_at='2026-01-01T00:00:00.000Z', within_capture='single_repeatable_read',
                                 with_aggregate_release='not_asserted'))
    root = dict(context, kind='root', scope_kind='restricted', publication_state='ready',
                eligible_for_current_pointer=True, expected_metric_count='142', generated_at='2026-01-01T00:00:00.000Z',
                source_schema=dict(sha256='a'*64, declared_cdm_version='5.5'),
                source_consistency=dict(within_run='unknown', reusable=False, reason_code='fixture.synthetic'),
                disclosure=dict(approval_id='fixture-review', policy=policy, policy_sha256=sha(canonical(policy))),
                catalogue=catalogue_page, concepts=tree('concept_catalogue', concept_nodes),
                terminology=tree('terminology', name_nodes), data=tree('data', data), saved_terminology=metadata)
    descriptor = emit(root, 'root', 0)
    pointer = dict(contract_version=context['contract_version'], publication_id=context['publication_id'],
                   source_id=context['source_id'], access_scope_id=context['access_scope_id'], root=descriptor)
    (artifact / 'publication.json').write_bytes(canonical(pointer))
    context.update(root=descriptor, authorization_epoch='1', instance_id='inventory-fixture')
    manifest = dict(fixture='saved-inventory-v1', count=count, page_rows=page_rows,
                    context=context, inventory=totals, approval='requires_complete_native_admission')
    (directory / 'fixture.json').write_bytes(canonical(manifest))
    return manifest
