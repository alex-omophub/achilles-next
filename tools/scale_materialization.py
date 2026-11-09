"""Guarded CSV chunk materialization for bounded indexed-source selections.

Local POSIX filesystems only. No database access, full-tier executor, resource
allocation, host permission changes or analytical-result publication.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import stat
import sys
import time
try:
    import fcntl
except ImportError:
    fcntl = None

import scale_cdm as SCALE

MAX_ROWS = 100000
MAX_CHUNKS = 128
MAX_BYTES = 64 * 1024**2
JSON_BYTES = 1024**2
SOURCE_SHA = SCALE.BASE.sha(Path(__file__).read_bytes())
META = {'plan.json', 'checkpoint.json', 'complete.json', 'attempt.json', '.lock', 'STOP'}
SCRATCH = {'checkpoint.json.next', 'complete.json.next', 'attempt.json.next'}


class Stopped(Exception):
    def __init__(self, reason, code=3):
        super().__init__(reason)
        self.code = code


def build_plan(tier, version, windows, chunk_rows=1000, byte_limit=MAX_BYTES,
               seconds=120, min_free=64*1024**2):
    source = SCALE.Source(tier, version)
    for value, lo, hi in [(chunk_rows, 1, 10000), (byte_limit, 1, MAX_BYTES), (min_free, 16*1024**2, 1024**3)]:
        if type(value) is not int or not lo <= value <= hi:
            raise ValueError('Materialization control outside hard bounds')
    if type(seconds) not in (int, float) or not math.isfinite(seconds) or not 1 <= seconds <= 120:
        raise ValueError('Materialization needs a finite 1..120 second invocation budget')
    if type(windows) is not list or not 1 <= len(windows) <= 64:
        raise ValueError('Select 1..64 bounded table windows')
    selected = []
    for item in windows:
        if type(item) is not dict or set(item) != {'table', 'start', 'rows'}:
            raise ValueError('Each selection needs only table/start/rows')
        table, start, rows = item['table'], item['start'], item['rows']
        if (type(table) is not str or table not in source.counts or type(start) is not int or
                type(rows) is not int or start < 0 or rows < 0 or start+rows > source.counts[table]):
            raise ValueError('Selected window outside logical source')
        selected.append(dict(table=table, start=start, rows=rows))
    selected.sort(key=lambda x:(x['table'], x['start']))
    for left, right in zip(selected, selected[1:]):
        if left['table'] == right['table'] and (left['start'] == right['start'] or left['start']+left['rows'] > right['start']):
            raise ValueError('Overlapping or duplicate source windows')
    if sum(w['rows'] for w in selected) > MAX_ROWS:
        raise ValueError('Bounded selection exceeds 100000 rows; full tiers disabled')
    if sum(max(1, (w['rows']+chunk_rows-1)//chunk_rows) for w in selected) > MAX_CHUNKS:
        raise ValueError('Bounded selection exceeds 128 chunks')
    if SCALE.BASE.sha(Path(__file__).read_bytes()) != SOURCE_SHA:
        raise ValueError('Materializer changed after import')
    body = dict(kind='bounded_source_materialization', version=1, source=source.plan(), windows=selected,
                materializer_sha256=SOURCE_SHA, chunk_rows=chunk_rows,
                limits=dict(csv_bytes=byte_limit, invocation_seconds=float(seconds), min_free_bytes=min_free),
                full_tier_generated=False, qualifying=False)
    return dict(body, plan_sha256=SCALE.BASE.sha(SCALE.BASE.canonical(body)))


def layout(plan):
    result = []
    for window in plan['windows']:
        for offset in range(0, max(1, window['rows']), plan['chunk_rows']):
            result.append(dict(file=f'chunk-{len(result):06}.csv', table=window['table'],
                               start=window['start']+offset, rows=min(plan['chunk_rows'], window['rows']-offset)))
    return result


def regular(path, limit, links=(1,)):
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_size > limit or st.st_nlink not in links:
        raise ValueError('Unexpected file type/size/links: ' + path.name)
    return st


def open_file(path, write=False):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL if write else os.O_RDONLY
    fd = os.open(path, flags | os.O_NOFOLLOW, 0o600)
    return os.fdopen(fd, 'wb' if write else 'rb')


def read_json(path):
    regular(path, JSON_BYTES)
    with open_file(path) as stream: raw = stream.read(JSON_BYTES+1)
    if len(raw) > JSON_BYTES: raise ValueError('Metadata byte budget exceeded')
    value = json.loads(raw)
    if raw != SCALE.BASE.canonical(value): raise ValueError('Noncanonical materialization metadata')
    return value


def sync_directory(root):
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)


def atomic_json(root, name, value, exclusive=False):
    raw = SCALE.BASE.canonical(value)
    if len(raw) > JSON_BYTES: raise ValueError('Metadata byte budget exceeded')
    target = root/name; pending = root/(name+'.next')
    if pending.exists() or pending.is_symlink():
        regular(pending, JSON_BYTES); pending.unlink()
    with open_file(pending, True) as stream:
        stream.write(raw); stream.flush(); os.fsync(stream.fileno())
    if exclusive:
        os.link(pending, target, follow_symlinks=False); pending.unlink()
    else:
        if target.exists() or target.is_symlink(): regular(target, JSON_BYTES)
        os.replace(pending, target)
    sync_directory(root)


@contextmanager
def locked(root):
    if fcntl is None: raise ValueError('POSIX file locking is required')
    root = SCALE.outside(root)
    if root.is_symlink() or not root.is_dir(): raise ValueError('Prepared nonsymlink directory required')
    root = root.resolve()
    regular(root/'.lock', 0)
    with open_file(root/'.lock') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            if os.fstat(lock.fileno()).st_ino != (root/'.lock').stat().st_ino:
                raise ValueError('Materialization lock changed')
            yield root
        finally: fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def checkpoint(plan, entries):
    return dict(plan_sha256=plan['plan_sha256'], committed=entries,
                rows=sum(e['rows'] for e in entries), csv_bytes=sum(e['bytes'] for e in entries))


def prepare(root, tier, version, windows, **limits):
    if fcntl is None: raise ValueError('POSIX file locking is required')
    plan = build_plan(tier, version, windows, **limits)
    root = Path(root)
    if root.is_symlink(): raise ValueError('Output directory must not be a symlink')
    root = SCALE.outside(root).resolve()
    if shutil.disk_usage(root.parent).free < plan['limits']['min_free_bytes']:
        raise ValueError('Materialization free-space floor reached')
    root.mkdir(mode=0o700)
    sync_directory(root.parent)
    with open_file(root/'.lock', True): pass
    atomic_json(root, 'plan.json', plan, exclusive=True)
    atomic_json(root, 'checkpoint.json', checkpoint(plan, []))
    return plan


def load_plan(root):
    plan = read_json(root/'plan.json'); source = plan['source']
    expected = build_plan(source['tier'], source['parameters']['cdm_version'], plan['windows'],
                          plan['chunk_rows'], plan['limits']['csv_bytes'],
                          plan['limits']['invocation_seconds'], plan['limits']['min_free_bytes'])
    if SCALE.BASE.canonical(plan) != SCALE.BASE.canonical(expected): raise ValueError('Registered plan or source inputs changed')
    return plan


class Guard:
    def __init__(self, root, plan, stop=None, began=None):
        self.root, self.plan, self.stop = root, plan, stop
        self.began = time.monotonic() if began is None else began
        self.writes = 0

    def check(self, disk=False):
        reason = self.stop() if self.stop else None
        if reason: raise Stopped(reason, 130 if reason == 'SIGINT' else 143)
        if (self.root/'STOP').exists(): raise Stopped('stop_file')
        if time.monotonic()-self.began > self.plan['limits']['invocation_seconds']:
            raise Stopped('invocation_deadline')
        if disk and shutil.disk_usage(self.root).free < self.plan['limits']['min_free_bytes']:
            raise ValueError('Materialization free-space floor reached')

    def emit(self):
        self.check(disk=self.writes%64 == 0); self.writes += 1


class PrefixEnd(Exception): pass


def inspect_chunk(root, desc, source, guard, partial=False):
    path = root/desc['file']; st = regular(path, SCALE.MAX_BYTES, (1, 2))
    with open_file(path) as stream:
        class Compare:
            def write(self, raw):
                guard.emit(); observed = stream.read(len(raw))
                if observed != raw[:len(observed)]: raise ValueError('CSV data differs from registered source')
                if len(observed) < len(raw):
                    if partial: raise PrefixEnd()
                    raise ValueError('Truncated committed CSV')
                return len(raw)
        try: meta = SCALE.render(source, desc['table'], desc['start'], desc['rows'], Compare())
        except PrefixEnd: return None
        if stream.read(1): raise ValueError('CSV has unexpected trailing bytes')
    if st.st_size != meta['bytes']: raise ValueError('CSV size changed during verification')
    return dict(desc, **{key:meta[key] for key in ['bytes','sha256','row_bytes_min','row_bytes_max','null_counts']})


def inventory(root, plan, cp):
    descriptions = layout(plan); entries = cp['committed']
    if type(entries) is not list or len(entries) > len(descriptions): raise ValueError('Invalid committed prefix')
    if SCALE.BASE.canonical(cp) != SCALE.BASE.canonical(checkpoint(plan, entries)):
        raise ValueError('Checkpoint totals or plan binding differ')
    for desc, entry in zip(descriptions, entries):
        if SCALE.BASE.canonical({k:entry.get(k) for k in desc}) != SCALE.BASE.canonical(desc):
            raise ValueError('Checkpoint order differs')
    allowed = set(META)|SCRATCH|{d['file'] for d in descriptions[:len(entries)]}
    if len(entries) < len(descriptions):
        next_file = descriptions[len(entries)]['file']; allowed |= {next_file, next_file.replace('.csv','.part')}
    sizes, names, inodes, completion_links = 0, set(), {}, {}
    for path in root.iterdir():
        names.add(path.name)
        if len(names) > MAX_CHUNKS+12 or path.name not in allowed:
            raise ValueError('Unexpected materialization file')
        csv = path.suffix in ('.csv','.part')
        completion = path.name in ('complete.json','complete.json.next')
        st = regular(path, SCALE.MAX_BYTES if csv else JSON_BYTES, (1,2) if csv or completion else (1,))
        if completion and st.st_nlink == 2:
            completion_links[path.name] = (st.st_dev,st.st_ino)
        if csv:
            key = (st.st_dev, st.st_ino)
            if key not in inodes: sizes += st.st_size
            inodes.setdefault(key, []).append(path.name)
            if st.st_nlink != len(inodes[key]) and st.st_nlink != 2:
                raise ValueError('Unexpected source CSV hard link')
    for key, linked in inodes.items():
        st = (root/linked[0]).stat()
        if st.st_nlink != len(linked): raise ValueError('External hard link in source CSV')
    if completion_links and (set(completion_links) != {'complete.json','complete.json.next'} or
                             len(set(completion_links.values())) != 1):
        raise ValueError('External hard link in completion metadata')
    if sizes > plan['limits']['csv_bytes']: raise ValueError('Registered CSV byte budget exceeded')
    if 'complete.json' in names and len(entries) != len(descriptions):
        raise ValueError('Completion receipt precedes complete checkpoint')
    return descriptions, names


def receipt(plan, cp):
    return dict(kind='bounded_source_selection_complete', plan_sha256=plan['plan_sha256'],
                chunks=cp['committed'], rows=cp['rows'], csv_bytes=cp['csv_bytes'],
                full_tier_generated=False, qualifying=False)


def checked_prefix(root, plan, guard):
    cp = read_json(root/'checkpoint.json'); descriptions, names = inventory(root, plan, cp)
    source = SCALE.Source(plan['source']['tier'], plan['source']['parameters']['cdm_version'])
    for desc, saved in zip(descriptions, cp['committed']):
        guard.check()
        if SCALE.BASE.canonical(inspect_chunk(root, desc, source, guard)) != SCALE.BASE.canonical(saved):
            raise ValueError('Committed checkpoint metadata differs from source')
    return cp, descriptions, names, source


def run(root, max_chunks=MAX_CHUNKS, stop=None):
    if type(max_chunks) is not int or not 1 <= max_chunks <= MAX_CHUNKS:
        raise ValueError('Invocation needs 1..128 chunk limit')
    with locked(root) as root:
        began = time.monotonic(); plan = load_plan(root); guard = Guard(root, plan, stop, began)
        result = dict(status='failed', code=1, full_tier_generated=False, qualifying=False)
        try:
            cp, descriptions, names, source = checked_prefix(root, plan, guard)
            for name in SCRATCH & names: (root/name).unlink()
            done = 0
            while len(cp['committed']) < len(descriptions):
                guard.check(disk=True)
                if done >= max_chunks: raise Stopped('invocation_chunk_limit')
                desc = descriptions[len(cp['committed'])]; final = root/desc['file']
                pending = final.with_suffix('.part')
                if final.exists():
                    meta = inspect_chunk(root, desc, source, guard)
                    if pending.exists():
                        if pending.stat().st_ino != final.stat().st_ino:
                            raise ValueError('Pending file is not the published chunk link')
                        pending.unlink(); sync_directory(root)
                else:
                    if pending.exists():
                        inspect_chunk(root, dict(desc, file=pending.name), source, guard, partial=True)
                        pending.unlink(); sync_directory(root)
                    class Writer:
                        size = 0
                        def write(self, raw):
                            guard.emit()
                            if cp['csv_bytes']+self.size+len(raw) > plan['limits']['csv_bytes']:
                                raise ValueError('Registered CSV byte budget exceeded')
                            count = stream.write(raw)
                            if count != len(raw): raise OSError('Short source CSV write')
                            self.size += count; return count
                    with open_file(pending, True) as stream:
                        meta = SCALE.render(source, desc['table'], desc['start'], desc['rows'], Writer())
                        stream.flush(); os.fsync(stream.fileno())
                    guard.check(); load_plan(root); guard.check()
                    os.link(pending, final, follow_symlinks=False); sync_directory(root)
                    pending.unlink(); sync_directory(root)
                    meta = dict(desc, **{k:meta[k] for k in ['bytes','sha256','row_bytes_min','row_bytes_max','null_counts']})
                if cp['csv_bytes']+meta['bytes'] > plan['limits']['csv_bytes']:
                    raise ValueError('Registered CSV byte budget exceeded')
                guard.check(); load_plan(root); guard.check()
                updated = checkpoint(plan, cp['committed']+[meta])
                atomic_json(root, 'checkpoint.json', updated); cp = updated; done += 1
            if done:
                verified, _, _, _ = checked_prefix(root, plan, guard)
                if SCALE.BASE.canonical(verified) != SCALE.BASE.canonical(cp):
                    raise ValueError('Checkpoint changed before completion')
            expected = receipt(plan, cp)
            if (root/'complete.json').exists():
                if SCALE.BASE.canonical(read_json(root/'complete.json')) != SCALE.BASE.canonical(expected):
                    raise ValueError('Completion receipt differs')
            else:
                guard.check(); load_plan(root); guard.check()
                atomic_json(root, 'complete.json', expected, exclusive=True)
            result.update(status='complete', code=0, rows=cp['rows'], csv_bytes=cp['csv_bytes'])
        except (Exception, KeyboardInterrupt) as error:
            result.update(status='stopped' if isinstance(error,(Stopped,KeyboardInterrupt)) else 'failed',
                          code=error.code if isinstance(error,Stopped) else 130 if isinstance(error,KeyboardInterrupt) else 1,
                          reason=str(error) or 'KeyboardInterrupt')
        result['elapsed_seconds'] = time.monotonic()-guard.began
        atomic_json(root, 'attempt.json', result)
        return result


def verify(root):
    with locked(root) as root:
        began = time.monotonic(); plan = load_plan(root); guard = Guard(root, plan, began=began)
        cp, descriptions, names, _ = checked_prefix(root, plan, guard)
        if len(cp['committed']) != len(descriptions) or names & SCRATCH or any(n.endswith('.part') for n in names):
            raise ValueError('Materialization is incomplete; run to recover')
        expected = receipt(plan, cp)
        if SCALE.BASE.canonical(read_json(root/'complete.json')) != SCALE.BASE.canonical(expected):
            raise ValueError('Completion receipt differs')
        return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    create = commands.add_parser('prepare'); create.add_argument('--selection',type=Path,required=True)
    create.add_argument('--tier',choices=['S1','S2'],required=True)
    create.add_argument('--cdm-version',choices=['5.3','5.4','5.5'],default='5.5')
    create.add_argument('--chunk-rows',type=int,default=1000)
    create.add_argument('--byte-limit',type=int,default=MAX_BYTES)
    create.add_argument('--seconds',type=float,default=120)
    create.add_argument('--min-free-bytes',type=int,default=64*1024**2)
    execute = commands.add_parser('run'); execute.add_argument('--max-chunks',type=int,default=MAX_CHUNKS)
    check = commands.add_parser('verify')
    for command in [create, execute, check]: command.add_argument('--output-dir',type=Path,required=True)
    args = parser.parse_args(); old = {}; interrupted = [None]
    try:
        if args.action == 'prepare':
            regular(args.selection, 65536)
            with open_file(args.selection) as stream: raw = stream.read(65537)
            if len(raw) > 65536: raise ValueError('Selection byte budget exceeded')
            selected = json.loads(raw)
            prepare(args.output_dir,args.tier,args.cdm_version,selected,chunk_rows=args.chunk_rows,
                    byte_limit=args.byte_limit,seconds=args.seconds,min_free=args.min_free_bytes)
            print('prepared bounded source selection'); return 0
        if args.action == 'verify':
            value = verify(args.output_dir); print('verified '+str(value['rows'])+' selected rows'); return 0
        def interrupt(signum,frame): interrupted[0] = signal.Signals(signum).name
        for signum in [signal.SIGINT,signal.SIGTERM]: old[signum] = signal.signal(signum,interrupt)
        value = run(args.output_dir,args.max_chunks,lambda:interrupted[0])
        print(value['status']+': '+str(args.output_dir)); return value['code']
    except Stopped as error:
        print('Materialization stopped: '+str(error),file=sys.stderr); return error.code
    except (ValueError,OSError,KeyError,TypeError) as error:
        print('Materialization refused: '+str(error),file=sys.stderr); return 1
    finally:
        for signum,handler in old.items(): signal.signal(signum,handler)


if __name__ == '__main__': raise SystemExit(main())
