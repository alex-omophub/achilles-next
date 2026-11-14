"""Bounded metadata/STOP worker for an existing registered resource allocation.

No provisioning, lease renewal, source scan, DDL, generation or publication.
The operator separately samples the common parent and renews/revokes admission.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import sys
import time

import source_execution_resources as Z

M=Z.M
S=Z.S
L=Z.L
SOURCE_SHA=S.BASE.sha(Path(__file__).read_bytes())
PROBE="SELECT current_database() AS database,current_user AS owner,pg_postmaster_start_time()::text AS postmaster_started_at,current_setting('transaction_read_only') AS read_only,1 AS ping"
EXPECTED_STOPS={'resource_operator_stop_file','resource_admission_revoked'}
MAX_SAMPLES=120
MAX_JOURNAL=65536


def pins():
    if S.BASE.sha(Path(__file__).read_bytes())!=SOURCE_SHA:raise ValueError('Trial implementation changed after import')
    return dict(trial=SOURCE_SHA,resources=Z.pins(),loader=L.pins())


def separate(output,resources,state,record):
    output=Path(output)
    if output.is_symlink():raise ValueError('Symlink trial output')
    output=S.outside(output).resolve()
    if output.exists():raise FileExistsError('Trial output must be new')
    if not output.parent.is_dir():raise ValueError('Existing trial output parent required')
    config=record['allocation'];export=Path(config['storage']['export']['worker_path']).resolve()
    if not output.is_relative_to(export) or output==export:raise ValueError('Trial output must be below registered export storage')
    protected=[resources,state,config['job_dir'],config['projection']['evidence_file']] if config['projection'] else [resources,state,config['job_dir']]
    for item in protected:
        other=Path(item).resolve()
        if output==other or output.is_relative_to(other) or other.is_relative_to(output):raise ValueError('Keep trial output separate from registration/state/job/projection')
    return output


class Guard(L.Guard):
    def __init__(self,paths,seconds,lease,stop):
        super().__init__(paths,seconds,stop=stop);self.lease=lease
    def check(self,disk=False):
        super().check(disk);self.lease.check()


def identity(client,expected):
    observed=Z.target_identity(client)
    # Database size is live metadata, not a stable instance identifier. This
    # worker performs no DDL or data writes and does not claim growth coverage.
    if {k:v for k,v in observed.items() if k!='initial_database_bytes'}!={k:v for k,v in expected.items() if k!='initial_database_bytes'}:
        raise ValueError('Trial database identity/settings differ')
    return observed


def run(resources,state,output,seconds=10,stop=None):
    started=time.monotonic()
    if type(seconds) is not int or not 1<=seconds<=30:raise ValueError('Trial requires 1..30 integer seconds')
    resources=Path(resources)
    if resources.is_symlink():raise ValueError('Symlink resource registration')
    resources=S.outside(resources).resolve();state=Path(state).resolve()
    record=Z.read_registration(resources);config=record['allocation'];code=pins()
    output=separate(output,resources,state,record)
    if record['status']!='registered':raise ValueError('Trial needs registered resource admission')
    lease=Z.Lease(resources,record,worker=True)
    guard=Guard([output.parent],seconds,lease,stop);guard.began=started;guard.check(disk=True)
    application='achillesnext-resource-trial-'+secrets.token_hex(8)
    client=L.Client(state,guard,application)
    client.env['PGOPTIONS']+=' -c default_transaction_read_only=on'
    L.check_target(client);observed=identity(client,config['database']);guard.check(disk=True)
    body=dict(kind='resource_admission_trial',version=1,registration_sha256=record['registration_sha256'],
        partition_plan_sha256=config['partition_plan_sha256'],tier=config['tier'],job_dir=config['job_dir'],
        application=application,seconds=seconds,code=code,database=observed,qualifying=False)
    request=dict(body,trial_sha256=Z.digest(body));output.mkdir(mode=0o700);M.sync_directory(output.parent)
    with M.open_file(output/'.lock',True):pass
    with M.locked(output):
        M.atomic_json(output,'request.json',request,exclusive=True)
        samples=0;written=0;failure=None;reason=None;status='failed';journal_hash=hashlib.sha256()
        try:
            with M.open_file(output/'samples.jsonl',True) as journal:
                while True:
                    guard.check(disk=True)
                    rows=client.rows(PROBE)
                    if (len(rows)!=1 or rows[0]!=dict(database=observed['database'],owner=observed['owner'],
                        postmaster_started_at=observed['postmaster_started_at'],read_only='on',ping=1)):
                        raise ValueError('Trial read-only metadata probe differs')
                    sample=dict(elapsed_seconds=time.monotonic()-started,probe=rows[0])
                    raw=S.BASE.canonical(sample)
                    if samples>=MAX_SAMPLES or written+len(raw)>MAX_JOURNAL:raise ValueError('Trial journal budget exceeded')
                    journal.write(raw);journal.flush();os.fsync(journal.fileno());journal_hash.update(raw);samples+=1;written+=len(raw)
                    if samples==1:M.atomic_json(output,'ready.json',dict(trial_sha256=request['trial_sha256'],
                        registration_sha256=record['registration_sha256'],application=application,metadata_probe_completed=True,qualifying=False),exclusive=True)
                    # No lease renewal or automatic STOP removal in the worker.
                    time.sleep(.25)
        except M.Stopped as error:
            reason=str(error)
            if samples and reason in EXPECTED_STOPS:
                # An external callback cannot fabricate an operator STOP.
                try:Z.stop_files(resources)
                except M.Stopped as actual:
                    if str(actual)==reason:status='passed'
                except (ValueError,OSError) as actual:failure=str(actual)[:1024]
            if status!='passed':failure=reason
        except (Exception,KeyboardInterrupt) as error:
            failure=str(error)[:1024] or type(error).__name__
        try:
            if pins()!=code:raise ValueError('Trial implementation pins differ')
        except Exception as error:status='failed';failure=str(error)[:1024]
        result=dict(kind='resource_admission_trial_result',version=1,status=status,trial_sha256=request['trial_sha256'],
            registration_sha256=record['registration_sha256'],samples=samples,journal_bytes=written,journal_sha256=journal_hash.hexdigest(),
            elapsed_seconds=time.monotonic()-started,stop_reason=reason,error=failure,qualifying=False,
            scope='bounded read-only fixture metadata and cooperative admission STOP; no source/scale or live attribution qualification',
            source_scanned=False,lease_renewed=False,allocation_qualified=False)
        M.atomic_json(output,'trial.json',dict(result,result_sha256=Z.digest(result)),exclusive=True)
        return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resource-dir',type=Path,required=True);parser.add_argument('--state-dir',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True);parser.add_argument('--seconds',type=int,default=10)
    args=parser.parse_args()
    try:
        result=run(args.resource_dir,args.state_dir,args.output_dir,args.seconds)
        print(json.dumps(result,sort_keys=True));return 0 if result['status']=='passed' else 1
    except M.Stopped as error:print('Resource trial refused: '+str(error),file=sys.stderr);return error.code
    except (ValueError,OSError,KeyError,TypeError,RuntimeError) as error:
        print('Resource trial refused: '+str(error),file=sys.stderr);return 1


if __name__=='__main__':raise SystemExit(main())
