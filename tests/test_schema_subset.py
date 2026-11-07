import importlib.util
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('schema_subset',ROOT/'tools/check_schema_subset.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)


class SchemaSubsetTests(unittest.TestCase):
    def test_current_native_schemas_and_locks(self):
        audit.main()

    def test_conditional_or_external_vocabulary_is_not_silently_ignored(self):
        for schema in [dict(allOf=[]),dict(type=['string','null']),{'$ref':'https://example.invalid/schema'},
                       dict(format='email'),dict(additionalProperties=dict(type='string'))]:
            with self.assertRaises(ValueError):audit.audit_schema(schema,{})

    def test_ref_siblings_and_unknown_targets_fail(self):
        root={'$id':'urn:test','$defs':{'text':{'type':'string'}}}
        audit.audit_schema({'$ref':'#/$defs/text'},root)
        audit.audit_schema({'$ref':'urn:test#/$defs/text'},root)
        for schema in [{'$ref':'#/$defs/missing'},{'$ref':'#/$defs/text','maxLength':1}]:
            with self.assertRaises(ValueError):audit.audit_schema(schema,root)

    def test_exact_string_counts_remain_patterns_not_floating_arithmetic(self):
        result=audit.audit_schema({'type':'string','pattern':'^(0|[1-9][0-9]*)$'}, {})
        self.assertEqual(result['pattern'],1)

    def test_nested_resource_ids_are_rejected_without_changing_root_refs(self):
        root={'$id':'urn:test','$defs':{'text':{'type':'string'}}}
        audit.audit_schema(root,root)
        for schema in [
            {'$id':'urn:child','$ref':'#/$defs/text'},
            {'properties':{'value':{'$id':'urn:child','type':'string'}}},
            {'$defs':{'child':{'$id':'urn:child','type':'string'}}},
        ]:
            with self.assertRaisesRegex(ValueError,'nested'):audit.audit_schema(schema,root)


if __name__=='__main__':unittest.main()
