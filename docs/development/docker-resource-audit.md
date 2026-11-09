# Linux resource attribution audit

The optional observer in [resource_audit.py](../../tools/docker/resource_audit.py)
checks an already running synthetic PostgreSQL/validator pair in a declared
common cgroup-v2 parent. It needs Python3 on Linux, or the existing validation
image and Docker. It reads counters and process identities; it creates no
cgroups, resets no statistics and never signals either workload.

This is a small sampler-attribution trial. It does not authorize a shared-host
allocation, launch a benchmark, qualify a release or enable larger source tiers.
Register the host, operator, resource limits, storage headroom and stop authority
before running any workload there. A shared machine's available resources are
not a dedicated reservation.

## Place the two containers

Use a new project and its isolated volumes from the
[Docker validation guide](docker-validation.md). Build the validation image and
initialize that project's marked volumes with a small `smoke` run first.
On the Linux daemon, an operator must select a dedicated parent whose final
path component starts with `achillesnext-validation`. The parent must contain
only the two containers, and those containers must be its direct children.
Systemd and cgroupfs drivers use different parent names/paths; supply the actual
host hierarchy path to the observer, rather than guessing it from a slice name.
Docker Desktop refers to its Linux VM, not the physical Mac/Windows host.

The optional [Compose override](../../tools/docker/compose.audit.yaml) places
only PostgreSQL and validator under the selected parent. It does not set parent
limits or create an exclusive CPU/I/O reservation. Docker may create a missing
parent during container startup; do not mistake that for an allocated, capped
parent. Bootstrap, the image builder and the observer stay outside measurement.
For example, with the project's output/identity/image environment already set:

```sh
export ACHILLESNEXT_VALIDATION_IMAGE_ID="$(docker image inspect --format '{{.Id}}' \
  "achillesnext-validation:${ACHILLESNEXT_VALIDATION_TAG:-local}")"
export ACHILLESNEXT_VALIDATION_IMAGE="$ACHILLESNEXT_VALIDATION_IMAGE_ID"
export ACHILLESNEXT_VALIDATION_CGROUP_PARENT=/achillesnext-validation-trial
docker compose --project-name "$ACHILLESNEXT_VALIDATION_PROJECT" \
  --file tools/docker/compose.yaml --file tools/docker/compose.audit.yaml \
  up --detach --wait --wait-timeout 120 postgres
docker compose --project-name "$ACHILLESNEXT_VALIDATION_PROJECT" \
  --file tools/docker/compose.yaml --file tools/docker/compose.audit.yaml \
  run --detach --name "${ACHILLESNEXT_VALIDATION_PROJECT}-probe" \
  --no-deps validator telemetry
```

Run only one validator in that parent. Obtain the full IDs and host init PIDs
for that project's database and validator while both run:

```sh
docker inspect --format '{{.Id}}:{{.State.Pid}}' CONTAINER_NAME
```

Pass these operator-supplied identities to the observer. It checks them against
the host process start ticks, cgroup membership and full ID in the cgroup name;
it does not query Docker labels or establish authorization from a name. Container
restarts, PID reuse/movement, unrelated descendants and observer inclusion fail
the audit. Every sampled live PID must share its container init PID's namespace
and remain in the enumerated cgroup. Separate container PID namespaces are
required; host/shared PID namespaces and nested worker PID namespaces are refused.
A worker that exits before its metadata is read is excluded from the live count;
missing metadata permissions fail the audit. A short-lived PostgreSQL worker can come and go between samples; this
is sampled structural evidence, not a complete process-event trace.

## Run the read-only observer

On a Linux host with Python3 and access to its process/cgroup metadata:

```sh
python3 tools/docker/resource_audit.py \
  --parent /achillesnext-validation-trial \
  --runner FULL_RUNNER_ID:HOST_PID --postgres FULL_POSTGRES_ID:HOST_PID \
  --output /absolute/new-audit-directory --seconds 5 --interval 0.5
```

