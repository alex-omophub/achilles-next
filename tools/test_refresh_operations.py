#!/usr/bin/env python3
"""Controlled concurrent refresh, connection-loss and promotion proof on marked fixtures."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import test_measurement_baseline as measurement


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--state',type=Path,required=True);p.add_argument('--config',type=Path,required=True)
    p.add_argument('--output-dir',type=Path,required=True);p.add_argument('--admin-host',default='/tmp')
    p.add_argument('--admin-user');p.add_argument('--port',type=int,default=5432);a=p.parse_args()
    out=measurement.base.create_evidence_dir(a.output_dir)
    case=measurement.fixture();event=dict(case['events'][0],id='1',person_id=case['person'][0]['person_id'],concept='100',date='2020-01-01',end='2020-02-01')
    case.update(person=case['person'][:1],events=[],observation_period=[])
    model=measurement.physical(case,'5.5')
    rows=measurement.physical(dict(case,events=[event]),'5.5')['tables']['condition_occurrence']
    model['condition_initial']=rows
    model['condition_changed']=[dict(rows[0],condition_occurrence_id='2',person_id='987654321',condition_start_date='2019-12-31'),
                                dict(rows[0],condition_occurrence_id='3',condition_start_date='2020-01-02')]
    (out/'input.json').write_text(json.dumps(model))
    cmd=[sys.executable,'tools/test_result_serving.py','--test-script','refresh-operations','--state',str(a.state.resolve()),
         '--config',str(a.config.resolve()),'--output-dir',str(out),'--admin-host',a.admin_host,'--port',str(a.port)]
    if a.admin_user:cmd.extend(['--admin-user',a.admin_user])
    subprocess.run(cmd,cwd=measurement.ROOT,check=True)
    r=json.loads((out/'report.json').read_text())
    assert r['snapshots']==[dict(person_count='1',condition_count='1',wrong_domain_count='0'),
                            dict(person_count='2',condition_count='2',wrong_domain_count='2')]
    for key in ['overlap_observed','distinct_candidate_identities','late_connection_loss_rollback','promotion_contention_observed','one_cas_winner',
                'stale_cas_rejected','idempotent_winner_retry','approval_contexts_isolated','pinned_prior_bytes_retained',
                'pinned_loser_readable','source_denied_reads','children_stopped']:
        assert r[key] is True,key
    assert r['final_revision']=='2'
    (out/'oracle.json').write_text(json.dumps(dict(status='passed',checks=r),indent=2)+'\n')
    print('OVERLAPPING_SNAPSHOTS_CONNECTION_LOSS_CAS_AND_PINNED_READS_OK')


if __name__=='__main__':main()
