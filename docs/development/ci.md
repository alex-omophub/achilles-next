# CI runtime and coverage

The [conformance guide](conformance.md) groups the contributor commands by
compatibility and safety boundary, including saved-bundle viewer checks.

Compatibility also audits the locked core metadata/dimension vocabulary with
`tools/check_schema_subset.py`; see [validator ownership](validator-boundary.md).
The [saved-representation timing experiment](../benchmark/saved-representation.md)
is an explicit local command and adds no hosted benchmark job or dependency cache.

The existing compatibility suite runs `saved-transport.R` offline. The
[artifact/database byte-parity and grant-revocation checks](saved-transports.md)
run against the marked PostgreSQL fixture through the existing `result-export.R`
serving test.
The same fixture also compares the native semantic providers. `saved-provider.R`
checks semantic pagination, dependencies and limits without a database connection.
No extra integration job, dependency install or fixture generation is added.

The PostgreSQL workflow runs three distinct integration suites, each in its own
runner and PostgreSQL service. Each has a 30-minute routine budget (60 minutes
for an explicitly requested wider manual run):

| Suite | Coverage |
|---|---|
| `compatibility` | Native/JavaScript contracts, existing tracers, core and registered publication, recovery/ledger, private staging, refresh readiness and saved viewer/provider checks |
| `domain` | Population and eight-domain numerical oracles, schema variants, saved selection and source-denied reads |
| `measurement` | Whole-source measurement oracle, exact reference/weighted parity, budget/failure and source-denied checks, concurrent refresh/CAS operations proof |

Every integration check has one suite owner. Database suites remain serial inside
their runner, preserving temporary-permission and cleanup checks. Only the
compatibility suite installs Node dependencies and rebuilds the viewer; the other
two use the shipped assets and native R validators. All suites install the current
R package over cached dependencies.

The lightweight `tracer` gate keeps the previous required-check name and succeeds
only when the integration matrix succeeds. A failing suite cancels remaining
matrix work; failed, cancelled or skipped results cannot make the gate green.
Superseded workflow runs on the same ref are still cancelled. There is no additional
feature-branch push trigger duplicating the pull-request run.

