# Source execution and result storage

AchillesNext computes reports in explicit batches and views saved, approved
aggregates. A source engine executes the OMOP queries. A result store owns
building releases, typed persistence, validation receipts and approved
publication. Neither the viewer nor the publication reader needs CDM access.

## Implementation boundary

The implemented deployment uses PostgreSQL for both source and store, in distinct
schemas in one database. Generators own one repeatable-read JDBC transaction.
Source privileges are SELECT-only, with private TEMP work where required; store
writes roll back with generation failures. Source identity remains unknown unless
verified separately. A transaction snapshot is not a reusable release identity.

Registered profiles now have independently exercised internal source and sink
interfaces. These are package internals, not a public remote-adapter API:

| Boundary | Input and output | Responsibility |
|---|---|---|
| `.profile_source(query, assets, schema, metricOrder, maxRows)` | Borrowed `one(sql)` / `stream(sql, visit)` callbacks; returns `schema_sha256`, exact `source_count` and `stream(visit)` | Source schema/type/membership preflight; dependency-ordered aggregate SQL; at most `maxRows` records of 64 KiB each; single-use stream |
| Source aggregate record | Exactly `metric_id`, `dimensions`, `row_kind`, `values` | Registered metric identity and dimensions; counts are strings, not JSON numbers; no patient rows or source text |
| `.profile_consume(source, writer, assets)` | Source descriptor/stream and a sink exposing `add(metricId, row)`; returns exact per-metric row counts and transferred-row total | Builds typed row identities and explicit denominator references from registered rules; caches singleton targets; checks singleton inventory |
| `.store_writer(tx, releaseId, assets)` | Complete typed rows; `add`, `flush`, `finish` | Validates rows, bounded SQL persistence and failure poisoning; does not commit or publish |
| Store lifecycle | Initialized store, profile/run/dataset context, sealed release and approval policy | Reconciliation, sealing, native validation, policy projection, export and explicit current-pointer promotion |

The source receives no result-schema handle or writer. The consumer receives no
SQL executor or database connection. The coordinator in `generateAnalysisProfile`
still owns the shared transaction, profile installation check, release metadata
and final reconciliation. Callbacks wrap trusted installed SQL; they are not a
SQL sandbox or a new security boundary. Exceptions propagate to transaction
rollback; a failed or exhausted source stream cannot be replayed in that run.

The registered example supports exact PERSON count partitions only. Its source
and consumer separation does not extend its allowed metric shapes to summaries.
The population/eight-domain producer still uses PostgreSQL staging and
`.domain_stream_sql()` joins to persisted denominator targets. That is an explicit
remaining source/store coupling, not a cross-database implementation. The shared
writer, saved validation and publication already operate on aggregate data.

## Requirements for another source adapter

Keep source execution and store lifecycle independent. An adapter must establish
the following before writing a candidate that can be declared complete:

1. Bind source ID, observed schema/type metadata, installed profile/SQL identities,
   scope, numeric policy and a within-run consistency basis. Separately record
   whether data and vocabulary release identities are verified or unknown.
2. Own its source snapshot/session and any private source workspaces. Metadata,
   membership checks and all dependent aggregates must describe the same source
   state. A multi-statement source needs an engine-specific consistency mechanism
   or a verified immutable release; statement-level snapshots alone are insufficient.
3. Emit only registered aggregate records, in dependency order, through bounded
   string transport. Enforce record, total-row and total-transfer-byte budgets;
   exceeding a budget fails rather than truncates. The current example enforces
   row count and per-record bytes, not a separate total-byte configuration.
4. Resolve denominator mappings within source-side aggregate relations or through
   bounded, store-side aggregate matching. Do not query the CDM once per result
   cell, transfer patient records or load an unbounded denominator catalogue in R.
   Preserve NULL/zero/absent tags and explicit unsupported/empty states.
5. Signal success only after stream exhaustion and inventory reconciliation.
   Source errors, overflow, cancellation, unsupported required types and incomplete
   transfer invalidate the candidate. Always close cursors and source workspaces.

An adapter's descriptor also needs engine/version, actual observed precision and
scale, arithmetic/session settings, and the snapshot/release evidence used. The
current two-count source descriptor is intentionally narrower; those additional
fields and their persisted binding require implementation before remote transfer
is exposed. No new wire or persisted format is defined by this guide.

The store must accept typed rows without needing source SQL, credentials or
cross-engine joins. It owns release/run/dataset metadata, exact value validation,
denominator integrity, content revision and seal/write concurrency. Validation
and approval must finish before a new publication can replace the old one.
Storage transactions/triggers are store capabilities, never assumptions about
the source engine. A storage adapter change requires its own migration and
compatibility evidence; SQL rendering is not evidence for those guarantees.

## Deployment choices and permissions

| Deployment | State | Permissions and consistency |
|---|---|---|
| PostgreSQL source and PostgreSQL store in one database | Implemented development path | SELECT-only source access, TEMP for baseline staging, restricted result writes in one owned transaction; separate installer/publisher/serving permissions |
| Databricks SQL warehouse source → institution-local PostgreSQL store | Intended experimental adapter path; not implemented or certified | Separate source and store connections/credentials; source SELECT plus explicitly authorized private staging if needed; store writer has no CDM grants; source snapshot/version pinning must be proved |
| Snowflake source → institution-local PostgreSQL store | Alternative experimental adapter path; not implemented or certified | Same aggregate-only boundary; engine-specific consistent source and exact arithmetic proof required |
| Native warehouse result store or PostgreSQL source in another database | Not implemented | Requires additional lifecycle/transfer implementation; PostgreSQL store transactions cannot simply be translated into warehouse SQL |

