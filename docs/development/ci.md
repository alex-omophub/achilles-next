# CI runtime and coverage

The [conformance guide](conformance.md) groups the contributor commands by
compatibility and safety boundary, including saved-bundle viewer checks.

The PostgreSQL workflow runs three distinct integration suites, each in its own
runner and PostgreSQL service. Each has a 30-minute routine budget (60 minutes
for an explicitly requested wider manual run):

| Suite | Coverage |
|---|---|
| `compatibility` | Native/JavaScript contracts, existing tracers, core and registered publication, recovery/ledger, private staging, refresh readiness and saved viewer/provider checks |
| `domain` | Population and eight-domain numerical oracles, schema variants, saved selection and source-denied reads |
| `measurement` | Whole-source measurement oracle, exact reference/weighted parity, budget/failure and source-denied checks |

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

The measurement suite's default smoke uses the 5.5 adversarial and
empty-source fixtures and compares weighted summaries with physical-row reference
sorting. Run `tools/test_measurement_baseline.py --full-matrix` locally for the
5.3/5.4 schemas, empty-domain and unobserved cases. This is a numerical/safety
suite, not a timing benchmark or production-scale qualification.