This separates elapsed test time without dropping numerical, schema, state,
source-denied, rollback or publication coverage. Matrix jobs have some repeated
runner/setup work; splitting is not a claim of lower billed CPU minutes. Compare
the next hosted step timings before claiming a measured speedup. See
[GitHub's matrix job semantics](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/run-job-variations).

Compiled R dependencies use an exact OS/architecture/JDK/runtime key plus a
fingerprint of dependency fields in DESCRIPTION and the installer script.
Package prose, package version and unrelated workflow edits do not invalidate
that library. Change `tools/ci/install-r-dependencies.R` when installation inputs
change; change the cache epoch to deliberately refresh compiled dependencies.
Every restored library still passes dependency, JNI and JDBC checks. The new
cache epoch requires one initial cold installation.

One pinned PostgreSQL 17.10 client container is reused by `tools/ci/psql`; it
connects to the isolated 17.11 fixture server. It is removed at job end. Each
command still uses a separate psql process/session with its explicit connection
options and password/service-file paths. SQL session state is not shared.

Routine CI uses `--compact-calendar` for domain fixtures. It executes all 100
domain/density outputs, all 19 population outputs, the three physical schema
variants and the same missing, non-finite, duplicate, unobserved and unavailable
cases. The shorter synthetic calendar removes redundant zero-period cells;
non-calendar domain reports and full-scope/undated counts are checked for parity
with the wider fixture. The producer still processes its entire input history.
The population suite retains its full calendar, clipped, early/late-year and
streaming cases. Use manual dispatch with `full_calendar=true`, or omit
`--compact-calendar` locally, to run the wider domain fixture.

Saved baseline reads validate each dataset once into a private temporary binary
spool, then replay those exact validated R objects. No rows reach the visitor
before validation completes. This avoids a second SQL traversal and duplicate
schema/denominator validation, bounds memory, and preserves exact strings/NULLs.
The spool has a private directory/file mode and is removed on success, error or
cooperative cancellation. Unsupported period selections are rejected before
costly row traversal. These restricted readers remain separate from the approved
lazy UI provider.

Local timing evidence does not establish hosted-runner speed or large-CDM
performance. Compare step durations on the next user-pushed run; no extra remote
benchmark or scheduled workflow is started automatically.

Reader spools store only selected rows and are capped at 64 MiB by default
(`maxSpoolBytes`). Every saved dataset is still validated before emission.
A budget failure emits no rows and removes the temporary spool; operators can
explicitly raise the limit for larger approved local workloads.

The measurement suite also verifies [complete core candidates](core-characterization.md)
using `--full-matrix --with-publication`: populated 5.3/5.4/5.5 (including visit aliases and
denied descriptive metadata) plus an empty 5.5 source. It checks independent
metadata/numeric expectations, native validation without source access, type-modifier
schema fingerprints and late metadata-budget rollback. The same candidates now
come from checked refresh execution, and the first populated candidate is reused
for full/reduced approval, exact export-row comparisons and source/store-denied
serving reads, including context and audience-revocation checks. No additional
generation run or Node dependency is introduced. See the
[integrated conformance command](conformance.md#compose-complete-refresh-with-approved-publication).
The [full-refresh proof](refresh.md)
also runs in measurement on tiny empty-domain fixtures, checking fresh recomputation
and preservation of an actual prior publication through failures. Its offline plan/
readiness guard runs in compatibility. No new suite or dependency is added. The small offline metadata guard runs in compatibility. These checks
reuse the existing suites and dependencies; they add candidate validation work,
so total hosted duration must be measured after push.

The separate [operations proof](store-operations.md) runs serially in measurement,
using independently spawned R/JVM sessions inside that suite's isolated database.
It observes two in-flight snapshots across source changes, terminates only its
fixture-owned precommit backend, and holds the actual CAS key until both promotion
sessions visibly wait. Each process/barrier has a bounded wait and child cleanup.
It adds no runner or dependency install. The additional hosted duration has not
been measured; local proof timing is not a CI cost or production-scale guarantee.


The measurement suite's default smoke uses the 5.5 adversarial and
empty-source fixtures and compares weighted summaries with physical-row reference
sorting. Run `tools/test_measurement_baseline.py --full-matrix` locally for the
5.3/5.4 schemas, empty-domain and unobserved cases. This is a numerical/safety
suite, not a timing benchmark or production-scale qualification.

## Action runtime maintenance

The existing compatibility suite also runs source-denied saved-label/index tests,
their independent structural corpus and optional `2.1.0` capture/publication/search
checks inside the existing marked PostgreSQL serving test. These reuse the current
R/JDBC and Ajv installations; no extra job or dependency install is introduced.
Source capture in that fixture is explicit batch vocabulary work. Provider SQL
must still target only approved serving views. Local timings do not measure the
additional hosted duration or certify production scale.

Checkout v7, setup-node v7 and setup-java v6 declare Node 24 as their action
runtime. This avoids forcing the deprecated Node 20 actions to execute on Node 24.
The action runtime is separate from the installed test tools: Node 24.11.1,
Temurin 11 and R 4.2.3 retain their existing settings. The R/JDBC cache keys and
verification are unchanged; setup-r v2 and cache v5 already declare Node 24.

The migrations used here do not set npm registry authentication, Maven credential
aliases or privileged fork-checkout options. See the official
[checkout migration notes](https://github.com/actions/checkout/blob/v7.0.1/README.md),
[setup-node migration notes](https://github.com/actions/setup-node/blob/v7.1.0/README.md)
and [setup-java migration notes](https://github.com/actions/setup-java/blob/v6.1.0/README.md).
Confirm the annotations after the next user-pushed hosted run; local workflow
validation does not execute the remote actions.
