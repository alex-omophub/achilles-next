#!/usr/bin/env python3
"""Bounded marked-fixture aggregate persistence pilot, with private output."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--sizes', default='100,1000,5000')
    parser.add_argument('--trials', type=int, choices=range(1,4), default=3)
    args = parser.parse_args()
    try:
        sizes = [int(n) for n in args.sizes.split(',')]
    except ValueError:
        parser.error('Cardinalities must be integers')
    if not 1 <= len(sizes) <= 8 or len(set(sizes)) != len(sizes) or any(n < 1 or n > 5000 for n in sizes):
        parser.error('Use 1–8 distinct cardinalities between 1 and 5000')
    out = args.output_dir.resolve()
    if args.output_dir.is_symlink() or out.exists() or out.is_relative_to(ROOT):
        parser.error('Use a new output directory outside the checkout')
    out.mkdir(parents=True, mode=0o700)
    subprocess.run(['Rscript','--vanilla','tools/benchmark/persistence.R',str(args.config.resolve(strict=True)),str(out),','.join(map(str,sizes)),str(args.trials)],cwd=ROOT,check=True)
    report = json.loads((out/'report.json').read_text())
    summaries = []
    for n in sizes:
        groups = {s:[r for r in report['runs'] if r['cardinality']==n and r['strategy']==s] for s in ('row','batch')}
        row, batch = (statistics.median(r['writer_seconds'] for r in groups[s]) for s in ('row','batch'))
        summaries.append(dict(cardinality=n,row_seconds=row,batch_seconds=batch,speed_ratio=row/batch if batch else None,
            row_write_submissions=[r['jdbc_write_submissions'] for r in groups['row']],batch_write_submissions=[r['jdbc_write_submissions'] for r in groups['batch']],
            revision_updates_unchanged=all(r['revision_updates']==str(2*n+1) for s in groups.values() for r in s)))
    report['summary']=summaries
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(summaries,indent=2))


if __name__=='__main__':
    main()
