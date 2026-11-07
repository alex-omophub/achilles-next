#!/usr/bin/env python3
"""Audit core schemas consumed by finite native R; not a JSON Schema validator."""
from collections import Counter
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUPPORTED = {'$schema','$id','$defs','$ref','title','description','$comment','default','examples',
             'type','const','enum','oneOf','anyOf','required','properties','additionalProperties',
             'items','minItems','maxItems','uniqueItems','minLength','maxLength','pattern','format','minimum','maximum'}
ANNOTATIONS = {'$schema','$id','$defs','title','description','$comment','default','examples'}


def audit_schema(schema, root):
    """Reject unsupported native vocabulary/refs; no values or arithmetic checked."""
    if not isinstance(schema,dict):raise ValueError('Native schema must be an object')
    unknown = set(schema)-SUPPORTED
    if unknown:raise ValueError('Unsupported native schema keywords: '+','.join(sorted(unknown)))
    if '$ref' in schema:
        if set(schema)-ANNOTATIONS-{'$ref'}:raise ValueError('Native $ref semantic siblings are not supported')
        ref = schema['$ref']; prefix = '#/$defs/'
        if root.get('$id') and ref.startswith(root['$id']):ref = ref[len(root['$id']):]
        if not ref.startswith(prefix) or ref[len(prefix):] not in root.get('$defs',{}):raise ValueError('Nonlocal or unknown native reference')
    if 'type' in schema and schema['type'] not in ['object','array','null','string','boolean','integer','number']:
        raise ValueError('Unsupported native schema type')
    if 'format' in schema and schema['format'] not in ['date','date-time']:raise ValueError('Unsupported native format')
    if 'additionalProperties' in schema and type(schema['additionalProperties']) is not bool:
        raise ValueError('Native additionalProperties must be boolean')
    seen = Counter(schema.keys())
    for key in ['properties','$defs']:
        for child in schema.get(key,{}).values():seen.update(audit_schema(child,root))
    for key in ['oneOf','anyOf']:
        for child in schema.get(key,[]):seen.update(audit_schema(child,root))
    if 'items' in schema:seen.update(audit_schema(schema['items'],root))
    return seen


def main():
    directory = ROOT/'inst/contracts/v2'
    lock = json.loads((directory/'schema-lock.json').read_text())
    expected = {'rows.json','dimensions.json','metadata.schema.json','row.schema.json'}
    if set(lock['sha256']) != expected:raise ValueError('Unexpected core schema inventory')
    for name, sha in lock['sha256'].items():
        if hashlib.sha256((directory/name).read_bytes()).hexdigest()!=sha:raise ValueError('Schema lock mismatch: '+name)
    metadata = json.loads((directory/'metadata.schema.json').read_text())
    dimensions = json.loads((directory/'dimensions.json').read_text())
    seen = audit_schema(metadata,metadata)
    for schema in dimensions.values():seen.update(audit_schema(schema,metadata))
    print(json.dumps(dict(status='passed',scope='native-consumed core metadata and dimension schemas only',
        dimensions=len(dimensions),native_keywords=sorted(seen),
        row_schema='Generated conditional row.schema.json is an independent Ajv oracle, not consumed by .nv_schema',
        exclusions='No numerical, denominator, policy, complete-publication or transport certification'),sort_keys=True))


if __name__=='__main__':main()
