\name{executeCharacterizationRefresh}
\alias{executeCharacterizationRefresh}
\title{Execute a full refresh into a fresh restricted candidate}
\usage{
executeCharacterizationRefresh(connectionDetails, plan,
  maxStageBytes = 64 * 1024^2, check = NULL, statementTimeoutMs = 30000L,
  maxAggregateRows = 1000000L)
}
\arguments{
\item{connectionDetails}{PostgreSQL worker credentials with USAGE on source and
results schemas, SELECT-only source,
database TEMPORARY and restricted result-store producer grants.}
\item{plan}{A current unmodified request from \code{planCharacterizationRefresh}.}
\item{maxStageBytes}{Total temporary relation/index byte budget checked after stages;
not a hard allocation, memory or spill limit.}
\item{check}{Optional trusted cooperative cancellation function; signal to roll back.}
\item{statementTimeoutMs}{Positive integral PostgreSQL statement timeout in milliseconds.}
\item{maxAggregateRows}{Integer from 1 through 1000000, covering numeric and metadata rows.}
}
\description{Checks the complete request against current installed definitions,
verifies store version and worker table privileges, and recomputes all 142 frozen
outputs into a new restricted building candidate. Does not publish or alter current.}
\details{The checked plan, limits and request identity are persisted with the
successful candidate in the same repeatable-read transaction as all aggregates.
Changed or rehashed unsafe plans and stale implementation identities are rejected
before connection setup. Each execution creates fresh run, source-release and result
identities; matching request hashes never imply reusable inputs.
Precommit errors or cancellation roll back the candidate. Sealing, native validation,
institutional approval and compare-and-swap promotion remain separate explicit
operations. Later validation or approval failure leaves prior approved bytes/current
unchanged and may leave an unpublished candidate for diagnosis. A lost commit
acknowledgement can make candidate completion uncertain; a retry is a full rerun,
not checkpoint recovery. No failed-attempt ledger survives a rolled-back generation.
Readiness failures preserve class \code{AchillesRefreshReadinessFailure} and a
safe \code{reason_code} describing version availability/compatibility, missing
table privilege or a failed access check. Raw database diagnostics are excluded.
The serving schema is retained in the request but its view wiring/audience grants
are not verified by generation. Readiness is a version/privilege preflight, not a
complete structural, RLS, migration or production-scale certification.
The cancellation callback is trusted application code and should only inspect a
cancellation signal and return or signal; its own database side effects cannot be
undone by this API. No scheduler or chart-time refresh is installed.}
\value{A complete building candidate, with \code{publishable = FALSE} and a
\code{refresh} field recording plan hash, full recomputation, no reuse/checkpoints,
unchanged publication, unverified serving wiring and required explicit next steps.}
\seealso{\code{planCharacterizationRefresh}, \code{generateCharacterizationCandidate},
\code{sealResultRelease}, \code{validateResultRelease}, \code{publishResultRelease},
\code{promoteResultPublication}}
