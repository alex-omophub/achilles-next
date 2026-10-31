\name{measurementRecovery}
\alias{cancelMeasurementRun}
\alias{resumeMeasurementRun}
\title{Cancel and Recover Synthetic Measurement Work}
\usage{
cancelMeasurementRun(runDir, connectionDetails = NULL)
resumeMeasurementRun(runDir, newRunDir, connectionDetails)
}
\arguments{
\item{runDir}{Existing trusted local run directory.}
\item{newRunDir}{New isolated recovery target under an existing parent, outside the prior run. Repeating the call with the same target is idempotent: it observes that attempt rather than creating another.}
\item{connectionDetails}{PostgreSQL DatabaseConnector connection details. Optional for cooperative cancellation; supplying the same execution role/database enables targeted query cancellation. Required to execute a new recovery attempt; never persisted.}
}
\description{Record an idempotent cancellation request, optionally signal the registered PostgreSQL backend, and recover requested work in a linked isolated attempt. All current source identities lack a durable immutability assertion, so every recovery attempt recomputes all operations. No earlier aggregate or partial output is reused.}
\details{Cancellation signals are guarded by marked synthetic database/role identity, backend PID, backend start time and a run-specific application name. A sent signal is not an executor acknowledgement. An independent R session or CLI can cancel a blocked query. The executor checks requests before/after operations and queries, records cancellation and remaining work, rolls back/disconnects its own session and removes only its own bundle staging. Completed operations retain factual timings; outputs cannot become successful published results after cancellation. Query interruption also attempts JDBC Statement.cancel during statement cleanup. Cancellation of connection establishment, lost network connections, permission-denied backend signals or a killed executor may remain unacknowledged; inspection reports that honestly.

The final terminal record is serialized with accepting cancellation requests. Already-terminal runs remain unchanged by late cancellation. Requests/receipts are separate local control records and are not exported. Source database cancellation is PostgreSQL-only; no process kill, backend termination or elevated role is used by the API.

Recovery creates a current-definition plan with a new run/bundle identity, immutable parent plan/revision hashes, an attempt number and an explicit recomputation decision. The destination directory is its idempotency key. Existing matching planned attempts execute once; running or terminal targets are only inspected. A lost execution claim observes the matching target, waiting up to five seconds if it is still transitioning from planned. Unrelated errors propagate and locks are never stolen. A different parent or changed installed definitions requires a new target. Concurrent creation may fail closed while a target is incomplete; retry the same command after creation finishes. Old writer locks are never stolen, and old records/staging remain intact after a hard kill. Recovery can run independently while an earlier attempt may still be alive; it never copies its inputs or results. Explicit approval/publication remains separate.

A source endpoint hash, observed schema/capability hashes, declared vocabulary metadata and aggregate terminology hash are diagnostic evidence, not immutable input identity. Unknown identity always invalidates reuse, including when these hashes match. Schema/vocabulary/source/metric-definition changes are therefore recomputed. No cache-hit path or institutional consistency assertion is implemented. Analytical payload hashes exclude run IDs, passport/timing metadata and request-envelope provenance; unchanged numerical inputs/definitions reproduce those hashes. Local locks/atomic renames do not establish power-loss or network-filesystem durability and do not authenticate hostile edits.}
\value{Cancellation returns requested/acknowledged flags, last persisted run state and explicit database-signal availability. Recovery invisibly returns the inspection list for the target attempt. Running state is last persisted state, not a liveness assertion. Failed/cancelled existing targets are not automatically retried in place; choose another new target for another attempt.}
\seealso{\code{planMeasurementRun}, \code{executeMeasurementRun}, \code{inspectMeasurementRun}, \code{publishMeasurementRun}}
