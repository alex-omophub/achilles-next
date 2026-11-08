#!/usr/bin/env python3
"""Generate or verify bounded synthetic CDM CSV previews; never large tiers."""
import argparse
from pathlib import Path
from synthetic_cdm import generate, verify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['build','verify'])
    parser.add_argument('--output-dir',type=Path,required=True)
    parser.add_argument('--people',type=int)
    parser.add_argument('--events',type=int)
    parser.add_argument('--seed',type=int)
    parser.add_argument('--cdm-version',choices=['5.3','5.4','5.5'])
    args = parser.parse_args()
    parameters={k:v for k,v in dict(people=args.people,events=args.events,seed=args.seed,version=args.cdm_version).items() if v is not None}
    if args.action=='verify' and parameters:
        parser.error('Verify uses only the pinned manifest parameters')
    result = generate(args.output_dir,**parameters) if args.action=='build' else verify(args.output_dir)
    print(f"Synthetic preview {args.action} passed: {result['parameters']['people']} people, {result['parameters']['events']} events; no database connection")


if __name__=='__main__':main()
