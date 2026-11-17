"""Bounded, read-only resource observation for an owned small-fixture worker.

Counters always carry scope. Missing telemetry is never synthesized as zero.
No cgroup creation, membership changes, PostgreSQL settings or stats resets.
"""
import errno
import json
import math
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import time

MAX_SAMPLES=20000
MAX_RECORD_BYTES=64*1024
MAX_OUTPUT_ENTRIES=100000
MAX_OUTPUT_DEPTH=32
FD_INVENTORY_SUPPORTED=(os.name=='posix' and hasattr(os,'O_NOFOLLOW') and hasattr(os,'O_DIRECTORY')
    and os.open in os.supports_dir_fd and os.scandir in os.supports_fd)


def metric(value=None,reason=None,scope=None):
    return dict(state='available' if reason is None else 'unavailable',value=value,reason=reason,scope=scope)


def bounded_text(path):
    with Path(path).open('rb') as f:
        raw=f.read(MAX_RECORD_BYTES+1)
    if len(raw)>MAX_RECORD_BYTES:raise ValueError('Telemetry counter file budget exceeded')
    return raw.decode('ascii')


def unsigned(value):
    if not value.isdecimal():raise ValueError('Invalid telemetry counter')
    return int(value)


def cgroup_snapshot(directory,pid):
    scope='specified cgroup subtree; database/cache inclusion and dedicated allocation not verified'
    if directory is None:return metric(reason='no_cgroup_allocation',scope=scope)
    try:
        root=Path(directory)
        current=unsigned(bounded_text(root/'memory.current').strip());peak=unsigned(bounded_text(root/'memory.peak').strip())
        cpu={k:unsigned(v) for k,v in (line.split() for line in bounded_text(root/'cpu.stat').splitlines())}
        io={}
        for line in bounded_text(root/'io.stat').splitlines():
            device,*fields=line.split();io[device]={k:unsigned(v) for k,v in (s.split('=',1) for s in fields)}
        pids=[unsigned(s) for s in bounded_text(root/'cgroup.procs').split()]
        return metric(dict(memory_current_bytes=current,memory_peak_bytes=peak,cpu=cpu,io=io,worker_member=pid in pids),scope=scope)
    except (OSError,ValueError,UnicodeError):return metric(reason='cgroup_unreadable_or_invalid',scope=scope)


def rss_bytes(pid):
    scope='sampled worker RSS including in-process JVM; excludes PostgreSQL/cache; not a lifetime peak'
    try:
        if sys.platform.startswith('linux'):
            line=next(s for s in bounded_text(Path('/proc')/str(pid)/'status').splitlines() if s.startswith('VmRSS:'))
            fields=line.split();assert fields[2]=='kB';value=unsigned(fields[1])*1024
        elif sys.platform=='darwin':
            result=subprocess.run(['/bin/ps','-p',str(pid),'-o','rss='],capture_output=True,text=True,timeout=2,check=True)
            value=unsigned(result.stdout.strip())*1024
        else:return metric(reason='platform_sampler_unavailable',scope=scope)
        return metric(value,scope=scope)
    except (OSError,ValueError,StopIteration,AssertionError,subprocess.SubprocessError):
        return metric(reason='worker_sample_unavailable',scope=scope)


def directory_bytes(directory):
    """Bounded descriptor-relative walk; refuse symlink roots and descendants.

    Never reopen a descendant through an ancestor pathname. Each child must still
    match its single non-following stat when opened relative to its parent FD.
    Depth bounds both owned directory FDs and open scandir iterators to 32 each.
    Unsupported platforms fail closed; a moving tree is not an atomic snapshot.
    """
    if not FD_INVENTORY_SUPPORTED:raise ValueError('Descriptor-relative inventory unavailable')
    flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW
    entries=0
    def walk(descriptor,depth):
        nonlocal entries
        total=0
        with os.scandir(descriptor) as items:
            for p in items:
                entries+=1
                if entries>MAX_OUTPUT_ENTRIES:raise ValueError('Output inventory budget exceeded')
                observed=p.stat(follow_symlinks=False)
                if stat.S_ISLNK(observed.st_mode):raise ValueError('Symlink in telemetry output')
                if stat.S_ISDIR(observed.st_mode):
                    if depth>=MAX_OUTPUT_DEPTH:raise ValueError('Output inventory depth budget exceeded')
                    child=os.open(p.name,flags,dir_fd=descriptor)
                    try:
                        opened=os.fstat(child)
                        if (opened.st_dev,opened.st_ino)!=(observed.st_dev,observed.st_ino):
                            raise ValueError('Changed directory in telemetry output')
                        total+=walk(child,depth+1)
                    finally:os.close(child)
                elif stat.S_ISREG(observed.st_mode):total+=observed.st_size
        return total
    root=os.open(Path(directory),flags)
    try:return walk(root,1)
    finally:os.close(root)


