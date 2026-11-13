# Completed source to batch-analysis handoff

[source_analysis_handoff.py](../../tools/source_analysis_handoff.py) connects a
completed [whole-source stream](partition-stream.md) to the matched-analysis
contributor tooling. It captures a small, versioned input descriptor plus the
independent reference SQL for the frozen 142-output profile. It does not execute
analyses, publish results or authorize a benchmark tier.

## Prepare and check

Use the already provisioned, marked PostgreSQL fixture database and a new output
directory outside the checkout. The completed stream, reducer, audit, source
registration, code and fixture state must still be available:

```sh
python3 tools/source_analysis_handoff.py prepare \
  --stream-dir /absolute/work/completed-stream \
  --state-dir /absolute/private/fixture-state \
  --output-dir /absolute/work/analysis-input
python3 tools/source_analysis_handoff.py verify \
  --state-dir /absolute/private/fixture-state \
  --output-dir /absolute/work/analysis-input
# Static file/compiler integrity only; no database connection:
python3 tools/source_analysis_handoff.py inspect \
  --output-dir /absolute/work/analysis-input
```

Preparation requires a version-2 whole-source completion receipt and a complete
independent inventory audit. Selected partitions, incomplete or dropped sources,
changed code/recipe/registration identities and source STOP files fail closed.
The handoff directory must be separate from all source/control/fixture-state
inputs. Existing outputs are not overwritten.

The batch capture uses a read-only repeatable-read PostgreSQL transaction. It
checks namespace ownership/marker, physical table and column inventory, types,
nullability, original column ordinals, completion header, journal cardinality,
row/null counts and the fixture reader's grants. The database instance/settings
must match the registered target. These count queries scan batch source data;
they are not an interactive provider/viewer read path. Existing time, output-byte,
free-space and cancellation guards apply. Output is written only after capture.

`handoff.json` binds these observations to the stream request, source plan, audit,
profile and implementation hashes. `reference.json` contains the same independent
138-query compiler used by the matched comparator; four metadata outputs use the
shared serialization boundary. Its canonical bytes have a separate 4 MiB limit.
Inspection rechecks the file hashes and regenerates the expected reference SQL;
editing SQL and merely recomputing its hash does not replace the compiler.

Verification repeats the live checks. Source instance/schema/count/grant changes
require a new handoff. The descriptor is not a retained PostgreSQL snapshot:
analysis must capture its own shared snapshot. The source owner must preserve
the completed candidate. These are trusted-owner metadata/count checks, not a
cryptographic rehash of every live database row or protection from a hostile
owner changing values while preserving counts/nulls. The original inventory audit
proves generated source bytes; it does not make a mutable database immutable.

Completion is historical evidence, so reading it does not require a still-live
loading lease. The descriptor always says `analysis_execution_authorized=false`
and `qualifying=false`. Real calibration/paired execution still requires a
registered allocation, scoped authority, live controls and complete telemetry.

## Compact shared-snapshot proof

With the current package/JDBC installed and fixture configuration available:

```sh
ACHILLES_NEXT_FIXTURE_STATE=/absolute/private/fixture-state \
  Rscript --vanilla tests/tracer/stream-analysis.R \
  tools/tracer_fixture_config.R /absolute/work/analysis-input
```

This opt-in proof refuses inputs above 20,000 total physical rows, 1,000 people or
2,000 observation periods. The reference path retains its existing 10,000-event,
50,000-aggregate-row and 64 MiB aggregate-stage limits; statement timeouts remain.
It imports one exported repeatable-read snapshot into both unchanged analyzers,
compares all 138 numerical and four metadata outputs, checks source inventory
counts/capabilities, and seals/natively validates both candidates. Physical counts
are additionally checked inside that captured snapshot. Candidate inspection is
bounded to 50,000 rows; it is not the representative-scale comparison transport.

Source STOP/dropped/active controls are checked at phase boundaries and during
candidate capture; per-statement timeouts bound SQL waits. This is not the
reference run's live lease/telemetry controller.

The proof preserves the source rows and source grants. Disposable result schemas
and an originally absent fixture TEMP privilege are cleaned up. It writes
`analysis-results.json` only after comparisons and both validations pass; a zero
process exit is also required because cleanup runs at exit.
`analysis-fixture-state.json` records the disposable schema names and prior TEMP
privilege for manual recovery if process termination prevents cleanup. No approval,
publication/export, serving or browser-memory qualification is inferred. The
existing [small matched comparator](matched-reference.md) separately covers full
and projected publication/export and source-denied serving. A large handoff is
not permission to bypass this proof's small-input limits.

Native tests can opt in to this additional proof with both
`ACHILLES_NEXT_TEST_STATE` and `ACHILLES_NEXT_HANDOFF_R_PROOF=1`. The normal native
transaction suite checks handoff creation/live drift without launching R again.
