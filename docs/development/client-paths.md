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
| `renderCharacterizationSql` | Compile a complete 142-output SQL program from declared columns, profile/CDM and exact operator; runtime metadata parameters remain explicit | No connection or JVM. Ordered PostgreSQL assertions/materializations and aggregate/metadata queries; requires a checked executor, real runtime facts and subsequent validation/approval. |
| `executeCharacterizationSql` | Reconstruct current compiled program, enforce assertions/bounded output callbacks, observe metadata and client/JDBC timings | One source-only PostgreSQL transaction, temporary stages, rollback/disconnect even on success. No result-store persistence or publication. |
| `generateCharacterizationCandidateFromSql` | Execute a checked program into bounded private capture, then replay canonical rows and disk-backed denominator targets into a complete building candidate | Separate source and store connections/transactions. Source cleanup completes before import; no distributed snapshot, automatic reuse, approval or publication. Commit acknowledgement loss retains diagnostic IDs and an unknown outcome. |
| `generateCharacterizationCandidate`, `executeCharacterizationRefresh` | Validate requests, issue SQL, track states and stream exact aggregate strings into the result store | Core generation in `R/population-baseline.R` uses one owned JDBC transaction, metadata preflight and engine-local temporary PERSON/event/interval/report stages. Patient rows in those stages stay in the engine. Candidate creation does not itself approve a publication. |
| `generatePopulationObservationBaseline`, `generateDomainBaseline`, `generateMeasurementBaseline`, `generateAnalysisProfile` | Generate reduced or registered-profile candidates; stream aggregate output | PostgreSQL source/results connection. Separate source/results schemas; not restricted to loopback or the tiny-fixture database. Core/reduced paths must not be confused with the old tracer. |
| `initializeResultStore`, `registerAnalysisProfile`, `sealResultRelease`, `validateResultRelease` | Install/verify store definitions, run exact native validation and reconciliation | PostgreSQL result-store operations; no local database requirement. Core installation uses the `achillesnext` table prefix. |
| `captureConceptSnapshot` | Stream reference terminology to a private file under `maxOutputBytes` (default 1 GiB) | Explicit vocabulary query; not patient data. Capture output grows up to its configured logical byte cap; later publication independently bounds its private input copy with `maxSnapshotBytes` (default 1 GiB). Projection limits approved saved labels. Capture does not assert consistency with a separate aggregate run. |
| `publishResultRelease`, `promoteResultPublication` | Validate/project approved rows, write immutable pages, verify them and promote complete output explicitly | Result-store/serving writes plus optional file export. `publishResultRelease` applies `maxScratchBytes` to each of its two sequential artifact admission passes; a separate `maxExportBytes` cap incrementally charges each serialized object and the pointer once, before its individual file is opened; earlier staged files may exist when a later file exceeds the remaining cap. The terminology INPUT snapshot copy is excluded. Approval remains required. Previously approved bytes are preserved; confirmed pre-COMMIT rollback and cleanup preserve prior current. Unknown or confirmed commits report explicit outcomes and may advance current when promotion was requested. Growing export/storage performance is not qualified by these caps. |
| `validateResultArtifact` | Complete native admission, including references and approved terminology; shared logical scratch-byte and file-count limits, disk-spooled indexes and cooperative cancellation | No SQL. `maxScratchBytes` defaults to 1 GiB, with a separate fixed 1,000,000-file cap. Opening a provider alone is not full admission. Admission time and required scratch still grow with saved output size. |
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
  rows up to 64 KiB, bounded index frontiers. `maxExportBytes` defaults to 1 GiB
  of logical serialized output, including the pointer. It is separate from
  validation scratch and excludes the terminology INPUT copy, database temporary
  tables, filesystem metadata and client memory.
- `R/result-artifact.R` / `R/validation-spool.R`: one shared validation budget
  covers both row/concept spools and reconciliation files, including simultaneous
  old/replacement indexes during rehash. Zero-byte page marks count toward a
  separate finite file cap. These bound logical file lengths/counts, not physical
  disk allocation or R/JVM memory; see [bounded validation](bounded-validation.md)
  for controls, cancellation, error handling and exclusions.
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

The [offline renderer](offline-renderer.md) now emits the full core SQL program;
the [checked executor](checked-executor.md) now executes that artifact through
bounded restricted-aggregate callbacks. Other dialects still require adapters.
Internal physical primitives remain an incomplete subset. Default candidate/refresh
execution still builds SQL inside orchestration, sharing pure builders with the
renderer. The optional [compiled-candidate bridge](compiled-candidate.md) provides
checked source capture and separate bounded persistence without replacing those
defaults. Streaming and page bounds need growing-inventory validation/export
measurements; fixed caps
alone are insufficient evidence. The full saved-result UI and browser-memory
evaluation are separate work from the earlier tracer viewer.

See the [client footprint runner](../benchmark/client-footprint.md) for an
exploratory, database-free baseline of the paths that can currently run offline.
