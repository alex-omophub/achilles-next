# Resume a bounded fixture load

[incremental_source_load.py](../../tools/incremental_source_load.py) loads a
verified synthetic source selection into one new PostgreSQL fixture schema, with
one transaction per CSV chunk. It consumes the witness from a
[source-run registration](source-run-registration.md), including a combined
registration produced by the [shared partition loader](partition-shared-load.md).
It does not generate data or run analytical reports.

## Prepare, load and resume

Use a current code-pinned registration with a completed source and inventory
witness. Older registrations must be recreated when their pinned tools change.
The marked local fixture database, owner/runner roles and locked PostgreSQL
17.11/native psql 17.10 tuple must already exist. The owner also needs the
database TEMP privilege for per-chunk staging; the tool refuses if it is missing
and never grants it automatically.

```sh
mkdir -p ../incremental-work
python3 tools/incremental_source_load.py prepare \
  --registration-dir ../partition-shared-work/load-one/registration \
  --output-dir ../incremental-work/load-one

python3 tools/incremental_source_load.py run \
  --output-dir ../incremental-work/load-one \
  --state-dir .local/postgresql --max-chunks 1

# Resume the same candidate using its saved registration and SQL journal.
python3 tools/incremental_source_load.py run \
  --output-dir ../incremental-work/load-one \
  --state-dir .local/postgresql
```

Prepare requires a new output outside the checkout, separate from the registered
source, inventory and registration, including their ancestors. Inputs remain
unchanged. `request.json` binds their identities, code pins, ordered chunks and
a random `cdm_incremental_…` schema. Preparation does not connect to PostgreSQL.
The operation lock excludes concurrent operations on the same local output.

Each run verifies the registration, freezes and replays the complete **bounded**
selection, then checks the live marked local owner connection. It reuses the
saved candidate schema; changing source/code bindings requires a new output.
The temporary source copy is removed when the invocation unwinds.

## Transactional checkpoints

The candidate contains an `achillesnext_load_checkpoint` table. Its header binds
the request and its entries describe a contiguous prefix of committed chunks.
Each mutating transaction takes a schema-specific transaction advisory lock,
checks owner/marker and the journal, and locks the journal table. Cooperating
copies of the same request can safely converge on that prefix. This is a
cooperative protocol, not isolation from arbitrary database owners or hostile
filesystem writers. PostgreSQL releases transaction advisory locks when the
transaction ends. [PostgreSQL locking documentation](https://www.postgresql.org/docs/17/explicit-locking.html)

For a new chunk, frontend COPY first fills a temporary staging table. The chunk's
row/null counts must match before its rows are appended to the candidate and its
journal entry is inserted, all in the **same transaction**. Duplicate rows are
preserved. A failed transaction leaves the previously committed prefix intact.
Committed entries are checked and skipped on retry; local `progress.json` is
informational, never the checkpoint authority. The SQL script uses native psql
`\gset` and `\if` to decide whether COPY is still required after acquiring its
transaction lock. [psql documentation](https://www.postgresql.org/docs/17/app-psql.html)

After every chunk is present, a separate finalization transaction validates row
and null counts across all physical tables, marks the journal complete, and
grants the fixture runner SELECT access. Unselected tables must be empty. Partial
candidates receive no runner schema access. Growing destination tables are not
rescanned after each chunk; cumulative checks occur at finalization. Repeating
a completed run rechecks final facts and grants without copying rows again.

`complete.json` is written after successful finalization. A lost commit response,
progress-write failure or completion-write failure can be recovered by running
the same output again: the SQL journal determines what committed. A receipt is
historical evidence at finalization, not continuous verification against later
external table edits. No existing candidate or analytical publication is replaced.

## Bounds and cancellation

The existing selection caps remain: **100,000 rows, 128 chunks and 64 MiB CSV**.
`--max-chunks` accepts 1–128 chunk transactions per invocation; reaching it before
completion exits 3 with a committed prefix. Header and finalization transactions
are additional. `--seconds` is a cooperative 1–120-second whole-invocation budget.
Keep space for the frozen source, inventory verification scratch and database/WAL
growth; the sampled 64 MiB free-space floor is not a reservation or OS limit.

SIGINT, SIGTERM and a regular empty `STOP` file in the output stop cooperative
work. An active owned psql process group receives finite INT/TERM/KILL escalation;
its unfinished transaction rolls back when the connection closes. Earlier chunks
survive. A process or connection may disappear immediately after a commit, so a
failure is recorded as `database_state=inspect_journal`, never assumed rollback.
Remove `STOP` before resuming. Syntax errors exit 2; other refusals/failures exit 1;
deadline/STOP/chunk-limit exits 3; INT/TERM exit 130/143. Connection, statement,
lock and idle-transaction timeouts retain the bounded loader's limits.

`attempt.json` retains the latest failed attempt and private database diagnostics;
a successful retry leaves that earlier failure record intact. Keep output and
credentials in operator-owned local storage. Blocking filesystem calls can exceed
the sampled deadline. This implementation replays the bounded source and complete
journal on resume; it does not provide a full-tier streaming admission protocol.
Coverage remains `bounded_selection_only`, `whole_source_loaded=false`,
`full_tier_generated=false` and `qualifying=false`.

## Cleanup

```sh
python3 tools/incremental_source_load.py drop \
  --output-dir ../incremental-work/load-one \
  --state-dir .local/postgresql
```

Cleanup takes the local operation lock and the same transaction advisory lock,
and honors the output `STOP` file before connecting and while SQL is running.
Remove `STOP` before requesting cleanup; an interrupted uncommitted DROP rolls back.
Cleanup rechecks the marked target and saved schema owner/marker in the DROP transaction,
and drops only that candidate. Original inputs/current generator code are not
needed. It retains local evidence and writes `dropped.json`; subsequent runs of
that local output refuse to recreate it. Repeating cleanup reports absence.
Archive all cooperating copies of a request after cleanup: a separately copied
output does not share the local dropped marker. No cross-host deletion tombstone
or hostile-owner protection is claimed.

## PostgreSQL regression tests

After provisioning the isolated marked fixture sandbox, run:

```sh
ACHILLES_NEXT_TEST_STATE=.local/postgresql \
  python3 -m unittest discover -s tests -p test_incremental_source_load_postgresql.py
```

The tests require the locked native client/server tuple, refuse foreign targets,
and clean up only their randomly named candidates. They do not reset existing
fixtures. Post-COPY validation failures must leave the committed prefix unchanged;
failed finalization must roll back runner grants; successful resume must preserve
exact rows and duplicates across CDM 5.3/5.4/5.5. STOP before cleanup must
preserve the candidate. The compatibility CI job runs this suite against its
existing PostgreSQL service. When using the containerized CI client, its mounted
temporary directory must match Python's `TMPDIR` so frontend COPY can read the
frozen CSV paths. Offline discovery skips these opt-in database tests.
