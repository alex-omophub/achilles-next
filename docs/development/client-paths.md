# Client and SQL-engine paths

AchillesNext's client plans work, submits SQL and handles saved aggregates.
The configured SQL engine stores the CDM and executes scans, joins, sorting and
aggregation. A remote PostgreSQL connection does not require a local PostgreSQL
service or Docker. PostgreSQL is the currently implemented execution engine;
other dialects require adapter and conformance work.

This inventory describes current code, including development-only paths. It does
not establish a laptop hardware minimum or qualify large-source performance.

| Entry point | Work in the client | SQL engine / current boundary |
|---|---|---|
| `planCharacterizationBatch`, `planCharacterizationRefresh` | Load pinned definitions; validate declared CDM 5.3/5.4/5.5, order modules and hash plans | No connection. PostgreSQL is fixed in the plan. These return requests and identities, **not executable full-profile SQL**. Source-derived bounds and schema capabilities are resolved during generation. |
| `planAnalysisProfile` | Plan a separately installed registered profile | No connection; PostgreSQL only. The packaged `reference-person-v1` extension is separate from the 142-output core profile. |
| `generateCharacterizationCandidate`, `executeCharacterizationRefresh` | Validate requests, issue SQL, track states and stream exact aggregate strings into the result store | Core generation in `R/population-baseline.R` uses one owned JDBC transaction, metadata preflight and engine-local temporary PERSON/event/interval/report stages. Patient rows in those stages stay in the engine. Candidate creation does not itself approve a publication. |
| `generatePopulationObservationBaseline`, `generateDomainBaseline`, `generateMeasurementBaseline`, `generateAnalysisProfile` | Generate reduced or registered-profile candidates; stream aggregate output | PostgreSQL source/results connection. Separate source/results schemas; not restricted to loopback or the tiny-fixture database. Core/reduced paths must not be confused with the old tracer. |
| `initializeResultStore`, `registerAnalysisProfile`, `sealResultRelease`, `validateResultRelease` | Install/verify store definitions, run exact native validation and reconciliation | PostgreSQL result-store operations; no local database requirement. Core installation uses the `achillesnext` table prefix. |
| `captureConceptSnapshot` | Stream terminology records to a private file with bounded line parsing | Explicit vocabulary query; not patient data. Disk grows with captured terminology; projection later limits approved saved labels. Snapshot capture does not assert consistency with a separate aggregate run. |
| `publishResultRelease`, `promoteResultPublication` | Validate/project approved rows, write immutable pages, verify them and promote complete output explicitly | Result-store/serving writes plus optional file export. Publication approval and failure preservation remain required. No claim that all client validation/export growth is qualified yet. |
| `validateResultArtifact` | Complete native admission of an artifact, including references and approved terminology; disk-spooled indexes | No SQL. Admission visits the inventory before subsequent semantic reads; opening a provider alone is not full admission. Admission time and scratch storage can grow with saved output size. |
| `openArtifactResultProvider` | Verify and traverse pinned saved pages; bounded catalogue, row, concept-ID/name operations | No SQL. Trusted exact context and authorization callback required. R/JVM required by the current reader. |
| `openDatabaseResultProvider`, `readResultObject` | Same approved bytes and semantic operations | SELECT through approved PostgreSQL serving views, with grant checks. No CDM join or generation on a read. Driver/network latency is additional to local artifact cost. |
| `readPopulationObservationBaseline`, `readDomainBaseline`, `readMeasurementBaseline`, `listDomainConcepts` | Restricted saved-candidate validation/readback and bounded spool/paging | Read result-store tables, not a replacement for approved UI provider access. |
| `generateCountTracer`, `generateObservationTracer`, `generateMeasurementReport`, measurement run/recovery APIs | Earlier fixture/measurement tracer pipeline | Deliberately marked synthetic-schema/database restrictions. They are development paths, not the general external-source entry point. Keep their guards. |
| `viewResults` | Loopback HTTP server and development React viewer of contracts 1.0/1.1 | Source-free viewing, but currently the earlier count/observation/measurement bundle formats. It does not render the 142-output 2.x saved-provider model. |

## Buffer boundaries to verify

- `R/result-validation.R`: JDBC fetch size 128, string row visitor and singleton
  metadata queries. A row count is not a byte cap: driver buffers, a large row
  and decoded values also consume memory. A 142-entry dataset inventory is fixed
  profile metadata, distinct from the number of aggregate rows.
- `R/result-writer.R`: default queue 128 rows / 1 MiB of SQL, with configured
  upper bounds. These cover queued SQL, not total R/JVM memory.
- `R/result-export.R`: data pages up to 2,048 rows / 4 MiB, individual serialized
  rows up to 64 KiB, bounded index frontiers. Export and validation scratch are
  local disk costs and must be measured separately from database temporary tables.
- `R/saved-reader.R`: default raw cache 4 MiB, at most 8 MiB configurable; default
  operation budget 64 objects / 8 MiB / 8,192 physical rows. Decoded pages,
  dependency rows, responses, R objects and JVM memory are additional. Database
  transport disables the cross-operation raw cache to preserve live grant checks.
- `R/population-reader.R`: restricted readback uses a disk spool, default 64 MiB
  total cap; this is a development readback cap, not a source-size limit.
- `R/batch-workspace.R`: internal physical qualification helper `aggregate()`
  returns an entire queried relation as a data frame. Do not use it as a bounded
  production aggregate transport. Core generation uses the streamed store path.
- Old tracer/viewer paths accumulate bounded small bundles. Their fixed limits
  and fixture evidence do not establish the production client envelope.

Stage-byte and statement-time limits in generation constrain engine work, not
laptop RAM. Metadata/control statements and result rows are client traffic;
patient-level temporary tables remain engine-local. Efficient SQL and snapshot,
cancellation, failure and publication behavior remain package responsibilities.

## Known gaps

There is no public offline executable full-profile renderer or selectable dialect
adapter yet. The internal physical primitives are an incomplete subset, despite
being renderable offline. Execution currently builds SQL inside orchestration,
and client/driver/network/engine timings need clearer attribution. Streaming and
page bounds need growing-inventory validation/export measurements; fixed caps
alone are insufficient evidence. The full saved-result UI and browser-memory
evaluation are separate work from the earlier tracer viewer.

See the [client footprint runner](../benchmark/client-footprint.md) for an
exploratory, database-free baseline of the paths that can currently run offline.