For a Docker-only host, bind the observer script read-only into the immutable
validation image. Reading namespace links across the runner/PostgreSQL UIDs
normally requires root with `SYS_PTRACE`. This observer-only permission grants
process-inspection authority; the script uses namespace metadata reads, never
ptrace calls or process signals. The workload containers keep their existing
non-root/capability settings. The output parent must exist; the root example
creates root-owned audit files. Replace the IDs, PIDs, parent path and image ID:

```sh
docker run --rm --network none --read-only --cap-drop ALL --cap-add SYS_PTRACE \
  --security-opt no-new-privileges:true --user 0:0 \
  --pid host --cgroupns host --cpus 0.25 --memory 128m --memory-swap 128m \
  --pids-limit 32 --entrypoint python3 \
  --mount type=bind,source=/sys/fs/cgroup,target=/sys/fs/cgroup,readonly \
  --mount "type=bind,source=$PWD/tools/docker/resource_audit.py,target=/audit.py,readonly" \
  --mount "type=bind,source=$ACHILLESNEXT_VALIDATION_OUTPUT,target=/output" \
  sha256:IMMUTABLE_VALIDATION_IMAGE_ID /audit.py \
  --parent /achillesnext-validation-trial \
  --runner FULL_RUNNER_ID:HOST_PID --postgres FULL_POSTGRES_ID:HOST_PID \
  --output /output/new-resource-audit --seconds 5 --interval 0.5
```

Host PID visibility exposes process metadata to this observer. No Docker socket,
host filesystem root, credentials, network or writable cgroup mount is granted.
Do not put the observer under the measured parent. This mode requires the host
PID/cgroup namespaces and permission to read the selected metadata; rootless or
remapped configurations may refuse it. Missing access is a failed audit, not 0.

The observer accepts 1–60 second durations with 0.25–5 second intervals and bounded file, group,
process, sample and journal sizes. It exclusively creates its output directory.
It retains `samples.jsonl` and `audit.json`, including explicit missing counters
and failure reasons. Exit 0 with `status=observed` means the requested observation
completed; it is never a qualification receipt. An error or interruption returns
exit status 1 and retains earlier samples; invalid CLI timing values return usage
status 2 before creating output. Forced termination may leave an incomplete
journal without a final record. The observer does not stop the workload when it
exits; inspect its exit/logs, then stop only the owned project's containers.

## Interpret the counters

The parent `memory.current` includes descendants and charged file cache.
Previously warmed/shared pages can be charged to another group and are then
outside these counters. Moving a process does not move its existing memory
charges. A full cache-inclusive claim needs a registered lifecycle/cache policy;
this audit alone cannot establish that claim.
`memory.peak` is the kernel's parent-subtree lifetime peak since group creation;
the observer never adds child peaks. A reused parent's earlier work remains in
that peak. A five-second observation while a longer job runs does not establish
its full-job peak or cold-cache conditions. HugeTLB accounting is separate on
some kernels; keep the validation database's explicit `huge_pages=off` policy.
The record includes raw memory/cache/events/swap, CPU, I/O and PID counters,
parent and member limits, plus the observed interval's CPU usage delta.

`max` remains an explicit unlimited value (`null` in parsed controls), not a
reservation. Separate child caps and aggregate counters do not prove a parent
cap or exclusive allocation. Attribution is checked before and after each sample;
gaps between samples remain unobserved. Cgroup/PID identity drift, counter
regression or unreadable required counters prevents a successful observation.
Every record sets `qualifying=false` and `allocation_verified=false`.

For the kernel semantics see [cgroup-v2 memory interfaces](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
and [Compose cgroup parent configuration](https://docs.docker.com/reference/compose-file/services/#cgroup_parent).
Namespace identity and read-access rules follow the [Linux namespace interfaces](https://man7.org/linux/man-pages/man7/namespaces.7.html).
Image build/bootstrap and observer overhead are outside the parent. End-to-end
qualification still needs a registered fresh-parent lifecycle, complete job
coverage, limits/stop authority, calibrated storage and the matched workload.
