"""Fixture safety tests; opt-in integration tests use only the marked sandbox."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "postgresql_fixtures", Path(__file__).resolve().parents[1] / "tools/postgresql_fixtures.py")
fixtures = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixtures)


class FixtureSafetyTests(unittest.TestCase):
    def test_corrupt_cached_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / "cache").mkdir()
            asset = fixtures.LOCK["gibleed"]["assets"]["5.3"]
            (state / "cache" / asset["filename"]).write_bytes(b"modified archive")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                fixtures.archive_path(state, "5.3", download=False)

    def test_unmarked_database_is_rejected(self):
        class OtherDatabase:
            def rows(self, query):
                return [{"db": fixtures.DB, "usr": fixtures.OWNER, "marker": None}]
        with self.assertRaisesRegex(ValueError, "marked fixture sandbox"):
            fixtures.guard_database(OtherDatabase())

    def test_production_database_is_rejected_even_with_same_owner_and_marker(self):
        class OtherDatabase:
            def rows(self, query):
                return [{"db": "production", "usr": fixtures.OWNER, "marker": fixtures.MARKER}]
        with self.assertRaisesRegex(ValueError, "marked fixture sandbox"):
            fixtures.guard_database(OtherDatabase())

    def test_sql_identifiers_cannot_inject_commands(self):
        with self.assertRaises(ValueError):
            fixtures.copy_sql("x; DROP DATABASE postgres", "person", ["person_id"], [[1]])


@unittest.skipUnless(os.environ.get("ACHILLES_NEXT_TEST_STATE"), "Set ACHILLES_NEXT_TEST_STATE for local PostgreSQL integration tests")
class PostgresIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.state = Path(os.environ["ACHILLES_NEXT_TEST_STATE"]).resolve()
        cls.pg = fixtures.Postgres(cls.state)
        fixtures.guard_database(cls.pg)

    def test_unmarked_schema_is_preserved(self):
        pg = self.pg
        schema = "fixture_guard_probe"
        pg.run(f"CREATE SCHEMA {schema}; CREATE TABLE {schema}.keep_me (n integer); "
               f"INSERT INTO {schema}.keep_me VALUES (7);")
        try:
            result = pg.run("BEGIN;" + fixtures.create_schema_sql(schema, "5.3", True) + "COMMIT;", allow_failure=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing to replace", result.stderr)
            self.assertEqual(pg.value(f"SELECT n FROM {schema}.keep_me"), "7")
        finally:
            pg.run(f"DROP SCHEMA {schema} CASCADE;")

    def test_failed_source_rebuild_rolls_back(self):
        pg = self.pg
        schema = "fixture_rollback_probe"
        pg.run(f"CREATE SCHEMA {schema}; COMMENT ON SCHEMA {schema} IS "
               f"{fixtures.literal(fixtures.MARKER + ': ' + schema)}; "
               f"CREATE TABLE {schema}.keep_me (n integer); INSERT INTO {schema}.keep_me VALUES (9);")
        try:
            result = pg.run("BEGIN;" + fixtures.create_schema_sql(schema, "5.4", True) +
                            f"INSERT INTO {schema}.person (person_id) VALUES (1); COMMIT;", allow_failure=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("violates not-null constraint", result.stderr)
            self.assertEqual(pg.value(f"SELECT n FROM {schema}.keep_me"), "9")
        finally:
            pg.run(f"DROP SCHEMA {schema} CASCADE;")

    def test_csv_preserves_null_empty_unicode_and_exact_numeric(self):
        pg = self.pg
        sql = ("BEGIN; CREATE TABLE fixture_results.csv_probe (label text, value numeric);" +
               fixtures.copy_sql("fixture_results", "csv_probe", ["label", "value"],
                                 [[None, None], ["", "0"], ['µg, "quoted"\nsecond line', "9007199254740993.125"]]) +
               "SELECT json_agg(row_to_json(t)) FROM fixture_results.csv_probe t; ROLLBACK;")
        output = pg.value(sql, "runner")
        self.assertIn('"label":null', output)
        self.assertIn('"label":""', output)
        self.assertIn('9007199254740993.125', output)
        self.assertIn('µg,', output)

    def test_synpuf_and_results_survive_fixture_reset(self):
        pg = self.pg
        pg.run("CREATE TABLE cdm_synpuf_53.retention_probe (n integer); INSERT INTO cdm_synpuf_53.retention_probe VALUES (17);")
        try:
            pg.run("CREATE TABLE fixture_results.retention_probe (n integer); INSERT INTO fixture_results.retention_probe VALUES (19);", "runner")
            try:
                fixtures.reset_fixtures(pg, self.state, with_gibleed=False)
                self.assertEqual(pg.value("SELECT n FROM cdm_synpuf_53.retention_probe", "runner"), "17")
                self.assertEqual(pg.value("SELECT n FROM fixture_results.retention_probe", "runner"), "19")
            finally:
                pg.run("DROP TABLE fixture_results.retention_probe;", "runner")
        finally:
            pg.run("DROP TABLE cdm_synpuf_53.retention_probe;")


if __name__ == "__main__":
    unittest.main()
