# Experimental core batch planner

`planCharacterizationBatch()` is a pure, deterministic planner for the frozen
142-result core profile. It connects to no database and runs no clinical SQL.
The plan enumerates 51 topologically ordered logical modules, their dependencies,
physical input columns, output populations and exact grains. Logical modules are
not promises of one SQL statement each. Complete core result generation is not yet
implemented; the plan explicitly reports `planning_only`. Population/observation
kernels identify `available_in_population_baseline`; the eight-domain/density
kernels and measurement presence identify `available_in_domain_baseline` in the
[domain producer](domain-baseline.md). Other modules report `not_implemented`. The existing 15-output development tracer remains separate.

```r
plan <- planCharacterizationBatch(
  cdmSchema = "cdm", sourceId = "local-source", declaredCdmVersion = "5.5")
plan$modules
```

Full recorded history and all observed concepts are the default. There is no
concept allowlist, per-concept query loop or inherited 120-month bound. An
optional `window = list(start = "2020-01-01", end = "2024-12-31")` restricts the
observed-window view of the plan; all-recorded metrics retain physical source
rows, including undated and unlinked records. Compiling a full-history period
query later requires resolving finite source-derived history bounds. A declared
CDM version does not stand in for capability checks against actual columns.

The source, scope, profile, module registry, SQL and R implementation/dependency
identities bind the plan hash. Changed definitions or request require a new plan.
The module registry is checked against its lock and the complete profile. No
result/profile contract or metric definition changes here.

## Materialization and exact grains

`strategy = "reference"` is the default. `strategy = "shared"` records explicit
evaluation candidates for observation interval union, narrow domain classification
and linked-person presence. It does not automatically select or certify a faster
plan. A classification bag preserves physical duplicates and uses `EXISTS`
membership against valid merged intervals; it must not join overlapping intervals
into extra clinical rows. Unit vocabulary lookups also avoid row multiplication.

Each output retains the population/grain in the profile. Full-scope, window,
monthly and yearly people require distinct counting at those exact periods;
monthly people are never summed to obtain a wider period. Exact summaries keep
concept, known unit and raw NULL/zero operator groups separate. Numeric core
summaries use all-recorded rows, including unobserved, undated and unlinked rows;
observation numeric summaries have no operator dimension. Recompute integer-rank
quantiles from raw values or exact frequencies. Do not average monthly percentiles,
pool units or mix these core semantics with the legacy observed tracer.

## Internal execution substrate

The internal worker substrate is a development foundation, not a public report
executor or arbitrary-SQL service. It uses a dedicated writable repeatable-read
transaction and a role with source SELECT access plus PostgreSQL TEMPORARY access.
The old tracer still uses its own read-only transaction. Permission to materialize
does not imply permission to update the CDM.

Temporary tables use `achillesnext_` names, are private to one backend, and use
`ON COMMIT DROP`. Success, exceptions and cancellation roll back the transaction;
disconnect also removes abandoned backend state. No durable retention or
cross-process recovery/reuse of staging is enabled. Explicit checks reject
null/duplicate PERSON identity before dependent work. Missing/inaccessible source
columns fail the relevant primitive rather than fabricate a zero result.

The engine creates a stage once and does not mutate it. Within that transaction,
the stage key binds the plan/definitions, observed schema fingerprint, backend
snapshot token, SQL, indexes and already verified dependency keys. Reusing an ID
with different dependencies or SQL is rejected. These are trusted internal engine
operations, not validation of caller-supplied arbitrary SQL or detection of
deliberate same-session table tampering. A new transaction always recomputes;
an operator's release/snapshot assertion alone cannot enable reuse.

The development default is a 64-MiB total stage-byte budget checked **after each
materialization**, a 30-second local statement timeout and a two-second local lock
timeout. These leave server settings unchanged. Byte checks include table/index
size but cannot prevent a single statement's transient disk overshoot or bound
sort/hash spill. Large workloads still need resource preflight and external disk
monitoring. No large-data or production resource certification is implied.

None of these stages is a serving object. Existing approved publications are
untouched by workspace work, including failed/recomputed work. Interactive readers
continue to read saved approved bytes without CDM credentials.

## Reproduce a small physical-plan comparison

After installing from this checkout, run the offline planner and identity tests:

```sh
Rscript --vanilla tests/tracer/batch-plan.R
Rscript --vanilla tests/tracer/implementation-identity.R
```

With the marked synthetic PostgreSQL sandbox and fixture JDBC configuration:

```sh
python3 tools/benchmark/batch_primitives.py \
  --config tools/tracer_fixture_config.R \
  --output-dir /new/private/batch-probe
```

Use a **new directory outside the checkout**. The harness creates only three small
deterministic synthetic inputs (empty, 24 and 1,224 event rows per domain), three paired
reference/shared repeats in alternating order, and the nine physical domain
adapters. It adds no fixture dependency to the installed package. The fixture
matrix runs once per strategy in CI (`--trials 1`); the default three pairs are
reserved for exploratory local comparisons, reducing routine CI work. The fixture
owner temporarily grants TEMPORARY to the runner when needed and restores it;
all disposable source schemas and temporary tables are removed. Source tables
remain SELECT-only for the worker. No database role or server setting is changed
outside this marked sandbox.

The probe executes capture periods, linked-event frequency histograms and numeric
primitives. It is **not** complete output generation for the 142-result profile:
missing concept/period zero skeletons, metadata, domain-specific panels and
store-writing pipelines remain future generator work. No clinical record or
person-level histogram input leaves the database; the harness returns aggregates.

Python independently expands tiny observation intervals to days, counts people
per period, preserves source multiplicity, and computes exact Decimal/rank
statistics by concept/unit/operator. It compares raw-sort and weighted summaries,
including empty groups, NULL/zero/unknown concepts, repeated rows, absent units,
non-finite values, orphan people, partial months and above-JavaScript-safe values.

Measured `EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT JSON)` executes each CTAS once.
The report records source scan nodes, actual scan rows × loops, shared block
operations, temporary block I/O, materialized relation bytes, wall time and cleanup.
It also records every submitted SQL statement's hash, kind, duration and outcome,
including indexes, ANALYZE, metadata and aggregate reads. Materialization statement
counts and all submitted SQL counts are labelled separately; JDBC rollback is a
separate transaction operation. Counts must remain independent of source concept
cardinality for the fixed set of exercised module/grain consumers.
Nested node buffer totals are not summed. Source physical bytes are explicitly
unavailable; buffer operations are not unique source bytes. Preflight work is
reported separately. These measurements include staging and aggregate writes;
they are not estimates of a production full-profile run. Process/OS cache state
is uncontrolled and is not labelled cold. A slower shared plan is a valid result,
and does not change the default reference strategy.
