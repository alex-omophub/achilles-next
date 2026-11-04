#!/usr/bin/env python3
"""Prove full reruns and old-publication preservation on tiny marked fixtures."""
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
    case=measurement.fixture();case.update(person=case['person'][:1],events=[],observation_period=[])
    (out/'input.json').write_text(json.dumps(measurement.physical(case,'5.5')))
    cmd=[sys.executable,'tools/test_result_serving.py','--test-script','refresh-execution','--state',str(a.state.resolve()),
         '--config',str(a.config.resolve()),'--output-dir',str(out),'--admin-host',a.admin_host,'--port',str(a.port)]
    if a.admin_user:cmd.extend(['--admin-user',a.admin_user])
    subprocess.run(cmd,cwd=measurement.ROOT,check=True)
    report=json.loads((out/'report.json').read_text())
    assert report['person_counts']==['1','1','2','2']
    for key in ['fresh_identities','unchanged_numeric_parity','stale_definitions_rejected','source_changed_recomputed',
                'new_definitions_recomputed','late_failure_rolled_back','late_cancellation_rolled_back','validation_failure_preserved',
                'approval_failure_preserved','source_denied_pinned_reads','prior_pointer_and_bytes_preserved','readiness_before_writes']:
        assert report[key] is True,key
    (out/'oracle.json').write_text(json.dumps(dict(status='passed',checks=report),indent=2)+'\n')
    print('FULL_REFRESH_RECOMPUTATION_AND_PREVIOUS_PUBLICATION_PRESERVATION_OK')


if __name__=='__main__':main()
