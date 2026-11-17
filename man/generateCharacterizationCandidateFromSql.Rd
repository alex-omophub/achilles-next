\name{generateCharacterizationCandidateFromSql}
\alias{generateCharacterizationCandidateFromSql}
\title{Import checked source aggregates through a separate result-store connection}
\usage{
generateCharacterizationCandidateFromSql(sourceConnectionDetails, program,
  storeConnectionDetails, resultsSchema, maxScratchBytes = 1024^3,
  scratchParent = tempdir(), maxStageBytes = 64 * 1024^2,
  maxAggregateRows = 1000000L, maxAggregateBytes = 256 * 1024^2,
  maxRowBytes = 131072L, fetchSize = 128L,
  statementTimeoutMs = 30000L, maxElapsedSeconds = 3600, check = NULL)
}
\arguments{
\item{sourceConnectionDetails}{PostgreSQL DatabaseConnector credentials with
SELECT-only source access and TEMPORARY permission. Result-store access is unnecessary.}
\item{program}{Current, unmodified output of \code{renderCharacterizationSql()}.
The complete compiler artifact is reconstructed before connecting.}
\item{storeConnectionDetails}{Separate PostgreSQL DatabaseConnector credentials
for an initialized restricted aggregate store with the producer privileges checked
by the refresh-readiness checks. Source access is unnecessary.}
\item{resultsSchema}{Initialized aggregate schema, distinct from the source schema
name. No installation, migration or serving-schema modification is performed.}
\item{maxScratchBytes}{Nonnegative integer logical file-byte budget, at most
\code{2^53-1}, shared by capture rows, duplicate/denominator index, simultaneous
rehash indexes and control files. Directories, filesystem metadata and physical
block allocation are not reserved.}
\item{scratchParent}{Existing local directory for a new private attempt directory.
The function removes only its own directory. No saved-capture resume is supported.}
\item{maxStageBytes,maxAggregateRows,maxAggregateBytes,maxRowBytes,fetchSize}{Source
execution limits passed to \code{executeCharacterizationSql()}. Canonical captured
rows additionally have a fixed 65536-byte cap.}
\item{statementTimeoutMs}{Positive integer per-statement PostgreSQL timeout used
for source execution, store preflight and persistence. JDBC uses whole seconds.}
\item{maxElapsedSeconds}{Cooperative whole-call elapsed deadline. Checked between
queries, rows and local I/O. It is not a hard network or filesystem deadline.}
\item{check}{Optional cooperative check. FALSE, an error or an interrupt cancels.}
}
\description{Runs a checked complete source characterization into bounded,
unpublished local capture files. After confirmed source cleanup, replays canonical
rows in dependency order through a separate result-store transaction. Returns a
complete building candidate; existing generation and refresh APIs remain unchanged.}
\details{
A read-only store preflight checks storage version, producer privileges and the
installed profile before source execution. The final transaction repeats those
checks. The source receipt supplies actual schema/capability observations,
generation timestamps, timings and independent physical input audit totals.
Captured rows keep exact numeric strings and explicit unavailable states.
Source metadata retains its source-capture timing; persistence is a separate
transaction, not a distributed source/store snapshot. Unknown source/vocabulary
release identities remain unknown and nonreusable.

The client retains a fixed 142-entry inventory and processes one bounded row at a
time. A disk index rejects duplicate canonical keys and resolves denominator
targets without per-row source or store queries. One capture writer, one replay
reader and the index handles are used; no handle or vocabulary cache grows with
row count. Captured record frames and rolling hashes detect truncated, modified
or extra data. Each control file is capped at four MiB, with at most 512 accounted
files; normal captures use a fixed number of per-metric files. Scratch failures,
including rehash overlap, fail closed. These logical limits do not bound total
R/JVM RSS, arbitrary operating-system buffers or external SQL-engine memory.

Replay follows registered analysis dependencies, flushes the existing bounded
writer after each metric, validates typed rows/denominators and checks exact
population/domain conservation against independent source audits. It never
retrieves clinical source rows or performs interactive source reads for viewing.
The attempt's scratch is closed and removed before attempting candidate COMMIT.
No seal, validation receipt, approval, export or publication promotion is created.

Public failures have class \code{AchillesCandidateFailure} with fixed
\code{reason_code}; diagnostics omit SQL, connection credentials, callback text
and local scratch paths. Once allocated, \code{attempt_id}, \code{run_id},
\code{source_release_id} and \code{release_id} identify the attempt.
A failed COMMIT acknowledgement reports \code{candidate.commit_unknown} and
\code{outcome="unknown"}: the server may already have committed the unpublished
candidate. A confirmed commit followed by cleanup failure reports
\code{outcome="committed"}. Earlier failures report \code{outcome="not_committed"},
which does not guarantee rollback confirmation during a network failure. Cleanup
attempts rollback/disconnect and retries unconfirmed actions; no uncertain cleanup
returns success. Inspect the restricted store using the returned IDs before any
manual recovery. There is no automatic retry, reuse or publication change.

Source execution retains its PostgreSQL-only, concurrent-DDL and cooperative
cancellation limitations. Client process CPU and JDBC round-trip wall times are
separate from external engine CPU/memory/query IDs, which remain unavailable.
Large-source and external-engine performance qualification are separate.
}
\value{A complete building candidate with fresh IDs, profile identity,
\code{profile_complete=TRUE}, \code{publishable=FALSE} and
\code{publication_changed=FALSE}. Includes the bounded \code{source_receipt},
writer \code{persistence} statistics, peak logical \code{scratch} accounting and
separate client/source/store telemetry. No aggregate row collection is retained.}
\seealso{\code{renderCharacterizationSql}, \code{executeCharacterizationSql},
\code{generateCharacterizationCandidate}, \code{sealResultRelease}}
