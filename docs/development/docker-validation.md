# Docker contributor validation

The validation image supplies R, JNI/Java, JDBC, Python, a native pinned `psql`
client, Node and package dependencies. The host needs Docker Engine/Desktop and
a recent Docker Compose plugin with `up --wait`, plus a POSIX shell to use the wrapper. Host R, Java,
PostgreSQL and Node installations are unnecessary. These are synthetic contributor
checks; existing CI suites and representative-scale qualification remain separate.

## Start a bounded run

From the checkout root, create an output directory outside the checkout:

```sh
mkdir -p ../achillesnext-validation-output
export ACHILLESNEXT_VALIDATION_OUTPUT="$(cd ../achillesnext-validation-output && pwd -P)"
export ACHILLESNEXT_VALIDATION_PROJECT=achillesnext-validation-local
sh tools/docker/validate.sh smoke
```

The wrapper builds/reuses the image, bootstraps new marked state/credential volumes,
waits for its own PostgreSQL container to become healthy, runs one validator, then
stops that PostgreSQL container. Failures return nonzero and preserve outputs and
volumes. It neither starts nor stops unrelated projects. No public port is exposed;
the validator shares only its PostgreSQL service's network namespace, preserving
the fixture tools' loopback-only connection guard. Runtime networking is internal.

Use these modes separately; outputs are new timestamp/random directories:

| Command argument | Checks |
|---|---|
| `build` | Build the cached image without starting fixtures. |
| `offline` | Runtime/installed-source identity, observer journal faults, Python discovery, contract checks and React tests. It starts an isolated database container for the common network setup but does not provision the CDM. |
| `smoke` | Runtime/identity, locked fixture setup and verification for CDM 5.3/5.4/5.5, observer SQL fault/savepoint recovery. No full report generation is claimed by this mode. |
| `telemetry` | Smoke checks plus the existing four-person/24-event, all 142-output observed/control proof, complete/projected native exports, after-page-write cancellation and disposable-store cleanup. |
| `status` | List only this Compose project's containers. |
| `down` | Remove only this project's containers/network; preserve volumes and bind outputs. |

For example: `sh tools/docker/validate.sh telemetry`. No mode enables S1/S2 or
downloads institutional data. GiBleed, SynPUF, broad CI integration matrices and
full scale runs are not added to this bounded environment.
Offline mode preserves the existing integration-dependent test skips; it does
not generate or claim the complete tracer/publication integration bundle matrix.

## Isolation, resources and retained state

The default runtime caps are 2 CPUs/4 GiB each for validator and PostgreSQL, with
swap limits equal to memory limits and separate PID caps. Bootstrap runs earlier
with 0.5 CPU/256 MiB. These are ceilings, not dedicated host reservations. The
validator runs as the invoking user's non-root UID/GID; bootstrap has only the
capabilities needed to initialize/chown its own volumes. The validator has no
extra capabilities, Docker socket, host network or production mounts.
These runtime caps do not constrain image builds; builder resources are managed
separately. The dependency build compiles with one make worker by default.

A small Docker Desktop VM can use lower caps for the same tiny checks:

```sh
export ACHILLESNEXT_RUNNER_CPUS=2 ACHILLESNEXT_POSTGRES_CPUS=1
export ACHILLESNEXT_RUNNER_MEMORY=2g ACHILLESNEXT_POSTGRES_MEMORY=1g
sh tools/docker/validate.sh telemetry
```

Choose limits from actual available host resources before running on a shared
machine. Non-root IDs default to `id -u`/`id -g`; explicitly set `VALIDATION_UID`
and `VALIDATION_GID` to a non-root account if invoking from a root shell. Changing
IDs for existing marked volumes is refused. Use a new guarded project name for
a different owner/isolated copy; do not overwrite old credentials.

State, credentials and PostgreSQL data are separate project-scoped named volumes.
Password generation is random, idempotent and private; credentials never enter
the image, Compose environment declarations or result receipts. Fixtures retain
their existing database/role/schema markers and restricted producer identity.
PostgreSQL data stays on its volume, not its writable container layer. Its test
configuration uses explicit huge-pages-off and bounded work/temp settings; it does
not change host huge-page pools or other databases.

Output is a bind mount selected by `ACHILLESNEXT_VALIDATION_OUTPUT`; its parent
must exist. The wrapper refuses the checkout, its children and its ancestors. It checks a 10 GiB
free-space floor on state/output before steps. This is observation, not a disk
quota or reservation. PostgreSQL/backend temp limits and native telemetry output
limits remain scoped controls; actual storage pools can be shared or aliased.
Keep production/backup headroom independently. Cleanup never prunes global images
or volumes; `down` preserves credentials/data for examination and reruns. Remove
this project's retained volumes manually only when its data is no longer needed.

Each run retains `validation.json`, image/runtime manifests, step logs and cgroup
endpoints. A running/failed record is not a success receipt. Successful telemetry
also retains the original fully checked `telemetry/receipt.json`. Ordinary signals
are forwarded to the owned subprocess group. A step timeout first sends SIGINT,
then SIGTERM and ultimately SIGKILL if the child ignores stopping; Docker itself
also has a finite stop grace period. Forced process death may leave fixture work
for inspection/recovery. A stopped or incomplete run is not accepted.

## Cached builds and evidence scope

Base R/Node/PostgreSQL images are pinned by digest. All 47 R dependency archives,
the JDBC driver and native PostgreSQL client source are checksum-locked in
[runtime-lock.json](../../tools/docker/runtime-lock.json). `npm ci` uses the existing
two lockfiles. Source edits reuse compiled dependencies; no dependency installer
runs during validation. Update the Docker dependency lock when package imports
change; changing that lock invalidates the dependency layers. Docker's build context is an explicit allowlist that
excludes host configuration, local outputs, credentials and host node_modules.

The built image records source hashes, installed function/asset identity, actual
versions and the system-package manifest hash. Each run verifies that source has
not drifted. Apt patch versions are recorded rather than fully snapshot-locked;
retain the immutable built image ID (or `docker save` that image) for exact image
replay. The checked source/image content, not a mutable `local` tag alone, is the
evidence identity. Avoid concurrent builds using the same image tag; use distinct
`ACHILLESNEXT_VALIDATION_TAG` values for concurrent source revisions.

Linux cgroup-v2 files are collected separately for validator and PostgreSQL,
including raw memory/cache/CPU/I/O, limits and OOM counters. PostgreSQL counters
are read by the synthetic container administrator; analysis still uses its
restricted fixture runner. Unreadable files remain unavailable. IDs in each
record use that container's PID namespace. Do not sum separate lifetime memory
peaks or treat them as a measured whole-job peak. No common parent group, exclusive
CPU/I/O allocation or cold-cache reset is established here; every receipt sets
`qualifying=false`. Build/install work is outside validation/telemetry timings.
