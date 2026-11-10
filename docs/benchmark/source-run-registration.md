# Source-run registration and resource observations

[source_run_registration.py](../../tools/source_run_registration.py) freezes an
indexed source target, read-only resource observations and optional measured
[source inventory](source-inventories.md) evidence in a new local artifact.
It is a preparation step for larger source workflows; it starts no workload,
connects to no database and changes no host configuration or resource allocation.

Every record has `status=planned_not_admitted`, `execution_enabled=false` in its
assessment, `full_tier_generated=false` and `qualifying=false`. There is no flag to
enable execution. A verified registration does not certify resources or admit
full-tier generation.

## Register and verify

Use Python 3.10+ on a local POSIX filesystem. From the checkout root, prepare a
storage plan outside the checkout:

```sh
mkdir -p ../source-run-work
python3 - <<'PY'
import json
from pathlib import Path

work = Path('../source-run-work').resolve()
roles = ['source', 'inventory', 'database', 'temporary', 'export']
(work / 'storage.json').write_text(json.dumps({role: str(work) for role in roles}))
PY
python3 tools/source_run_registration.py register \
  --run-id local-s2-preparation --tier S2 --cdm-version 5.5 \
  --storage-plan ../source-run-work/storage.json \
  --output-dir ../source-run-work/registration
python3 tools/source_run_registration.py verify \
  --output-dir ../source-run-work/registration
```

The storage plan contains exactly five role-to-directory entries. Paths must be
absolute; aliases resolve to canonical paths. These roles describe intended
locations. The tool only reads filesystem metadata and space counters, so giving
a directory the `database` role does not associate it with a running PostgreSQL
instance. Missing or unreadable directories produce unavailable observations.
Use real locations to collect meaningful preparation evidence. The example maps
all roles to one filesystem deliberately; it does not create a database.

`--tier` selects the unchanged S1/S2 logical recipes and `--cdm-version` selects
5.3, 5.4 or 5.5. A run ID is 1–64 lowercase letters/digits/hyphens, beginning with
a letter or digit. A new output directory is required, outside the checkout.
Direct output symlinks and an output overlapping sample directories are refused.
Existing output is preserved. The directory contains only `registration.json`;
unknown files and interrupted partial metadata are refused by `verify`.

## Bind a bounded witness

After generating a completed source selection and its measured inventory, add
both paths to a new registration:

```sh
python3 tools/source_run_registration.py register \
  --run-id local-s2-witness --tier S2 --cdm-version 5.5 \
  --storage-plan ../source-run-work/storage.json \
  --sample-source ../streaming-source-work/job \
  --sample-inventory ../streaming-source-work/inventory \
  --output-dir ../source-run-work/witness-registration
```

The sample must match the target tier, CDM version and current pinned recipe/code.
Collect the inventory separately before registering its witness. Registration
reruns source and inverse replay verification through the existing inventory
verifier; supplying a receipt alone is insufficient. Verification of a sample
uses its materializer lock. Source/inventory contents remain unchanged. The new
record binds source/recipe/DDL/profile and tool hashes, the complete source
binding, measured inventory/database hashes and selected row/byte counts. The
sample has `coverage=bounded_selection_only`; no full-tier widths, frequencies,
storage amplification or capacity projection are inferred from it. Source and
inventory files must remain available for later registration verification.

## Resource facts and readiness

The snapshot records a UTC timestamp, platform/architecture, the registrar's CPU
affinity count, physical memory where the OS exposes it, current cgroup-v2 endpoints,
and total/free space plus logical device identities for the five storage roles.
Unavailable facts stay explicit. This uses no Docker socket, host PID access,
elevated capabilities, recursive directory scan or clinical-data query.

`visible_cpus` counts the registrar's calling-thread affinity mask, including
cpuset restrictions; it is unavailable when the OS cannot provide that mask.
It does not substitute the host CPU total. CPU quota is observed separately.
See the Linux [affinity interface](https://man7.org/linux/man-pages/man2/sched_getaffinity.2.html).

Cgroup limits come from the registrar's unified `/proc/self/cgroup` membership,
mapped through the cgroup-v2 entries in `/proc/self/mountinfo`, including mount
roots, subtree mounts and escaped paths. The probe uses bounded metadata reads
and reports unreadable, ambiguous or unmapped views as unavailable; it never falls
back to unlimited hierarchy-root values. Membership changes during a counter read
also make that observation unavailable. See the Linux
[mount metadata](https://man7.org/linux/man-pages/man5/proc_pid_mountinfo.5.html) and
[cgroup namespace](https://man7.org/linux/man-pages/man7/cgroup_namespaces.7.html) manuals.

Paths on the same logical device form one group with their minimum sampled free
space. Free bytes are never added across aliases. Different device numbers do
not establish different physical pools: bind mounts, virtual disks and shared
backing storage still require operator evidence and reservations. The tool does
not treat every filesystem as needing the entire reference free-space floor;
per-pool requirements need a calibrated source/database/temp/export projection.

The declared benchmark reference is Linux, 8 CPUs, 32 GiB physical memory,
a 28 GiB job-memory limit and 512 GiB free storage before generation. These are
benchmark preparation targets, not package installation requirements. Observed
CPU/memory shortfalls and unavailable endpoints get explicit reason codes.
Unbounded cgroup limits do not prove an allocation. The visible namespace may
omit constraining ancestors, and the current process group does not establish
database/cache inclusion or a common measured parent.

Even apparently sufficient observations leave dedicated allocation, physical
storage reservations, operator stop authority, common-parent auditing and
calibrated capacity unverified. The full-tier executor, source-wide inventory
and chunk database loader are explicitly unavailable in this increment. A missing
bounded witness is recorded separately. No successful probe removes these gates.

`verify` checks canonical metadata, current tool/source bindings, optional sample
replay and recomputed assessment. It validates the **recorded snapshot**, without
replacing it with current free-space or resource facts. Collect a new registration
in a separate directory for fresh observations. Hashes provide local consistency,
not an authenticated hardware attestation; these operator-owned artifacts are
not admission credentials. Edited eligibility flags cannot turn them into one.

CLI success returns 0, refusals return 1 and syntax errors return 2. A bounded
sample verifier deadline returns 3; Ctrl-C returns 130. Slow/blocking OS metadata
calls are not subject to a hard timer. An interruption can leave incomplete
metadata; preserve it and register in a new location. The tool never replaces
an earlier registration or publication.
