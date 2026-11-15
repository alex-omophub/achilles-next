# Offline client footprint baseline

Run from the checkout with R, the package's R/Java dependencies and a matching
installed AchillesNext. Python 3.10+ and Unix `wait4` are required by this
contributor sampler. No database connection, JDBC driver download, PostgreSQL
service, Docker, cgroup observer or dedicated server is used.

```sh
python3 tools/benchmark/client_footprint.py --output /tmp/achilles-client-baseline
```

Use `R_LIBS` to select your existing installed package library. The runner checks
loaded R bindings, SQL files and analysis definitions against the checkout before
work. It does not install dependencies. Each repeat runs two fresh R processes:

1. `plan`: public core batch planner for CDM 5.3/5.4/5.5 with both reference/shared
   planning strategies and an explicit 2020 window. Six plans; no executable
   full-profile SQL or source capability verification is claimed.
2. `primitives`: internal PostgreSQL interval, nine-domain classification,
   capture/coverage and exact reference/weighted numeric physical primitives.
   Fourteen strings per declared CDM version. These deliberately **do not**
   constitute all 142 report queries or dialect certification. They currently
   render the same physical SQL across these version declarations.

To add a saved-result process, supply a previously approved/admitted artifact and
its exact trusted provider-context JSON, including its root descriptor and host
authorization epoch/instance. Keep this context local; do not publish credentials
or confidential output. The benchmark's callback approves only this supplied
context; it is a standalone diagnostic, not a host authorization implementation.

```sh
python3 tools/benchmark/client_footprint.py --output /tmp/achilles-saved-baseline \
  --artifact /path/to/approved-bundle --context /path/to/context.json
```

The saved process separately times full `validateResultArtifact` admission,
provider opening, the first catalogue page (25 entries), the first PERSON-count
read and 100 subsequent PERSON-count reads (one primary row per request). The
bundle must retain an available `core.person.count` output. This is a narrow
read workload, not catalogue traversal, concept search or every report. Full
admission validates the bundle's publication pointer; the provider subsequently
reads the separately supplied exact pinned context. Supply matching identities
when comparing these phases.

## Evidence and limits

`manifest.json` records each run, harness hashes, platform, diagnostic limits and
failure state. Each run retains `worker.json` (phase wall/CPU time, R heap,
software/implementation identities, connector attempts and reader counters),
`process-telemetry.json`, RSS/output samples and `worker.log`. Planner/primitive
products are retained for inspection. Harness hashes are checked before and after
each worker; a detected edit or missing file fails the manifest and stops later
workers, retaining completed worker evidence. These drift checks are not an
immutable snapshot or protection against a file being changed and restored
between checks. Keep the checkout unchanged while benchmarking.
Errors preserve the evidence and return a nonzero exit. Output must resolve
outside the package checkout, including through symbolic links; existing output
paths are refused. Three repeats are the default;
`--repeats 1` is useful for a smoke test.

The lifetime RSS/CPU comes from the owned R process via `wait4`, including any
in-process JVM. It excludes the Python controller, SQL engine and browser. Phase
CPU excludes child processes; phase wall time includes operation waits. Phase
R heap is the sum of GC-reported Ncell/Vcell maxima, with a GC/reset **before**
each phase outside its operation clock. Those maxima need not coincide, do not
include Java/native memory and are not incremental allocations. Total process
cost includes this instrumentation, identity verification and startup. The JVM
maximum heap is a configured ceiling, not measured resident use. Compare these
scopes explicitly rather than subtracting one metric from another.

The worker's `TMPDIR` is under its run directory. Logical output/scratch bytes are
sampled there, excluding input artifacts, libraries and external databases.
Short-lived temporary peaks between samples can be missed. The separately
recorded `final_output_bytes` is the final run-directory logical byte total,
including telemetry, logs, retained products and any remaining scratch files;
it is not a product-only output measurement. Saved-provider fetched bytes count
verified page file bytes, not network or physical disk I/O; cache hits are separate. No external
traffic or browser heap is measured in these offline modes.

A rejecting/counting `DatabaseConnector::connect` sentinel covers operations
after package loading. It is armed on namespace load, avoiding connector/JVM
startup merely for instrumentation. It detects accidental connector use; it is not a
process-wide network sandbox. Fresh R does not imply cold OS, filesystem or
server caches. The default 120-second / 2-GiB RSS / 64-MiB output / 64-MiB free
space observer safeguards request cooperative stop, then owned-child SIGINT;
they are diagnostic limits, not product requirements or hard OS reservations.

These are exploratory baselines. No SQL-runtime, large-source, growing-export,
WAN, browser or universal laptop qualification follows. Current boundaries and
remaining gaps are in the [client-path inventory](../development/client-paths.md).

For the independent small synthetic fixture regression (no CDM):

```sh
ACHILLES_NEXT_CLIENT_TEST=1 python3 -m unittest discover -s tests -p test_client_footprint.py
```