def output_inventory(directory):
    """Try at most three fresh bounded walks; never reuse partial/cached bytes.

    A moving output tree is not an atomic filesystem snapshot. Retry only missing
    or replaced-directory races, requesting 10/20ms backoff; hard refusals remain
    unavailable. Diagnostics contain closed exception classes/errno, never paths
    or exception text. Wall duration includes actual walks and scheduling waits.
    """
    started=time.monotonic();first=None;last=None
    for attempt in range(1,4):
        try:
            value=metric(directory_bytes(directory),scope='logical files under this output directory')
            break
        except (OSError,ValueError) as error:
            name=type(error).__name__
            if name not in ('OSError','FileNotFoundError','NotADirectoryError','PermissionError','ValueError'):
                name='OSError' if isinstance(error,OSError) else 'ValueError'
            number=getattr(error,'errno',None)
            if type(number) is not int or not 0<number<=65535:number=None
            last=dict(exception_class=name,errno=number)
            if first is None:first=last
            if isinstance(error,OSError) and number in (errno.ENOENT,errno.ENOTDIR) and attempt<3:
                time.sleep((.01,.02)[attempt-1]);continue
            value=metric(reason='output_inventory_unavailable',scope='output directory');break
    return value,dict(attempts=attempt,elapsed_seconds=max(0,time.monotonic()-started),
                      first_failure=first,last_failure=last)


def limits(interval,wall_seconds,rss_limit,output_limit,min_free):
    if not all(type(v) in (int,float) and math.isfinite(v) for v in [interval,wall_seconds]):raise ValueError('Invalid sampler interval/deadline')
    if not .1<=interval<=5 or not 1<=wall_seconds<=900:raise ValueError('Small worker requires .1..5s samples and 1..900s deadline')
    if math.ceil(wall_seconds/interval)+100>MAX_SAMPLES:raise ValueError('Sample budget exceeded')
    for n in [rss_limit,output_limit,min_free]:
        if type(n) is not int or not 1<=n<=16*1024**3:raise ValueError('Invalid small-worker byte budget')


