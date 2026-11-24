#!/usr/bin/env python3
"""Validate the optional SQL-to-candidate bridge using tiny marked fixtures."""
import argparse
from decimal import getcontext
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile

import test_core_characterization as core
from postgresql_fixtures import Postgres, DB, MARKER, identifier, literal

ROOT = Path(__file__).resolve().parents[1]



def verify_matrix_coverage(report, matrix):
    """Reject absent or duplicate attempts before grouping a declared matrix."""
    expected = {(case['id'], version, strategy) for case, version in matrix
                for strategy in ('weighted', 'reference')}
    assert expected and len(expected) == len(matrix) * 2, 'Duplicate or empty declared fixture matrix'
    snapshots = report['snapshots']
    assert isinstance(snapshots, list), 'Expected snapshot list'
    actual = []
    for snapshot in snapshots:
        assert isinstance(snapshot, dict), 'Expected snapshot object'
        identity = tuple(snapshot.get(key) for key in ('case', 'version', 'strategy'))
        assert all(isinstance(value, str) for value in identity), 'Missing snapshot identity'
        actual.append(identity)
    assert len(actual) == len(set(actual)), 'Duplicate fixture/operator snapshot'
    assert set(actual) == expected, 'Fixture/operator matrix incomplete or unexpected'
    return expected


