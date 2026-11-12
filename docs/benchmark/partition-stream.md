# Stream selected partitions into one audited fixture candidate

[partition_stream.py](../../tools/partition_stream.py) connects the indexed
generator, bounded inventories, global [reducer](partition-inventory.md),
[independent auditor](partition-inventory-audit.md) and PostgreSQL COPY path.
It loads a frozen contiguous selection into one new marked fixture schema.
The job retains the current partition's files, rather than concatenating all
partitions or keeping a growing list of chunk manifests in Python/JSON.

The default is a local selected-partition development path. Covering the entire
logical schedule additionally requires an operator-approved
[resource registration and live lease](source-execution-resources.md).
Completion does not qualify a benchmark tier or publish AchillesNext analytical
results. The original standalone tools remain available.

## Prepare and resume

Use a verified [schedule](source-partition-plan.md), with its registration and
optional witness still available. Choose the starting partition index and count
explicitly; indices are in table-name order. Inspect the planner's `selection`
command before freezing a range. Keep all work outside the package checkout.

```sh
python3 tools/partition_stream.py prepare \
  --schedule-dir ../scale-work/schedule \
  --output-dir ../scale-work/stream --first 100 --count 12

# Repeat until status=complete. Exit 3 means incomplete or a cooperative stop.
python3 tools/partition_stream.py run \
  --output-dir ../scale-work/stream --state-dir ../fixture-state \
  --max-partitions 1 --max-steps 32
```

Preparation freezes schedule, range, code, accumulator budgets and a new random
`cdm_stream_…` schema identity. It generates no data and connects to no database.
Output must be new and separate from the schedule, registration, witnesses and
their ancestors. The PostgreSQL target must satisfy the existing locked-version,
loopback-only, marked fixture database and owner checks. Unrelated databases and
remote servers are refused. The owner needs TEMP for staging.

`--database-bytes` and `--bins` freeze the global accumulator and audit scratch
ceilings, using the reducer's bounds. Per-partition generation/collection caps
remain unchanged. A selection can exceed the previous combined 100,000-row cap
across invocations; no complete selection is assembled as CSV or a Python list.
This does not reserve storage or authorize a full-tier run.

To prepare the complete schedule, supply `--first 0`, its exact partition count,
`--resource-dir /absolute/private/resources`, and an explicit `--postgres-bytes`
growth ceiling between 128 MiB and 384 GiB. That ceiling must fit the registered
database projection, independently of SQLite's `--database-bytes` limit.
The registration must bind this
job, schedule and tier to the current runner/resources, with a verified bounded
source witness. Whole-source preparation creates a version-2 request. Every
resume uses the frozen resource identity and a fresh lease, checking the exact
database/settings before child work or DDL. There is no bypass flag. Cleanup is
still possible after resource expiry or revocation.

Preparation validates the PostgreSQL ceiling against the registered projection;
it does not connect to PostgreSQL or measure the current database size. Each
resume repeats that projection validation and rejects a live database size below
the frozen initial baseline before child work or DDL. SQL then checks the measured
size against the registered initial size plus the ceiling before/after
initialization, around partition COPY/insertion, and finalization.
Before COPY it conservatively reserves eight times the sum of CSV bytes and
64 bytes per row, plus 8 MiB; after staging it reserves twice the staged relation size plus
2 MiB before insertion. These are conservative operation reserves, not a
prediction of the complete source size. Insufficient allowance refuses work or
rolls back the current transaction without advancing its journal. The database
size counter includes other fixture schemas, so unrelated growth counts against
the budget. It excludes WAL; the live verified filesystem/pool lease also guards
WAL and actual free space. These sampled/transaction checks do not replace kernel
limits or reservations and are not an exact hard filesystem quota.

## Durable order and file retention

1. Initialize a private marked candidate namespace and PostgreSQL header/journal.
2. Generate and inventory one bounded partition. Source chunks resume using the
   materializer checkpoint. Child initialization uses a temporary directory and
   atomic rename; an interrupted, unpublished initialization is regenerated.
