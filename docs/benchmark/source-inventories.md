# Measured source inventories

[source_inventory.py](../../tools/source_inventory.py) measures a completed
[bounded source selection](streaming-scale-cdm.md). It stores exact counts on
disk so a growing number of distinct values does not require an in-memory
histogram. Run it with Python 3.10+ and its standard-library SQLite module on the
same local POSIX filesystem assumptions as the materializer.

This is development tooling for synthetic source calibration. It does not query
a CDM database, generate additional source rows or produce a viewer bundle.

## Collect and verify

After the materializer has written and verified `complete.json`, run from the
checkout root:

```sh
python3 tools/source_inventory.py collect \
  --source-dir ../streaming-source-work/job \
  --output-dir ../streaming-source-work/inventory
python3 tools/source_inventory.py verify \
  --source-dir ../streaming-source-work/job \
  --output-dir ../streaming-source-work/inventory
```

The output directory must be new, outside the checkout and separate from the
source directory, including its ancestors and descendants. Direct output
symlinks are refused; a parent-directory alias is allowed. Both operations hold
the materializer's exclusive nonblocking lock and replay-validate its complete
source prefix. The collector leaves source files unchanged. Use operator-owned
directories; this is not isolation from hostile concurrent filesystem writers.

Successful output has two files:

- `inventory.json`: version 1 completion receipt, source and code bindings,
  physical database hash/bytes, resource controls and per-table summaries.
- `inventory.sqlite`: exact histograms in `bins` and exact encoded-row occurrence
  counts in `row_bag`. These are development artifacts, not an analytical result
  store schema or an additional supported CDM engine.

The receipt binds to the materialization plan and completion receipt, indexed
generator, materializer and collector code. Changing those inputs requires a new
collection with matching source pins. Verification checks physical hashes, then
copies the database to bounded temporary storage and subtracts every replayed
source count. Missing, excess or changed bins fail verification even if someone
updates the physical hash. Original artifacts are read-only during verification;
the disposable replay copy is removed afterward. Summary facts are recomputed.

## What is measured

Each table has a logical recipe row count and an explicit coverage state:

| Coverage | Meaning |
|---|---|
| `not_selected` | No window selected; widths, nulls, duplicates and histograms are unmeasured (`null`). |
| `selected_windows` | Facts describe only the chosen nonoverlapping windows. |
| `full_table` | All logical rows of this table were selected, including an explicitly selected empty table. |

Per selected table, the receipt records selected rows, CSV bytes including each
chunk header, minimum/maximum encoded data-row width, column null counts, exact
distinct rows and duplicate excess (`selected_rows - distinct_rows`). Duplicate
identity is the complete encoded CSV row, including identifiers; it is not a
clinical duplicate definition. Header bytes do not enter the row-width histogram
or duplicate comparison. An empty selected table has zero counts, no width and
empty histograms; an unselected table is not treated as empty.

`bins` has columns `table_name`, `dimension`, `value_json`, `n`. Dimensions are:

- `encoded_row_bytes`: encoded CSV data-row widths, including the trailing newline.
- `column:<name>`: marginals for concept IDs, source values, dates, person IDs,
  vocabulary metadata and selected representation fields. The exact column list
  is recorded per table as `histogram_columns`.
- `joint:representation`: measurement/observation concept, unit, raw operator,
  numeric state and person-skew bucket. This supports conditional distributions,
  such as unit frequencies within a measurement concept, without a Cartesian
  expansion or a second clinical-data query.

Values use explicit JSON tags for `null`, `not_in_schema` and `value`. Raw text
is preserved: zero, empty string and whitespace remain distinct. Raw numeric
values also have marginal bins; the joint classifies them as `missing`, `finite`,
`non_finite` or `invalid`, without floating-point coercion. Operator absence in a
physical schema differs from a present null operator. The skew bucket follows
the synthetic recipe: the first `max(1, people // 5)` IDs are `hot_person`, with
`other_person` and `missing_person` separate. These labels are recipe attributes,
not observed patient-level clinical categories.

For example, inspect concept-conditional units using Python's SQLite module:

```python
import sqlite3
from contextlib import closing
from pathlib import Path

uri = Path('../streaming-source-work/inventory/inventory.sqlite').resolve().as_uri()
with closing(sqlite3.connect(uri + '?mode=ro', uri=True)) as db:
    for row in db.execute('''
        SELECT json_extract(value_json, '$.concept') AS concept,
               json_extract(value_json, '$.unit') AS unit, sum(n) AS rows
        FROM bins
        WHERE table_name = 'measurement' AND dimension = 'joint:representation'
        GROUP BY concept, unit ORDER BY rows DESC LIMIT 20
    '''):
        print(row)
```

That example needs SQLite JSON functions. Collection and verification use no
SQLite JSON extension. The tool makes no inference about unsampled logical rows.
Use windows spanning duplicate and skew boundaries when preparing calibration
inputs; a small window can miss whole recipe strata.

## Resource and failure boundaries

| Control | Default / hard maximum |
|---|---|
| Source selection | Materializer limits: 100,000 rows, 64 windows, 128 chunks, 64 MiB CSV |
| Main SQLite file | `--database-bytes`: 128 MiB; minimum 64 KiB, rounded down to 4 KiB pages |
| Distinct stored keys | `--bins`: 1,000,000, across marginal/joint/width bins **and** the exact row bag |
| Counter cache | 4,096 keys and 2 MiB accounted key payload; flushed into the SQLite transaction at either boundary |
| Encoded data row / histogram value | At most 64 KiB per row / 4 KiB per encoded JSON value |
| SQLite page cache | Requested 4 MiB per connection |
| Invocation time | `--seconds`: 120 seconds, minimum 1; includes source replay |
| Sampled free-space floor | `--min-free-bytes`: 16 MiB; allowed maximum 1 GiB |

Counter-cache flushes are not durable checkpoints. SQLite commits once after all
source scans and validation succeed.

SQLite's [max_page_count](https://www.sqlite.org/pragma.html#pragma_max_page_count)
caps the main database. Its rollback journal, filesystem allocation, metadata,
Python object overhead and process memory are additional. Collection uses a
DELETE rollback journal and full synchronous writes. Verification needs a
temporary copy up to the same database cap, plus its own SQLite connection cache;
only this disposable copy has journaling disabled. Free space is sampled on both
output and temporary filesystems. These checks are not disk reservations, a
whole-process memory limit or a hard OS deadline. Blocking I/O may exceed a
sampled deadline. Use external resource containment for reference runs.

`verify` uses the limits recorded by `collect`; it rejects limit overrides. SIGINT
and SIGTERM stop cooperatively with exit codes 130/143; deadline stops return 3.
Operational/refusal errors return 1 and command syntax errors return 2.

No completion receipt is published until all scans/counts, validation, database
commit, sync and hash succeed. Failures retain `failed.json` when writable and
partial database evidence. SIGKILL may leave no diagnostic. Partial/failed output
is refused by `verify`; preserve it and collect into a new directory. Histogram
collection has no checkpoint/resume yet. Source materialization retains its
independent checkpoint/restart support. A failure does not remove or replace a
previous inventory directory.

Every receipt sets `full_tier_generated=false` and `qualifying=false`. Even a
complete inventory of a selected auxiliary table does not establish a complete
S1/S2 source, source-wide clinical distributions, calibrated storage headroom or
representative-scale analytical performance.

For a frozen target with resource observations and an optional verified inventory
witness, see [source-run registration](source-run-registration.md). Registration
records preparation evidence; it does not enable a full-tier run.