For a warehouse source, the proposed bridge runs in the institution and streams
restricted aggregates through R to PostgreSQL. It adds a PostgreSQL deployment
dependency for that path, but no mandatory external service, cloud export, browser
database or new web backend. Aggregate records can still be sensitive and must
remain restricted until the normal approval policy is applied.

There is no distributed transaction across source and store. Before successful
transfer, source failure or cancellation must abort the store transaction and
preserve the previous approved publication. A later validation or approval
failure leaves no newly promoted current publication. Recovery defaults to full
recomputation; a flushed batch is not a checkpoint. Durable resumable transfer,
remote ingestion, source adapters and a second-engine execution proof are not
provided by the current API.

## Exact numeric policy

Existing mathematical profiles and wire schemas remain authoritative. An adapter
must reject a required input or operation it cannot represent exactly, rather
than silently changing the question or casting approximate input to DECIMAL.

| Value | Contract |
|---|---|
| Counts, frequencies, ranks and identifiers | Exact integer arithmetic; canonical strings across JDBC/R/JSON, including values above 2^53. Counts are nonnegative; raw identifier tags can be signed. NULL, zero and schema absence stay distinct. |
| Finite numeric inputs | Exact fixed-point/integer source types accepted by the specific producer. Inspect physical types before casts. PostgreSQL baseline numeric fields accept NUMERIC or integer types; the older measurement tracer specifically requires NUMERIC. Registered PERSON inputs require integer types. |
| Approximate inputs | PostgreSQL REAL/DOUBLE, warehouse FLOAT/DOUBLE and implicit floating promotions are unsupported for exact profiles. A decimal cast of a float does not recover the original decimal value. Any approximate profile would need a separate definition and validation. |
| Decimal transport | Plain canonical finite strings, no exponent, plus sign, leading zeroes, trailing fractional zeroes or negative zero. Remove representational zeroes with string operations only; never parse analytical values through R double or JavaScript Number. |
| Summaries | Exact `n`, `sum`, minimum/maximum and nearest-rank quantiles at `ceil(p × n)`; ties/duplicates retain frequency. Mean is the exact pair `sum/n`, with numerator equal to sum and denominator equal to n. Do not substitute rounded AVG or interpolated/approximate percentiles. |
| Non-finite and missing | Count their presence and apply the profile's ordered eligibility reasons where defined. NaN/±Infinity cannot become a finite stored statistic, zero or silently dropped source record. Empty eligible groups have n=0 and NULL statistics, distinct from absent groups. |
| Overflow or resource limits | Fail the candidate before approval; no wraparound, saturation, NULL-on-error aggregate or partial-success truncation. A database numeric capacity is not the package's supported row/resource capacity. |

PostgreSQL NUMERIC is exact but a declared scale can round input; the adapter
preserves the value actually stored, not precision lost during ETL. Unconstrained
NUMERIC has finite implementation limits, while the package also applies row,
sort-key, page and arithmetic-work limits. See the
[PostgreSQL 17 numeric documentation](https://www.postgresql.org/docs/17/datatype-numeric.html).

Databricks DECIMAL has at most 38 digits with scale from zero through precision;
an unqualified DECIMAL defaults to (10,0). Explicit casts can round. Its SUM
return type and overflow behavior depend on input type and execution settings.
An adapter must inspect the resulting types and enforce failure on overflow;
neither default casts nor a translated SUM establish parity. See
[DECIMAL](https://docs.databricks.com/aws/en/sql/language-manual/data-types/decimal-type)
and [SUM](https://docs.databricks.com/aws/en/sql/language-manual/functions/sum).

Snowflake NUMBER has at most 38 digits, maximum scale 37 and a default of (38,0);
integer aliases are NUMBER(38,0). Arithmetic result scale can differ from input
scale. An adapter must prove all intermediate products and accumulations fit,
not just the final serialized value. See
[numeric types](https://docs.snowflake.com/en/sql-reference/data-types-numeric)
and [arithmetic operators](https://docs.snowflake.com/en/sql-reference/operators-arithmetic).

For either warehouse, preflight must conservatively bound count/rank arithmetic,
value×frequency, partial and final sums. Cancellation between large positive and
negative values does not prove intermediate safety. If the bound exceeds exact
capacity, reject or implement and qualify an exact alternative; do not lower
scale. Transporting the rounded result to a wider PostgreSQL NUMERIC cannot fix
earlier loss. No universal 38-digit restriction is added to PostgreSQL profiles.

## Contributor verification

After package installation, run from the checkout root:

```sh
Rscript --vanilla tests/tracer/source-store-offline.R
Rscript --vanilla tests/tracer/registered-profile-offline.R
```

The first test exercises source callbacks independently of a store, and a typed
sink independently of SQL. It checks exact large counts/identifiers, denominator
binding, dependency order, malformed records, resource limits, single-use and
error propagation. The [registered-profile integration](registered-analyses.md#verify-from-a-checkout)
checks real generation, validation, approval and saved readback with source access
removed. These checks do not execute a warehouse adapter or prove summary parity
on another engine.

Before any second source is called supported, its conformance proof must include
one count and one exact summary through source execution, store ingestion,
validation, approval and source-denied readback; independent edge-case oracles;
overflow/type/non-finite rejection; cancellation/partial-transfer rollback; and
the documented source-consistency mechanism. Full-profile and representative-scale
qualification are separate requirements.
