# Load a verified bounded source selection

[bounded_source_loader.py](../../tools/bounded_source_loader.py) imports a
completed chunk selection and its verified inventory witness into a new isolated
schema in the existing marked PostgreSQL fixture sandbox. This connects the
[source registration](source-run-registration.md), immutable source chunks and
measured inventories with native database loading.

This is synthetic development tooling. It accepts the existing bounded selection
limits, not a full S1/S2 source. Selected windows can omit referenced people and
concepts; the resulting schema is for loader validation, not a certified complete
CDM. It does not run analyses, publish analytical results or create a viewer bundle.
Registration remains `planned_not_admitted`; this explicit bounded operation does
not treat a registration as full-tier execution permission.

## Load and inspect

First create a completed materialization, collect its inventory, and register both
as a witness using the linked guides. All artifacts must match current pinned code.
Use the existing fixture credentials created by `tools/postgresql_fixtures.py`;
the loader does not create databases or roles. From the checkout root:

```sh
mkdir -p ../source-load-work
python3 tools/bounded_source_loader.py load \
  --registration-dir ../source-run-work/witness-registration \
  --state-dir .local/postgresql \
  --output-dir ../source-load-work/load-001
```

This requires native `psql` 17.10 and the marked PostgreSQL 17.11 fixture database.
Connection services must identify the existing fixture owner; loopback TCP and
local Unix sockets are accepted. A matching name alone is insufficient: database,
owner, fixture marker, server version and local server address are checked. The
mutating transaction repeats those guards on its own connection. Remote servers,
unmarked databases and other principals are refused.

The output directory must be new, outside the checkout and separate from the
registration/source/inventory directories and their ancestors. Direct output
symlinks are refused. Each attempt uses a fresh `cdm_selection_<random-id>` schema.
Existing schemas are never reset or replaced. A nonblocking POSIX file lock
prevents cooperating cleanup from racing an active load. Keep operator-owned
local directories; arbitrary hostile filesystem or database writers are not isolated.

`complete.json` records the generated schema under `request.schema`, exact loaded
row/null facts for all physical tables, source/registration/code bindings, client/
server versions and explicit scope flags. `source_coverage=bounded_selection_only`,
`whole_source_loaded=false`, `full_tier_generated=false` and `qualifying=false`
remain true descriptions even when selected auxiliary tables are complete.

## Freeze, copy, validate, commit

Before database work, the loader replay-verifies the registration witness, locks
the original materialization, and freezes its bounded CSV chunks in a private
temporary directory. It preserves accepted internal hard-link topology and then
replays the frozen files against the indexed source again. Original files are
unchanged. The locked physical CDM DDL is checked immediately before script
construction. Registration verification accepts a cooperative stop callback for
its witness scan, so the loader's stop/deadline also covers that stage.

One database transaction creates the new schema and all physical tables for the
declared CDM version. Native frontend
[psql `\copy`](https://www.postgresql.org/docs/17/app-psql.html) reads the frozen
files, skipping each chunk's header separately and preserving the explicit
unquoted `\N` null marker. The fixture uses the locked table DDL without primary-key
enforcement, keeping duplicate rows and repeated identifiers intact.

Before `COMMIT`, every table's row count and every column's null count must match
the verified source facts. Unselected tables must be empty. A mismatch raises an
error inside that transaction. Reader access is granted to the existing fixture
runner; it receives SELECT rather than write privileges. There are no clinical
joins or source-wide analyses in this path. Successful native loading and these
checks do not establish relational completeness or analytical parity.

## Bounds and cancellation

| Control | Limit/default |
|---|---|
| Source | Existing materializer limits: 100,000 selected rows, 64 windows, 128 chunks and 64 MiB CSV budget |
| Invocation | `--seconds`: 1–120 seconds; default 120, including input verification |
| Sampled free space | 64 MiB default floor; frozen-copy preflight also requires room for the declared CSV bytes |
| Temporary files | Frozen bounded source plus small metadata; 1 MiB SQL cap and sampled 1 MiB stop thresholds for each psql stdout/stderr file; inventory verification may separately use its bounded SQLite replay copy |
| Connection / statement / lock / idle transaction | 5 / 30 / 2 / 10 seconds respectively |

The time and free-space checks are cooperative, not OS reservations. Blocking
filesystem calls can exceed a sampled deadline; child output can overshoot a stop
threshold between polls. Filesystem allocation, database/
WAL growth and caches are additional. Use external CPU/memory/disk containment for
resource experiments. Native psql is the tested transport; process-signal behavior
through arbitrary executable wrappers is not certified.

SIGINT/SIGTERM request stopping during verification, copying or the owned psql
process. The controller sends SIGINT to its owned child process group, then uses
finite TERM/KILL escalation if it fails to exit. SQL is run with `ON_ERROR_STOP`;
errors before commit and disconnects abort the uncommitted transaction. No signals
are sent to unrelated database or host processes. CLI exits are 0 on success,
1 for refusal/failure, 2 for syntax, 3 for deadline, and 130/143 for INT/TERM.

## Failures and cleanup

`request.json` is persisted before submitting DDL and retains the exact generated
schema/marker even if writing the success receipt later fails. `attempt.json`
retains failure/stop diagnostics when writable. If mutating SQL was attempted,
an unsuccessful invocation conservatively reports `commit_outcome=unknown`.
A connection loss, late stop or receipt-write failure can occur after commit;
do not infer rollback or retry into the same directory from a missing receipt.
Input failures before output initialization may leave no attempt directory.

Preserve the evidence and wait for the owned client to stop. To inspect and remove
only the recorded selection schema, including an uncertain attempt:

```sh
python3 tools/bounded_source_loader.py drop \
  --state-dir .local/postgresql --output-dir ../source-load-work/load-001
```

Cleanup takes the same operation lock and checks the saved schema pattern plus the
actual current owner/marker. It repeats the database and owner/marker guards in
the transaction that drops the schema. Wrong markers/owners are refused; an absent
schema is reported as absent. It does not delete source artifacts, other loaded
selections, results schemas, credentials or volumes. There is no automatic reset,
resume, publication promotion or full-tier override in this command.