def observe(command,out,env=None,interval=.5,wall_seconds=600,rss_limit=4*1024**3,output_limit=256*1024**2,min_free=64*1024**2,cgroup=None):
    """Preserve measurement on worker failure. Limits request cooperative stopping.

    The stop file is polled by R; one SIGINT to the owned child follows after five
    seconds. No automatic SIGKILL, DB-process signal or cgroup reconfiguration.
    """
    limits(interval,wall_seconds,rss_limit,output_limit,min_free)
    if not hasattr(os,'wait4'):raise ValueError('Owned-worker wait4 telemetry is required')
    out=Path(out);stop=out/'stop.json';record=out/'process-telemetry.json'
    if any(p.exists() for p in [record,stop,out/'samples.jsonl',out/'worker.log']):raise FileExistsError('Telemetry output must be new')
    started=time.monotonic();reason=None;requested=None;interrupted=False;samples=0;sampled_peak=None;output_peak=None;rss_missing=0;usage=None;code=None
    process=None
    output_success=0;output_missing=0;output_retried=0;output_attempts=0;output_first_failure=None;output_last_failure=None
    def request(why):
        nonlocal reason,requested
        if reason is None:
            reason=why;requested=time.monotonic()
            stop.write_text(json.dumps(dict(reason=reason))+'\n')
    try:
        with (out/'worker.log').open('xb') as log,(out/'samples.jsonl').open('x') as journal:
            process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,env=env)
            while True:
                try:
                    done,status,observed=os.wait4(process.pid,os.WNOHANG)
                    if done:
                        usage=observed;code=os.waitstatus_to_exitcode(status);process.returncode=code
                        if time.monotonic()-started>wall_seconds:request('wall_deadline_at_exit')
                        if usage.ru_maxrss*(1 if sys.platform=='darwin' else 1024)>rss_limit:request('worker_peak_rss_limit_at_exit')
                        break
                    now=time.monotonic();rss=rss_bytes(process.pid)
                    if rss['state']=='available':sampled_peak=max(sampled_peak or 0,rss['value'])
                    else:rss_missing+=1
                    output,inventory=output_inventory(out)
                    if output['state']=='available':output_peak=max(output_peak or 0,output['value'])
                    free=shutil.disk_usage(out).free
                    sample=dict(elapsed_seconds=now-started,rss=rss,output_bytes=output,output_inventory=inventory,output_volume_free_bytes=free,cgroup=cgroup_snapshot(cgroup,process.pid))
                    samples+=1
                    journal.write(json.dumps(sample,separators=(',',':'))+'\n');journal.flush()
                    output_attempts+=inventory['attempts']
                    output_retried+=int(inventory['attempts']>1)
                    if output['state']=='available':output_success+=1
                    else:output_missing+=1
                    if inventory['first_failure'] is not None:
                        if output_first_failure is None:
                            output_first_failure=dict(sample=samples,**inventory['first_failure'],
                                attempts=inventory['attempts'],elapsed_seconds=inventory['elapsed_seconds'])
                        output_last_failure=dict(sample=samples,**inventory['last_failure'],
                            attempts=inventory['attempts'],elapsed_seconds=inventory['elapsed_seconds'])
                    if now-started>=wall_seconds:request('wall_deadline')
                    if rss['state']=='available' and rss['value']>rss_limit:request('sampled_worker_rss_limit')
                    if output['state']!='available':request('output_measurement_failed')
                    elif output['value']>output_limit:request('output_bytes_limit')
                    if free<min_free:request('output_volume_free_limit')
                    if samples>=MAX_SAMPLES:request('sample_count_limit')
                    if requested is not None and now-requested>=5 and not interrupted:
                        try:os.kill(process.pid,signal.SIGINT)
                        except ProcessLookupError:pass
                        interrupted=True
                    time.sleep(interval)
                except KeyboardInterrupt:request('controller_interrupt')
    except BaseException:
        if reason is None:reason='sampler_error'
        if process is not None and process.returncode is None:
            try:os.kill(process.pid,signal.SIGINT)
            except ProcessLookupError:pass
            while True:
                try:
                    _,status,usage=os.wait4(process.pid,0);code=os.waitstatus_to_exitcode(status);process.returncode=code;break
                except InterruptedError:continue
        raise
    finally:
        # Do not invent lifetime data if launch/wait failed; keep the raw samples.
        result=dict(status='completed' if code==0 and reason is None else 'failed_or_stopped',exit_code=code,
            elapsed_seconds=time.monotonic()-started,samples=samples,rss_missing_samples=rss_missing,sampled_output_peak_bytes=output_peak,stop_reason=reason,cooperative_stop_requested=requested is not None,SIGINT_sent=interrupted,
            worker_cpu_seconds=metric(usage.ru_utime+usage.ru_stime,scope='wait4 OS-reported child usage; excludes PostgreSQL') if usage else metric(reason='worker_not_reaped'),
            worker_peak_rss_bytes=metric(usage.ru_maxrss*(1 if sys.platform=='darwin' else 1024),scope='wait4 worker lifetime RSS peak; R includes JVM; not total job/database memory') if usage else metric(reason='worker_not_reaped'),
            sampled_worker_peak_rss_bytes=metric(sampled_peak,scope='sampled worker RSS') if sampled_peak is not None else metric(reason='no_successful_RSS_samples'),
            output_inventory_coverage=dict(scope='Persisted output-inventory samples and fresh walk attempts for this owned worker; not an atomic filesystem snapshot',
                successful_samples=output_success,unavailable_samples=output_missing,
                retried_samples=output_retried,walk_attempts=output_attempts,first_failure=output_first_failure,last_failure=output_last_failure),
            database_process_CPU_memory=metric(reason='not_attributed_on_shared_development_host'),
            job_database_cache_peak=metric(reason='no_verified_dedicated_cgroup'),qualifying=False,
            limits=dict(interval_seconds=interval,wall_seconds=wall_seconds,rss_bytes=rss_limit,output_bytes=output_limit,min_output_volume_free_bytes=min_free),
            enforcement='sampled cooperative stop request then owned-child SIGINT; not hard OS memory/disk reservation; no automatic SIGKILL')
        record.write_text(json.dumps(result,indent=2)+'\n')
    return result