3. Append to the global disk-backed inventory. Its partition receipt is durable
   independently of the PostgreSQL transaction.
4. Freeze a verified copy of this partition's CSVs. COPY into a temporary table,
   verify row/null facts, insert into the candidate, and commit its receipt and
   prefix/hash-chain update together. One partition is one database transaction;
   an unfinished transaction repeats that partition, preserving prior commits.
5. Remove the completed active partition only after its database receipt matches
   the inventory receipt. A lost commit response is adopted from PostgreSQL on
   restart. An interrupted removal resumes without reading deleted CSVs.
6. Audit the stable global inventory, regenerate expected observations, compare
   all keys/counts and read every accumulator byte. The auditor is resumable.
7. Traverse the PostgreSQL partition journal one receipt at a time, with a durable
   cursor/hash chain. It must match the independent audit's receipt chain.
8. Under the inventory operation lock, recheck the audited source binding and
   validate final database table/null counts. Commit reader grants, completed
   database state and audit binding atomically; export `complete.json` afterward.

Whole-source mode requires the auditor's mandatory whole-source scope, covering
every scheduled partition and physical table. Only after that audit, journal
comparison and final database checks succeed does the version-2 completion say
`coverage=whole_source`, `whole_source_loaded=true` and `full_tier_generated=true`.
Selected receipts retain their false flags. Both remain `qualifying=false`;
generation/loading is distinct from matched reference execution, complete
telemetry and benchmark acceptance.

PostgreSQL is authoritative for the committed loading prefix. Local `active.json`
identifies the currently retained work; `journal.json` records the resumable
journal comparison. The global reducer and auditor have their own transactional
SQLite state. No distributed transaction is assumed: restarts reconcile these
durable records. Mismatched identities refuse reuse instead of reinterpreting work.

The active tree contains at most one partition's source/inventory; COPY also uses
one temporary frozen snapshot. Global row/histogram inventories, audit scratch,
partition journals and the candidate database grow on disk and require their own
capacity allowances. Rollback journals need additional disk. Free-space checks
and deadlines are cooperative, not OS containment or reservations.

## Failures, reader access and cleanup

The candidate grants no runner schema access during loading or failed auditing.
Each job uses a fresh schema; no existing candidate or publication is replaced or
deleted. Final grants are part of the successful finalization transaction. A
failure after that commit can leave a readable, completed candidate without its
local receipt; rerun to recover the receipt without copying rows again.

Source/code/schedule changes, inventory corruption, altered database receipts,
missing candidate schemas or changed owner/markers cause refusal. A missing
partially loaded schema is not recreated. Keep private `attempt.json` diagnostics
and prior completion files; do not treat a historical receipt as current without
rerunning the binding checks. Workspace/checkpoint storage and cooperating writers
are trusted; this is not protection against arbitrary hostile owner edits. The
global inventory has an independent row-bag audit; final PostgreSQL checks validate
loading receipts and table/null counts, not an independent global database row-bag
reconstruction. Repository PostgreSQL tests additionally compare exact text bags.

An empty regular `STOP` file in the job directory blocks work and cleanup.
SIGINT/SIGTERM retain their cause through nested generation, SQLite and owned
psql cancellation. `--seconds` allows 1–120 seconds per invocation;
`--max-partitions` and `--max-steps` allow 1–128. The latter bounds audit and
journal work per invocation. Blocking filesystem operations and crash recovery
can exceed sampled deadlines. CLI exits: 0 success/prepared, 1 refusal/failure,
2 syntax, 3 incomplete/STOP/deadline, 130/143 INT/TERM.

Explicitly discard only this job's marked candidate when it is no longer needed:

```sh
python3 tools/partition_stream.py drop \
  --output-dir ../scale-work/stream --state-dir ../fixture-state
```

Cleanup checks the saved schema identity, local fixture target, current owner and
marker; it does not need the original source files or matching current source code.
It preserves local evidence, writes `dropped.json` and prevents further job reuse.
