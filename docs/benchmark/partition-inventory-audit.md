# Independently audit and finalize an accumulated inventory

[partition_inventory_audit.py](../../tools/partition_inventory_audit.py) checks a
[partition accumulator](partition-inventory.md) against its pinned deterministic
synthetic workload. It regenerates the expected observations using a separate
CSV decoder and histogram implementation, then compares every global key and
count. Original partition CSVs and individual inventory files may be archived.
The source accumulator is opened read-only and remains unchanged.

## Prepare, resume and verify

Keep the source accumulator, partition schedule, registration and any registered
witness available. If a source rollback journal remains after a killed reducer,
run the reducer's `status` command to recover it first. Audit preparation refuses
an unrecovered source journal rather than writing the source itself.

```sh
python3 tools/partition_inventory_audit.py prepare \
  --source-dir ../scale-work/reduction \
  --output-dir ../scale-work/audit

python3 tools/partition_inventory_audit.py run \
  --output-dir ../scale-work/audit --max-steps 32 --page-keys 256

# Repeat run until status=complete; verify before reusing its receipt.
python3 tools/partition_inventory_audit.py verify \
  --output-dir ../scale-work/audit
```

Preparation needs a new output outside the checkout and separate from the source,
schedule, registration, optional witness and their ancestors. It freezes source
request/code identity, schedule, source header and the database's device/inode,
size and modification/change times. Source and audit operation locks are taken
in that order during each invocation. Cooperating writers cannot change the
source while that invocation runs. Appending between invocations invalidates the
old job; prepare a new audit after the source is stable.

`run` processes at most `--max-steps` durable units and returns resumable progress.
An incomplete invocation exits 3. Each expected-data update, comparison cursor,
digest and checkpoint commits together in the audit's own SQLite transaction.
Restart repeats only unfinished work, including after a lost commit response.
`progress.json` is informational; `audit.sqlite` holds the authoritative state.
Interrupted exclusive completion writes recover a matching internal temporary/
published hard-link pair; external completion hard links are refused.

## Independent checks

1. **Regenerate recorded partitions.** Read receipts in partition-index order,
   validate identities, and recreate bounded CSV chunks from the pinned indexed
   generator. Independent parsing produces expected row bags, null counts, widths
   and tagged histograms. The original collector's row-key builder and sink and
   the reducer's merge function are not used. Recreated source completion hashes
   and CSV byte counts must match each receipt. The original inventory-file hash
   is retained as provenance; its old physical SQLite bytes are not reconstructed.
2. **Compare global rows and bins.** Ordered keyset traversal compares expected
   and stored keys/counts in both directions, detecting missing or extra keys,
   changed multiplicities and altered histogram tags. Cached summaries and
   partition totals must match independently regenerated observations.
3. **Read every source database byte.** Fixed 8 MiB chunks are hashed using
   64 KiB reads. A digest chain and byte cursor make this phase resumable without
   serializing a Python hash object or loading the database into memory.
4. **Finalize.** Only after all comparisons, source-byte reads, coverage checks
   and unchanged-source checks succeed is a completion receipt committed inside
   the audit database. `complete.json` is exported afterward. A failed export can
   be recovered by rerunning without regenerating completed observations.

The pinned generator defines the synthetic workload; the audit independently
implements inventory accounting. This is a logical inventory audit, not a SQLite
storage repair procedure or isolation from arbitrary hostile database writers.
Trusted checkpoint storage and cooperating operation locks are required.

## Selected versus whole-source coverage

The default `scope=selected_partitions` audits exactly the recorded receipt set.
A complete selected audit does not imply the entire logical source was produced.
To require every scheduled partition, freeze that requirement at preparation:

```sh
python3 tools/partition_inventory_audit.py prepare \
  --source-dir ../scale-work/reduction \
  --output-dir ../scale-work/whole-audit --require-whole-source
```

Whole-source scope rejects partition gaps and missing final partitions. The
`whole_source_audited` flag becomes true only if every scheduled partition and
physical table's full logical row count is accounted for. `qualifying` and
`full_tier_generated` remain false: this tool audits an inventory and does not
admit a reference benchmark or build/load a CDM database. Source generation,
PostgreSQL loading, allocated resources and scale qualification remain separate.

The standalone audit receipt contains scope, counts, source/request/schedule
bindings and ordered digest chains. The accumulator's own `status` continues to
describe accumulation; its cached counters are not replaced with audit results.

## Bounds and freshness

An audit step is one bounded generation chunk, one comparison page, one 8 MiB
byte chunk or one phase transition/finalization. Existing source chunk caps apply.
Comparison pages allow 1–1,024 keys with a 2 MiB processed-value budget. Iteration
retains one key pair at a time. Expected observations are aggregated in a separate
buffer capped at 2,048 keys and 1 MiB of key payload before SQLite updates.
SQLite uses bounded page caches and disk-backed
expected row/histogram tables. No complete global key list is loaded into Python.

`prepare --database-bytes` and `--bins` freeze scratch database/key ceilings,
defaulting to the source accumulator's budgets. Existing reducer control bounds
apply. Reserve additional space for the expected database and its rollback
journal, including header/checksum overhead. Ceilings and the sampled 64 MiB
free-space floor are not storage reservations or OS containment.

`--seconds` is a cooperative 1–120-second invocation budget. Regular empty `STOP`
files in either source or audit output, SIGINT/SIGTERM, SQLite callbacks and disk
checks preserve their original stop cause. Blocking filesystem work and SQLite
journal recovery can exceed sampled deadlines. CLI exits are 0 success,
1 refusal/failure, 2 syntax, 3 incomplete step budget/STOP/deadline, and 130/143
for INT/TERM. Failed attempts retain diagnostics and prior committed checkpoints.

`verify` rechecks current bindings and the completed durable receipt without
regenerating data. Source append, replacement, metadata changes or a pending
source journal cause refusal. A copied database has a different identity and
needs a new audit. Keep old completion files as historical evidence; read them
through `verify` before treating them as current. There is no cross-host signing
or hostile-writer protection.

Logical row/bin/receipt digests use `ordered-sha256-chain-v1`: start with 32 zero
bytes and hash the previous digest concatenated with canonical JSON for each
ordered record. JSON uses UTF-8, sorted keys, no insignificant spaces,
unescaped Unicode and a final LF, matching the source manifest codec.
Row bytes are base64 encoded. The source-file digest uses
`sha256-chain-8MiB-v1`, chaining canonical offset/byte-count/SHA256 records for
fixed 8 MiB chunks, with a shorter final chunk. These are explicit digest-chain
formats, not a claim to be a single ordinary SHA256 hash of the complete file.
