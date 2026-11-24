#!/usr/bin/env python3
"""Check the installed analysis definitions and v2 result contract from this checkout."""
import argparse
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*command):
    print("Running", shlex.join(map(str, command)), flush=True)
    try:
        subprocess.run(command, cwd=ROOT, check=True)
    except FileNotFoundError:
        sys.exit(f"Required executable unavailable: {command[0]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
        epilog="With no subcommand, only the offline suites run.")
    modes = parser.add_subparsers(dest="mode")
    pg = modes.add_parser("postgresql", help="Also exercise the registered profile in a marked synthetic database.")
    pg.add_argument("--state", type=Path, required=True, help="Provisioned synthetic fixture state directory.")
    pg.add_argument("--config", type=Path, required=True, help="Trusted R fixture connection configuration.")
    pg.add_argument("--output-dir", type=Path, required=True, help="New directory for the integration output.")
    pg.add_argument("--admin-host", default="/tmp")
    pg.add_argument("--admin-user")
    pg.add_argument("--port", type=int, default=5432)
    args = parser.parse_args()

    for name in ("implementation-identity", "analysis-definitions", "registered-profile-offline"):
        run("Rscript", "--vanilla", f"tests/tracer/{name}.R")
    with tempfile.TemporaryDirectory(prefix="achillesnext-conformance-") as scratch:
        corpus = Path(scratch) / "v2-corpus.json"
        run("Rscript", "--vanilla", "tests/tracer/result-wire.R", corpus)
        run("node", "packages/contracts/tools/validate-v2-corpus.mjs", corpus)
        run("Rscript", "--vanilla", "tests/tracer/persistence-offline.R", corpus)
    print("Offline contributor conformance passed.", flush=True)

    if args.mode == "postgresql":
        # The fixture driver owns database markers, temporary reader roles and cleanup.
        command = [sys.executable, "tools/test_result_serving.py", "--test-script", "registered-profile",
                   "--config", args.config.absolute(), "--state", args.state.absolute(),
                   "--output-dir", args.output_dir.absolute(), "--admin-host", args.admin_host,
                   "--port", str(args.port)]
        if args.admin_user:
            command.extend(["--admin-user", args.admin_user])
        run(*command)
        print("Marked PostgreSQL registered-profile conformance passed.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode if error.returncode > 0 else 128 - error.returncode)