def verify(report, cases):
    """Use physical inputs and existing independent report oracles, never flags alone."""
    assert len(report['snapshots']) == len(cases) * 2
    seen = set()
    for snap in report['snapshots']:
        identity = snap['case'], snap['strategy']
        assert identity not in seen
        seen.add(identity)
        assert snap['strategy'] in ('weighted', 'reference')
        case = cases[snap['case']]
        core.verify(snap, case)
        model = core.physical(case, snap['version'])
        expected = core.source_audit_expected(model)
        assert snap['source_audit'] == expected, identity
        receipt = snap['source_receipt']
        assert receipt['audit_totals'] == expected, identity
        assert receipt['cleanup'] == dict(transaction='rolled_back', connection='disconnected')
        assert receipt['publication_changed'] is False
        assert len(receipt['inventory']) == 142
        candidate = snap['candidate']
        assert candidate['state'] == 'building'
        assert candidate['profile_complete'] is True and candidate['publishable'] is False
        assert candidate['publication_changed'] is False
        assert candidate['source_store_separate'] is True
        assert snap['missing_denominator_targets'] == '0'
        assert snap['denominator_edges'] != '0' or snap['case'] == 'empty_source'
        assert snap['exact_legacy_rows'] is True and snap['exact_legacy_datasets'] is True
        assert snap['validated_with_source_denied'] is True
    assert seen == {(case, strategy) for case in cases for strategy in ('weighted', 'reference')}
    isolation = report['isolation']
    assert isolation['different_principals'] is True
    assert isolation['source_store_access'] is False
    assert isolation['store_source_access'] is False
    assert isolation['source_write_access'] is False
    assert isolation['replay_source_access_revoked'] is True
    assert isolation['bounded_writer_batches'] is True
    failures = report['failures']
    assert failures['status'] == 'passed'
    assert failures['cases'] == dict(
        store_readiness='candidate.store_unavailable', scratch_bytes='candidate.scratch_byte_limit',
        source_stage_limit='candidate.source_failed', before_capture_cancel='candidate.cancelled',
        partial_capture='candidate.source_failed', query_timeout_forwarding='candidate.source_failed',
        source_cleanup_failure='candidate.source_failed', missing_denominator='candidate.store_failed',
        replay_cancel='candidate.cancelled', source_audit_mismatch='candidate.store_failed',
        receipt_count_mismatch='candidate.invalid_capture', control_disk_io='candidate.scratch_io_failure',
        partial_store_write='candidate.store_failed', required_scratch_cleanup='candidate.cleanup_failed',
        commit_acknowledgement_lost='candidate.commit_unknown')
    assert failures['partial_capture_rows'] == 3 and failures['partial_store_flush'] is True
    for key in ('source_cleanup', 'scratch_cleanup', 'previous_publication_preserved'):
        assert failures[key] is True
    acknowledgement = failures['commit_acknowledgement']
    assert acknowledgement['reason_code'] == 'candidate.commit_unknown'
    assert acknowledgement['outcome'] == 'unknown'
    assert acknowledgement['diagnostic_candidate_state'] == 'building'
    assert acknowledgement['automatic_promotion'] is False
    return dict(status='passed', cases=len(cases), programs=len(seen), metrics=142,
                numeric_parity='138 independently checked outputs per program',
                canonical_parity='all row identities, denominator references and dataset descriptors',
                source_audits='independent raw physical inputs', separate_principals=True,
                failures=report['failures'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', required=True, type=Path)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--full-matrix', action='store_true')
    mode.add_argument('--copy-only', action='store_true', help='Run only the PostgreSQL COPY/rollback/parity fixture')
    parser.add_argument('--admin-host', default='/tmp')
    parser.add_argument('--admin-user')
    parser.add_argument('--port', type=int, default=5432)
    args = parser.parse_args()
    getcontext().prec = 256
    out = core.measurement.base.create_evidence_dir(args.output_dir)
    case = core.measurement.fixture()
    empty = dict(case, id='empty_source', person=[], events=[], observation_period=[])
    cases = {case['id']: case, empty['id']: empty}
    matrix = [(case, '5.5'), (empty, '5.5')]
    if args.copy_only:
        matrix = [(case, '5.5')]
    if args.full_matrix:
        tail = core.observation_tail_fixture(case)
        cases[tail['id']] = tail
        matrix = [(case, version) for version in ('5.3', '5.4', '5.5')] + [(empty, '5.5'), (tail, '5.5')]
    (out / 'input.json').write_text(json.dumps([
        dict(case=c['id'], version=v, **core.physical(c, v)) for c, v in matrix]))
    subprocess.run(['Rscript', '--vanilla', 'tests/tracer/characterization-candidate-sql-offline.R',
                    str(out / 'input.json')], cwd=ROOT, check=True)
    admin = Postgres(args.state, admin=True, host=args.admin_host, port=args.port, admin_user=args.admin_user)
    if admin.value(f"SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname={literal(DB)}") != MARKER:
        raise RuntimeError('Refusing unmarked database')
    suffix = secrets.token_hex(6)
    roles = {kind: dict(user='achilles_test_bridge_' + kind + '_' + suffix,
                        password=secrets.token_urlsafe(32), port=args.port) for kind in ('source', 'store')}
    roles['reader'] = dict(user='achilles_test_reader_' + suffix, password=secrets.token_urlsafe(32), port=args.port)
    created = []
    try:
        for kind, value in roles.items():
            role = value['user']
            admin.run(f'CREATE ROLE {identifier(role)} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE '
                      f'NOREPLICATION NOBYPASSRLS PASSWORD {literal(value["password"])}; '
                      f'GRANT CONNECT ON DATABASE {identifier(DB)} TO {identifier(role)};')
            created.append(role)
        admin.run(f'GRANT TEMPORARY ON DATABASE {identifier(DB)} TO {identifier(roles["source"]["user"])}, {identifier(roles["store"]["user"])};')
        with tempfile.TemporaryDirectory(prefix='achilles-bridge-') as folder:
            path = Path(folder) / 'roles.json'
            path.touch(mode=0o600)
            path.write_text(json.dumps(roles))
            reader_path = Path(folder) / 'reader.json'
            reader_path.touch(mode=0o600)
            reader_path.write_text(json.dumps(roles['reader']))
            env = os.environ.copy()
            env['ACHILLES_NEXT_BRIDGE_FIXTURE'] = str(path)
            env['ACHILLES_NEXT_SERVING_FIXTURE'] = str(reader_path)
            env['ACHILLES_NEXT_FIXTURE_STATE'] = str(args.state.resolve())
            subprocess.run(['Rscript', '--vanilla', 'tests/tracer/characterization-candidate-sql-native.R',
                            str(args.config.resolve()), str(out)] + (['--copy-only'] if args.copy_only else []), cwd=ROOT, env=env, check=True)
        if args.copy_only:
            proof = json.loads((out / 'copy-result.json').read_text())
            assert proof['metrics'] == 45 and proof['parity_reports'] == 138 and proof['paired_pages'] > 0
            print('PostgreSQL COPY cancellation, rollback and exact numerical parity passed')
            return
        report = json.loads((out / 'report.json').read_text())
        verify_matrix_coverage(report, matrix)
        # Full-matrix runs contain repeated case IDs at different versions.
        if args.full_matrix:
            by_version = {}
            for snap in report['snapshots']:
                by_version.setdefault(snap['version'], []).append(snap)
            for version, snaps in by_version.items():
                selected = {snap['case']: cases[snap['case']] for snap in snaps}
                verify(dict(report, snapshots=snaps), selected)
            summary = dict(status='passed', fixtures=len(matrix), programs=len(report['snapshots']), metrics=142)
        else:
            summary = verify(report, cases)
        publication = report['compiled_publication']
        selected = core.publication_snapshot(report['snapshots'], publication)
        assert selected['source_receipt']['kind'] == 'characterization_execution_receipt'
        assert selected['source_receipt']['program_sha256'] == publication['program_sha256']
        assert selected['candidate']['source_receipt'] == selected['source_receipt']
        summary['publication'] = core.verify_publication(out, dict(report, publication=publication), require_refresh=False)
        for key in ('source_denied_operator', 'serving_only_reader', 'semantic_file_database_parity',
                    'only_approved_view_queries', 'cancelled_newer_attempt_preserved', 'pinned_providers_preserved'):
            assert publication[key] is True, key
        assert publication['cancelled_capture_rows'] == 3
        (out / 'oracle.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(summary)
    finally:
        admin.args[admin.args.index('-d') + 1] = DB
        for role in reversed(created):
            admin.run(f'DROP OWNED BY {identifier(role)}; DROP ROLE {identifier(role)};')


if __name__ == '__main__':
    main()
