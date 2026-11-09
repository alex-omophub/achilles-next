"""Read-only, bounded cgroup-v2 audit of an already running synthetic pair.

The operator supplies Docker's immutable container IDs and host init PIDs. This
observer never launches/stops workloads, creates cgroups or changes limits.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import sys
import time

MAX_FILE = 65536
MAX_GROUPS = 64
MAX_PIDS = 1024
MAX_JOURNAL = 16 * 1024**2
COUNTERS = ('memory.current', 'memory.peak', 'memory.max', 'memory.stat',
            'memory.events', 'memory.swap.current', 'memory.swap.max',
            'cpu.stat', 'cpu.max', 'io.stat', 'pids.current', 'pids.max')
SOURCE_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def read(path):
    with path.open('rb') as stream:
        raw = stream.read(MAX_FILE + 1)
    if len(raw) > MAX_FILE:
        raise ValueError('Counter/proc file exceeds audit byte budget')
    return raw.decode('ascii')


def group_path(value):
    path = PurePosixPath(value)
    if (not value.startswith('/') or value.startswith('//') or
            str(path) != value or '..' in path.parts):
        raise ValueError('Canonical absolute cgroup path required')
    return path


def unified(value):
    entries = [line[3:] for line in value.splitlines() if line.startswith('0::')]
    if len(entries) != 1:
        raise ValueError('One unified cgroup-v2 membership required')
    return group_path(entries[0])


def number(value):
    if not re.fullmatch('[0-9]+', value):
        raise ValueError('Invalid unsigned cgroup counter')
    return int(value)


def keyed(value):
    result = {}
    for line in value.splitlines():
        key, raw = line.split()
        if key in result:
            raise ValueError('Duplicate cgroup counter')
        result[key] = number(raw)
    return result


def limit(value):
    return None if value.strip() == 'max' else number(value.strip())


def controls(raw):
    quota, period = raw['cpu.max'].split()
    period = number(period)
    if not period:
        raise ValueError('Zero CPU period')
    return dict(memory_bytes=limit(raw['memory.max']),
                swap_bytes=limit(raw['memory.swap.max']),
                pids=limit(raw['pids.max']), cpu_quota_usec=limit(quota), cpu_period_usec=period)


def pid_namespace(directory):
    namespace = os.readlink(directory / 'ns/pid')
    if not re.fullmatch(r'pid:\[[0-9]+\]', namespace):
        raise ValueError('PID namespace identifier unavailable or invalid')
    return namespace


def proc_identity(proc, pid):
    directory = proc / str(pid)
    # comm can contain spaces and parentheses. Fields after its final ')' start
    # at field3, so starttime (field22) is index19 in the remaining sequence.
    stat = read(directory / 'stat').rsplit(')', 1)[1].split()
    return dict(pid=pid, start_ticks=number(stat[19]), pid_namespace=pid_namespace(directory),
                cgroup=str(unified(read(directory / 'cgroup'))))


class Audit:
    def __init__(self, root, proc, parent, containers):
        self.root, self.proc = Path(root), Path(proc)
        self.parent = group_path(parent)
        if not re.fullmatch(r'achillesnext-validation[-a-z0-9.]*', self.parent.name):
            raise ValueError('Use a dedicated achillesnext-validation cgroup parent')
        if set(containers) != {'runner', 'postgres'}:
            raise ValueError('Exactly runner and postgres identities required')
        self.groups, self.identities, self.inodes = {}, {}, {}
        for role, item in containers.items():
            cid, pid = item['id'], item['pid']
            if not re.fullmatch('[0-9a-f]{64}', cid) or type(pid) is not int or pid <= 0:
                raise ValueError('Full Docker container ID and positive host PID required')
            identity = proc_identity(self.proc, pid)
            group = group_path(identity['cgroup'])
            if group.parent != self.parent or group.name not in (cid, 'docker-' + cid + '.scope'):
                raise ValueError('Container is not a direct child of the declared common parent')
            self.groups[role], self.identities[role] = group, identity
        if len(set(self.groups.values())) != 2:
            raise ValueError('Runner and postgres must be distinct containers')
        self.observer_namespace = pid_namespace(self.proc / 'self')
        namespaces = {value['pid_namespace'] for value in self.identities.values()}
        if len(namespaces) != 2 or self.observer_namespace in namespaces:
            raise ValueError('Containers require separate PID namespaces outside the observer host namespace')
        for group in [self.parent, *self.groups.values()]:
            directory = self.directory(group)
            st = directory.stat()
            self.inodes[str(group)] = (st.st_dev, st.st_ino)
        # A namespace-private or unrelated cgroup mount must not pass by merely
        # containing the named directories. Confirm the observer in the same view.
        self.observer = unified(read(self.proc / 'self/cgroup'))
        if self.observer == self.parent or self.parent in self.observer.parents:
            raise ValueError('Observer must be outside the measured subtree')
        if os.getpid() not in self.pids(self.directory(self.observer)):
            raise ValueError('Observer PID/cgroup namespace or mount does not match')

    def directory(self, group):
        directory = self.root
        if directory.is_symlink():
            raise ValueError('Symlink cgroup root')
        for part in group.parts[1:]:
            directory = directory / part
            if directory.is_symlink():
                raise ValueError('Symlink cgroup path')
        return directory

    def pids(self, directory):
        raw = read(directory / 'cgroup.procs').split()
        if len(raw) > MAX_PIDS:
            raise ValueError('Process inventory exceeds audit budget')
        return [number(pid) for pid in raw]

    def membership(self):
        for role, expected in self.identities.items():
            if proc_identity(self.proc, expected['pid']) != expected:
                raise ValueError('Container PID identity or cgroup changed: ' + role)
        counts = {role: 0 for role in self.groups}
        found = set()
        stack, groups, total = [self.parent], 0, 0
        while stack:
            group = stack.pop()
            groups += 1
            if groups > MAX_GROUPS:
                raise ValueError('Cgroup inventory exceeds audit budget')
            directory = self.directory(group)
            if str(group) in self.inodes:
                st = directory.stat()
                if (st.st_dev, st.st_ino) != self.inodes[str(group)]:
                    raise ValueError('Cgroup identity changed')
            role = next((name for name, base in self.groups.items()
                         if group == base or base in group.parents), None)
            if group != self.parent and role is None:
                raise ValueError('Unrelated cgroup in measured parent')
            pids = self.pids(directory)
            total += len(pids)
            if total > MAX_PIDS:
                raise ValueError('Process inventory exceeds audit budget')
            if group == self.parent and pids:
                raise ValueError('Unattributed process in measured parent')
            if role:
                for pid in pids:
                    try:
                        identity = proc_identity(self.proc, pid)
                    except FileNotFoundError:
                        # A worker may exit between cgroup.procs and /proc reads.
                        # Missing init PIDs still fail the required found check.
                        continue
                    if identity['pid_namespace'] != self.identities[role]['pid_namespace']:
                        raise ValueError('Unrelated PID namespace in container cgroup: ' + role)
                    if identity['cgroup'] != str(group):
                        raise ValueError('Sampled process cgroup changed: ' + role)
                    counts[role] += 1
                    if pid == self.identities[role]['pid']:
                        found.add(role)
            # Bound enumeration itself, including empty/foreign groups. Files
            # such as memory.stat are ignored without reading process commands.
            with os.scandir(directory) as entries:
                for entry in entries:
                    if entry.is_symlink():
                        raise ValueError('Symlink in cgroup inventory')
                    if entry.is_dir(follow_symlinks=False):
                        stack.append(group / entry.name)
                        if groups + len(stack) > MAX_GROUPS:
                            raise ValueError('Cgroup inventory exceeds audit budget')
        if found != set(self.groups):
            raise ValueError('Container init PID absent from declared subtree')
        observer = unified(read(self.proc / 'self/cgroup'))
        if observer != self.observer or os.getpid() not in self.pids(self.directory(observer)):
            raise ValueError('Observer membership changed')
        return dict(groups=groups, processes=counts)

    def sample(self):
        membership = self.membership()
        directory = self.directory(self.parent)
        raw, missing = {}, []
        for name in COUNTERS:
            try:
                raw[name] = read(directory / name)
            except OSError:
                raw[name] = None
                missing.append(name)
        # Keep raw missing states in the journal, rather than replacing with0.
        metrics, member_controls = {}, {}
        for role, group in self.groups.items():
            values = {}
            for name in ('memory.max', 'memory.swap.max', 'cpu.max', 'pids.max'):
                try:
                    values[name] = read(self.directory(group) / name)
                except OSError:
                    values[name] = None
                    missing.append(role + '/' + name)
            member_controls[role] = values
        if not missing:
            metrics = dict(memory_current_bytes=number(raw['memory.current'].strip()),
                           memory_lifetime_peak_bytes=number(raw['memory.peak'].strip()),
                           cpu=keyed(raw['cpu.stat']), memory=keyed(raw['memory.stat']),
                           memory_events=keyed(raw['memory.events']),
                           swap_current_bytes=number(raw['memory.swap.current'].strip()),
                           pids_current=number(raw['pids.current'].strip()),
                           controls=controls(raw), io={})
            for line in raw['io.stat'].splitlines():
                device, *values = line.split()
                if not re.fullmatch('[0-9]+:[0-9]+', device) or device in metrics['io']:
                    raise ValueError('Invalid IO device')
                metrics['io'][device] = {key: number(value) for key, value in
                                         (item.split('=', 1) for item in values)}
            for values in member_controls.values():
                controls(values)
            if not {'anon', 'file'} <= metrics['memory'].keys() or 'usage_usec' not in metrics['cpu']:
                raise ValueError('Required CPU/cache counters absent')
        # Detect process moves, exits or replacement during the counter read.
        self.membership()
        return dict(membership=membership, raw=raw, member_controls=member_controls,
                    unavailable=missing, metrics=metrics)


def sampling_limits(seconds, interval):
    if not all(type(v) in (int, float) and math.isfinite(v) for v in (seconds, interval)):
        raise ValueError('Finite audit interval/duration required')
    if not 1 <= seconds <= 60 or not .25 <= interval <= 5:
        raise ValueError('Audit needs 1..60 seconds and .25..5 second samples')


def capture(root, proc, parent, containers, output, seconds=5, interval=.5):
    sampling_limits(seconds, interval)
    output = Path(output)
    output.mkdir(mode=0o700)  # exclusive: never overwrite a prior audit
    record = dict(status='running', qualifying=False, samples=0,
                  parent=parent, containers=containers,
                  observer_sha256=SOURCE_SHA256,
                  interval_seconds=interval, requested_seconds=seconds,
                  scope='parent subtree including charged cache; peak since cgroup creation, not an interval peak',
                  cache='uncontrolled; no reclaim, peak reset or host configuration change',
                  allocation_verified=False, stop_authority=False,
                  limits='observer only; does not enforce workload CPU/memory/disk ceilings')
    start = time.monotonic()
    journal_bytes, peak, first_cpu, last_cpu = 0, None, None, None
    previous_peak = None
    try:
        if hashlib.sha256(Path(__file__).read_bytes()).hexdigest() != SOURCE_SHA256:
            raise ValueError('Observer source changed since loading')
        audit = Audit(root, proc, parent, containers)
        record['identities'] = audit.identities
        record['observer_cgroup'] = str(audit.observer)
        record['observer_pid_namespace'] = audit.observer_namespace
        with (output / 'samples.jsonl').open('x') as journal:
            while True:
                sample = audit.sample()
                sample['elapsed_seconds'] = time.monotonic() - start
                line = json.dumps(sample, separators=(',', ':')) + '\n'
                journal_bytes += len(line.encode('utf-8'))
                if journal_bytes > MAX_JOURNAL or record['samples'] >= 242:
                    raise ValueError('Audit journal budget exceeded')
                journal.write(line); journal.flush()
                record['samples'] += 1
                if sample['unavailable']:
                    raise ValueError('Required counters unavailable: ' + ', '.join(sample['unavailable']))
                metrics = sample['metrics']
                value = metrics['memory_lifetime_peak_bytes']
                cpu = metrics['cpu']['usage_usec']
                if (previous_peak is not None and value < previous_peak or
                        last_cpu is not None and cpu < last_cpu):
                    raise ValueError('Cumulative counter regressed')
                previous_peak, last_cpu = value, cpu
                peak = value if peak is None else max(peak, value)
                first_cpu = cpu if first_cpu is None else first_cpu
                if time.monotonic() - start >= seconds:
                    break
                time.sleep(max(0, min(interval, seconds - (time.monotonic() - start))))
        if hashlib.sha256(Path(__file__).read_bytes()).hexdigest() != SOURCE_SHA256:
            raise ValueError('Observer source changed during audit')
        record.update(status='observed', memory_lifetime_peak_bytes=peak,
                      cpu_interval_usec=last_cpu-first_cpu,
                      peak_warning='Includes earlier work if parent is reused; never sum child lifetime peaks')
    except (Exception, KeyboardInterrupt) as error:
        record.update(status='failed', error=str(error))
    finally:
        record['elapsed_seconds'] = time.monotonic() - start
        (output / 'audit.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


def container(value):
    try:
        cid, pid = value.split(':')
        if not re.fullmatch('[0-9a-f]{64}', cid) or not pid.isdecimal() or int(pid) <= 0:
            raise ValueError()
        return dict(id=cid, pid=int(pid))
    except ValueError:
        raise argparse.ArgumentTypeError('Use full Docker ID:positive-host-PID') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', required=True)
    parser.add_argument('--runner', required=True, type=container)
    parser.add_argument('--postgres', required=True, type=container)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--seconds', type=float, default=5)
    parser.add_argument('--interval', type=float, default=.5)
    args = parser.parse_args()
    try:
        sampling_limits(args.seconds, args.interval)
    except ValueError as error:
        parser.error(str(error))
    if not sys.platform.startswith('linux'):
        parser.error('Linux host PID/cgroup namespaces required')
    result = capture('/sys/fs/cgroup', '/proc', args.parent,
                     dict(runner=args.runner, postgres=args.postgres), args.output,
                     args.seconds, args.interval)
    print(result['status'] + ': ' + str(args.output))
    return 0 if result['status'] == 'observed' else 1


if __name__ == '__main__':
    sys.exit(main())
