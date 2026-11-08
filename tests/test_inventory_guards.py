"""No mirror mutation before both independently resolved targets are guarded."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock,patch

_import_path = sys.path[:]
try:
    sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools/benchmark'))
    import inventory_database as MIRROR
finally:
    sys.path[:] = _import_path


class InventoryGuardsTest(unittest.TestCase):
    @staticmethod
    def connections(**change):
        facts=dict(db=MIRROR.DB,usr='achilles_next_fixture_owner',marker=MIRROR.MARKER);facts.update(change)
        identity=json.dumps(dict(started='2026-01-01 00:00:00+00',port='5432'))
        admin=Mock();admin.value.side_effect=[MIRROR.MARKER,identity]
        owner=Mock();owner.rows.return_value=[facts];owner.value.return_value=identity
        return admin,owner

    def test_correct_independent_connections_pass_without_mutation(self):
        admin,owner=self.connections();MIRROR.guard_connections(admin,owner)
        admin.run.assert_not_called();owner.run.assert_not_called()

    def test_owner_database_role_and_marker_mismatches_are_refused(self):
        for change in [dict(db='postgres'),dict(usr='other'),dict(marker=None)]:
            with self.subTest(change=change):
                admin,owner=self.connections(**change)
                with self.assertRaisesRegex(ValueError,'owned, marked fixture sandbox'):
                    MIRROR.guard_connections(admin,owner)
                admin.run.assert_not_called();owner.run.assert_not_called()

    def test_different_instances_with_valid_fixture_markers_are_refused(self):
        admin,owner=self.connections();owner.value.return_value=json.dumps(dict(started='different',port='5432'))
        with self.assertRaisesRegex(ValueError,'different PostgreSQL instances'):
            MIRROR.guard_connections(admin,owner)
        admin.run.assert_not_called();owner.run.assert_not_called()

    def test_bad_owner_is_refused_before_output_role_schema_or_copy(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);fixture=root/'fixture';fixture.mkdir();output=root/'output'
            manifest=dict(fixture='saved-inventory-v1',context=dict(root=dict(sha256='a'*64)))
            raw=json.dumps(manifest).encode();(fixture/'fixture.json').write_bytes(raw)
            (fixture/'admission.json').write_text(json.dumps(dict(status='passed',fixture_sha256=MIRROR.sha(raw),root_sha256='a'*64)))
            (fixture/'run-reads.json').write_text(json.dumps(dict(status='passed',root_sha256='a'*64)))
            admin,owner=self.connections(db='postgres')
            argv=['inventory_database.py','--state',str(root),'--fixture',str(fixture),'--output-dir',str(output)]
            with patch.object(sys,'argv',argv),patch.object(MIRROR,'Postgres',side_effect=[admin,owner]),patch.object(MIRROR,'require_process_telemetry'):
                with self.assertRaisesRegex(ValueError,'owned, marked fixture sandbox'):MIRROR.main()
            self.assertFalse(output.exists());admin.run.assert_not_called();owner.run.assert_not_called()

    def test_reader_host_preserves_tcp_and_maps_socket_explicitly(self):
        self.assertEqual(MIRROR.reader_host('localhost'),'localhost')
        self.assertEqual(MIRROR.reader_host('127.0.0.2'),'127.0.0.2')
        self.assertEqual(MIRROR.reader_host('/tmp'),'127.0.0.1')
        self.assertEqual(MIRROR.reader_host('/tmp','localhost'),'localhost')
        for host in ['/other/socket','',' localhost','localhost ','host name','host\tname','host\nname']:
            with self.subTest(host=host),self.assertRaisesRegex(ValueError,'TCP hostname'):
                MIRROR.reader_host('/tmp',host)
