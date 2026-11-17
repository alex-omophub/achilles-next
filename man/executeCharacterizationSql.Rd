\name{executeCharacterizationSql}
\alias{executeCharacterizationSql}
\title{Execute a checked core SQL program with bounded aggregate callbacks}
\usage{
executeCharacterizationSql(connectionDetails, program, visit,
  maxStageBytes = 64 * 1024^2, maxAggregateRows = 1000000L,
  maxAggregateBytes = 256 * 1024^2, maxRowBytes = 131072L,
  fetchSize = 128L, statementTimeoutMs = 30000L,
  maxElapsedSeconds = 3600, check = NULL)
}
\arguments{
\item{connectionDetails}{PostgreSQL DatabaseConnector connection details for a
worker with SELECT-only source access and TEMPORARY permission. No result-store
write permission is needed.}
\item{program}{Current unmodified output of \code{renderCharacterizationSql()}.
Its declared inputs are recompiled with the installed implementation and the
complete artifact must match before any connection is opened. A supplied digest
alone does not authorize SQL execution.}
\item{visit}{Function \code{function(metricId, row)} that consumes each decoded
restricted aggregate intermediate. Rows have \code{metric_id}, \code{row_kind},
\code{dimensions}, \code{values}, \code{state} and \code{reason_code} fields.
Stage all callback output privately until this function returns successfully.}
\item{maxStageBytes}{Nonnegative integer budget for this execution's temporary
table and index bytes, at most \code{2^53}. Checked after CREATE, INDEX and DROP.}
\item{maxAggregateRows}{Total output row budget, including metadata; integer
from zero to one million.}
\item{maxAggregateBytes}{Nonnegative integer budget, at most \code{2^53}, for
UTF-8 output JSON payload bytes before exact numeric-string normalization.
SQL text, bound parameters and JDBC protocol/control overhead are separate.}
\item{maxRowBytes}{UTF-8 text payload bytes per fetched row, integer from one
to one MiB. Applies to control/catalog rows as well as output rows.}
\item{fetchSize}{JDBC cursor fetch rows, integer from one to 1024.}
\item{statementTimeoutMs}{PostgreSQL per-statement timeout, positive integer
milliseconds up to \code{2147483647}. JDBC query timeout additionally bounds a
statement using whole seconds and the remaining cooperative deadline.}
\item{maxElapsedSeconds}{Cooperative whole-call wall deadline, from 0.001 to
604800 seconds. Checked between JDBC calls and rows; not a hard network deadline.}
\item{check}{Optional cancellation function. An error, interrupt or explicit
\code{FALSE} result cancels execution; other results continue.}
}
\description{Executes all ordered assertions/materializations and all 142 frozen
core output queries in one owned PostgreSQL repeatable-read transaction, streaming
only restricted aggregates and metadata to a bounded callback. Actual schema,
capability, timestamp and timing observations are captured in the same snapshot
and bound through prepared JSONB parameters.}
\details{
The source role must have SELECT-only privileges; the owned transaction is writable
only because it creates backend-private temporary stages. Before returning a
success receipt, it confirms rollback and disconnection. On error it attempts both
cleanup operations and retries unconfirmed cleanup while unwinding. Driver or
network failures can prevent cleanup confirmation; failed cleanup produces no
success receipt. The executor does not read or modify a result-store
publication, write a candidate, create canonical row keys or denominator edges,
validate a complete wire artifact, approve output or promote a publication.

Callbacks receive staging intermediates, with exact numeric strings normalized
without floating-point conversion. Callback code can retain rows or perform
external writes; that memory and those side effects are under the caller's control.
Source rollback cannot undo callback writes. An exception or cancellation means
no success receipt; partial callback output must remain unpublished and be discarded
or diagnosed by its owner. Saved-result viewing continues to use approved
precomputed results and does not invoke this source executor.

SQL checks payload length and cumulative query payload bytes before JDBC receives
JSON text. Cursor fetches are bounded and SQL limits use at most the remaining row
budget plus one. Overflow rows carry only a bounded status sentinel with a NULL
payload. Aggregate and metadata/catalog transfer have separate fixed budgets;
metadata catalog reads are capped at 4096 rows per operation, 8192 control/catalog
rows in total, 16 MiB of such payloads and 1024 statement telemetry records.
These bounds cover executor-owned state, not callback accumulation or total R/JVM
RSS. Temporary relation/index bytes are sampled after allocation, not enforced as
a hard reservation; server sort/spill files and engine process memory are not
attributed by that sample.

Cancellation checks occur between JDBC calls and rows; PostgreSQL/JDBC timeouts
bound statement execution, and an unsuccessful owned statement is cancelled before
closing. The API does not promise immediate interruption of an arbitrary blocked
network call or provide a cross-process cancellation endpoint. Failed transport,
checks, callbacks or cleanup never produce a success receipt. Public errors have
class \code{AchillesSqlExecutionFailure} and a fixed \code{reason_code}; SQL,
connection credentials and callback error text are not exposed.

Repeatable-read and declared-schema assertions do not establish a durable or
reusable source identity or a schema-DDL freeze. Concurrent source DDL is not
supported by this first adapter; no stronger source lock or broader source grant
is requested. PostgreSQL is the only implemented dialect. Large-source and
external-engine performance qualification are separate from these bounds.

Telemetry separates process CPU, validation/output decode/callback wall time and
client-observed JDBC execute/fetch round-trip wall time. Round-trip durations
include driver and network waits and are not engine CPU. PostgreSQL engine CPU,
process memory and warehouse query ID remain NULL with an explicit unavailable
reason. Runtime metadata timings are captured before metadata delivery; they are
actual pipeline observations, not isolated engine execution time.
}
\value{A \code{characterization_execution_receipt} with state succeeded,
program/profile/source identities, actual observed schema and capabilities,
generation timestamps, complete inventory, the \code{runtime_facts} bound to
metadata SQL, canonical output row/byte counts, per-metric counts and bounded
telemetry. Its cleanup records rollback/disconnect; \code{canonical_wire} and
\code{publication_changed} are FALSE. No aggregate row collection is retained.}
\seealso{\code{renderCharacterizationSql}, \code{generateCharacterizationCandidate}}
