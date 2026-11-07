"""Contributor-only verified routing comparators; not installed providers or formats."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import tempfile
from urllib.parse import quote

CONTEXT = ('contract_version', 'publication_id', 'release_id', 'source_id', 'profile_id',
           'profile_revision', 'profile_sha256', 'access_scope_id')
LIMITS = dict(root=262144, index=262144, data=4194304, metric_catalogue=1048576,
              concept_catalogue=1048576, terminology=1048576)
BRANCHES = dict(catalogue='metric_catalogue', data='data', concepts='concept_catalogue', terminology='terminology')
INDEX_LIMIT = 8 * 1024**2


def need(ok, message):
    if not ok:
        raise ValueError(message)


def canonical(doc):
    return (json.dumps(doc, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)+'\n').encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def decode(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            need(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    doc = json.loads(raw.decode('utf8'), object_pairs_hook=pairs,
                     parse_constant=lambda value: need(False, 'Non-finite JSON'))
    need(canonical(doc) == raw, 'Noncanonical JSON')
    return doc


def count(value):
    need(isinstance(value, str) and re.fullmatch(r'0|[1-9][0-9]{0,511}', value), 'Invalid exact count')
    return int(value)


def read_file(path, limit):
    path = Path(path)
    need(not path.is_symlink() and path.resolve(strict=True) == path and path.is_file(), 'Unsafe file')
    need(path.stat().st_size <= limit, 'File byte limit')
    with path.open('rb') as stream:
        raw = stream.read(limit+1)
    need(len(raw) <= limit, 'File changed beyond byte limit')
    return raw


class Pages:
    def __init__(self, directory, context):
        self.directory = Path(directory).resolve(strict=True)
        need(set(context) == set(CONTEXT) and context['contract_version'] == '2.0.0', 'Incomplete pinned context')
        self.context = context
        self.stats = Counter()

    def read(self, descriptor):
        need(set(descriptor) == {'sha256', 'bytes', 'kind', 'rows'}, 'Invalid descriptor keys')
        sha = descriptor['sha256']; kind = descriptor['kind']
        need(isinstance(sha, str) and re.fullmatch('[0-9a-f]{64}', sha), 'Invalid object hash')
        need(kind in LIMITS and count(descriptor['bytes']) <= LIMITS[kind], 'Object byte limit')
        count(descriptor['rows'])
        raw = read_file(self.directory/'objects'/(sha+'.json'), LIMITS[kind])
        self.stats['object_reads'] += 1; self.stats['verified_object_bytes'] += len(raw)
        need(len(raw) == count(descriptor['bytes']) and digest(raw) == sha, 'Object integrity mismatch')
        doc = decode(raw)
        need(doc['kind'] == kind and all(doc[k] == v for k, v in self.context.items()), 'Object context mismatch')
        if kind == 'index':
            children = doc['children']
            need(isinstance(children, list) and len(children) <= 128, 'Index fanout limit')
            previous = None
            for child in children:
                need(set(child) == {'lower_key', 'upper_key', 'object'}, 'Invalid child')
                lo, hi = child['lower_key'], child['upper_key']
                need(isinstance(lo, str) and isinstance(hi, str) and 0 < len(lo.encode()) <= 1024
                     and 0 < len(hi.encode()) <= 1024 and lo <= hi and (previous is None or previous < lo), 'Invalid index ranges')
                previous = hi
            need(sum(count(c['object']['rows']) for c in children) == count(descriptor['rows']), 'Index rows mismatch')
        elif kind != 'root':
            rows = doc['rows'] if kind == 'data' else doc['entries']
            need(isinstance(rows, list) and 0 < len(rows) <= 2048 and len(rows) == count(descriptor['rows']), 'Leaf rows mismatch')
        return doc, raw


def origin(directory):
    """Called only by the trusted experiment controller, not an authorization API."""
    directory = Path(directory).resolve(strict=True)
    if (directory/'publication.json').exists():
        pointer = decode(read_file(directory/'publication.json', LIMITS['root']))
        root = decode(read_file(directory/'objects'/(pointer['root']['sha256']+'.json'), LIMITS['root']))
        context = {k: root[k] for k in CONTEXT}
        # Complete native validation is a separate required orchestration step.
        Pages(directory, context).read(pointer['root'])
        return dict(scope='approved_core_artifact', context=context, root=pointer['root'])
    fixture = decode(read_file(directory/'routing.json', LIMITS['root']))
    need(fixture['scope'] == 'routing_fixture_not_an_approved_publication', 'Unknown fixture scope')
    return dict(scope=fixture['scope'], context=fixture['context'], trees=fixture['trees'])


class Tree:
    def __init__(self, directory, pin):
        self.pages = Pages(directory, pin['context']); self.pin = pin
        self.trees = pin.get('trees')
        if self.trees is None:
            root, _ = self.pages.read(pin['root'])
            self.trees = {kind: root[name] for name, kind in BRANCHES.items()}

    def lookup(self, branch, key):
        need(branch in self.trees and isinstance(key, str) and len(key.encode()) <= 1024, 'Invalid lookup')
        descriptor = self.trees[branch]
        for _ in range(9):
            doc, raw = self.pages.read(descriptor)
            if doc['kind'] != 'index':
                need(doc['kind'] == branch, 'Wrong leaf kind')
                return descriptor['sha256'], raw
            need(doc['index_kind'] == branch, 'Wrong index kind')
            child = next((c for c in doc['children'] if c['lower_key'] <= key <= c['upper_key']), None)
            if child is None:
                return None, None
            descriptor = child['object']
        raise ValueError('Index depth limit')

    def routes(self):
        seen = set()
        def walk(branch, descriptor, lo=None, hi=None, depth=0):
            need(depth <= 8 and len(seen) < 100000 and descriptor['sha256'] not in seen, 'Cycle/object/depth limit')
            seen.add(descriptor['sha256']); doc, _ = self.pages.read(descriptor)
            if doc['kind'] == 'index':
                need(doc['index_kind'] == branch, 'Wrong index kind')
                for child in doc['children']:
                    yield from walk(branch, child['object'], child['lower_key'], child['upper_key'], depth+1)
            else:
                need(doc['kind'] == branch, 'Wrong leaf kind')
                # A singleton root leaf has no routing bounds; its whole page is
                # returned and semantic filtering is deliberately outside this pilot.
                yield branch, lo or '', hi or '\U0010ffff', descriptor
        for branch, descriptor in self.trees.items():
            yield from walk(branch, descriptor)

    def close(self):
        pass


def copy_artifact(source, destination):
    source = Path(source).resolve(strict=True); destination = Path(destination)
    need(not destination.exists(), 'Destination must be new')
    destination.mkdir(mode=0o700); (destination/'objects').mkdir(mode=0o700)
    for path in (source/'objects').iterdir():
        need(re.fullmatch('[0-9a-f]{64}\\.json', path.name), 'Unexpected object filename')
        raw = read_file(path, max(LIMITS.values()))
        need(digest(raw) == path.stem, 'Copy integrity mismatch')
        (destination/'objects'/path.name).write_bytes(raw)
    control = 'publication.json' if (source/'publication.json').exists() else 'routing.json'
    (destination/control).write_bytes(read_file(source/control, LIMITS['root']))


def build_flat(directory, pin):
    """Flat indexed partition routing; retain exact v2 bytes for lossless validation."""
    directory = Path(directory); artifact = directory/'artifact'
    tree = Tree(artifact, pin)
    database = directory/'routes.sqlite'
    connection = sqlite3.connect(database)
    try:
        connection.execute('CREATE TABLE route(kind TEXT NOT NULL, upper_key TEXT COLLATE BINARY NOT NULL, lower_key TEXT NOT NULL, descriptor TEXT NOT NULL, PRIMARY KEY(kind,upper_key)) WITHOUT ROWID')
        connection.executemany('INSERT INTO route VALUES (?,?,?,?)',
                               ((kind, hi, lo, canonical(d).decode()) for kind, lo, hi, d in tree.routes()))
        connection.commit()
    finally:
        connection.close(); tree.close()
    raw = read_file(database, INDEX_LIMIT)
    manifest = dict(format='benchmark_flat_partition_index_v1_not_a_product_format',
                    origin=pin, index_sha256=digest(raw), index_bytes=str(len(raw)))
    raw = canonical(manifest); (directory/'flat.json').write_bytes(raw)
    return digest(raw)


class Flat:
    def __init__(self, directory, pin, manifest_sha):
        self.directory = Path(directory).resolve(strict=True)
        self.pages = Pages(self.directory/'artifact', pin['context']); self.temp = None; self.connection = None
        self.branches = set(pin['trees']) if 'trees' in pin else set(BRANCHES.values())
        try:
            raw = read_file(self.directory/'flat.json', LIMITS['root'])
            need(digest(raw) == manifest_sha, 'Flat manifest integrity mismatch')
            manifest = decode(raw)
            need(manifest['format'] == 'benchmark_flat_partition_index_v1_not_a_product_format'
                 and manifest['origin'] == pin, 'Flat manifest context mismatch')
            n = count(manifest['index_bytes']); need(n <= INDEX_LIMIT, 'Flat index byte limit')
            # Hash/copy the entire small index into a private spool before opening
            # SQLite. Concurrent changes to the supplied index cannot affect queries.
            self.temp = tempfile.TemporaryDirectory(prefix='achilles-index-')
            target = Path(self.temp.name)/'routes.sqlite'
            source = self.directory/'routes.sqlite'
            need(not source.is_symlink() and source.resolve(strict=True) == source and source.stat().st_size == n, 'Unsafe flat index')
            h = hashlib.sha256(); size = 0
            with source.open('rb') as src, target.open('xb') as dst:
                while chunk := src.read(65536):
                    size += len(chunk); need(size <= n, 'Flat index changed size'); h.update(chunk); dst.write(chunk)
            need(size == n and h.hexdigest() == manifest['index_sha256'], 'Flat index integrity mismatch')
            self.pages.stats['verified_index_bytes'] = size
            self.pages.stats['manifest_bytes'] = len(raw)
            self.connection = sqlite3.connect('file:'+quote(str(target),safe='/')+'?mode=ro&immutable=1', uri=True)
            for pragma in ['trusted_schema=OFF', 'query_only=ON', 'mmap_size=0', 'cache_size=-64']:
                self.connection.execute('PRAGMA '+pragma)
        except BaseException:
            self.close(); raise

    def lookup(self, branch, key):
        need(branch in self.branches and isinstance(key, str) and len(key.encode()) <= 1024, 'Invalid lookup')
        row = self.connection.execute('SELECT lower_key,upper_key,descriptor FROM route WHERE kind=? AND upper_key>=? ORDER BY upper_key LIMIT 1', (branch, key)).fetchone()
        if row is None or not row[0] <= key <= row[1]:
            return None, None
        descriptor = decode(row[2].encode()); doc, raw = self.pages.read(descriptor)
        need(doc['kind'] == branch, 'Flat leaf kind mismatch')
        return descriptor['sha256'], raw

    def close(self):
        if self.connection is not None:
            self.connection.close(); self.connection = None
        if self.temp is not None:
            self.temp.cleanup(); self.temp = None
