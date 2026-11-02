\name{generateMeasurementBaseline}
\alias{generateMeasurementBaseline}
\title{Precompute the measurement and nine-domain baseline in a restricted aggregate store}
\usage{
generateMeasurementBaseline(connectionDetails, cdmSchema, sourceId, resultsSchema,
  declaredCdmVersion, maxStageBytes = 64 * 1024^2, check = NULL,
  statementTimeoutMs = 30000L, numericStrategy = "weighted",
  maxAggregateRows = 1000000L)
}
\arguments{
\item{connectionDetails}{PostgreSQL worker credentials with SELECT-only source,
TEMPORARY and writes to an initialized restricted result store.}
\item{cdmSchema}{Source schema identifier.}
\item{sourceId}{Source identifier, at most 256 UTF-8 bytes.}
\item{resultsSchema}{Restricted result schema distinct from source.}
\item{declaredCdmVersion}{Declared CDM version: 5.3, 5.4 or 5.5. Actual columns
are probed; the declaration never substitutes for a capability probe.}
\item{maxStageBytes}{Total temporary relation/index bytes checked after stages.
This is not a hard allocation, sort-spill or database-memory limit.}
\item{check}{Optional cancellation function; signal an error to roll back.}
\item{statementTimeoutMs}{Positive integral PostgreSQL statement timeout in ms;
JDBC timeout is aligned above it.}
\item{numericStrategy}{Exact numeric/range summary operator: weighted or reference.
First-age summaries retain the shared exact domain operator in both modes.}
\item{maxAggregateRows}{Integer from 1 through 1000000; cap on all generated
aggregate rows. Failure, never truncation, when exceeded.}
}
\description{Generates population/observation dependencies and all nine recorded
clinical domains, adding the nineteen frozen measurement reports to the existing
119-output baseline. Reads the source only during explicit batch generation.
Every observed raw concept is included, with physical duplicate records retained.}
\details{Numeric summaries are stratified by known unit and separate NULL/zero
operators, with exact rational means and nearest-rank quantiles. The reference
operator sorts physical values; weighted uses cumulative frequencies. Range
boundaries and same-row reference status follow the frozen eligibility rules.
Unsupported required types, missing columns, resource limits or cancellation roll
back the entire candidate. No float casts or silent scope truncation. Stage byte
limits are checked after allocation; statement timeouts do not bound peak disk.
Four metadata outputs remain unimplemented, so the release is not publishable.}
\value{Restricted building release identity with 138 of 142 outputs accounted
for, including explicit schema-conditional unsupported states.}
\seealso{\code{readMeasurementBaseline}, \code{listDomainConcepts},
\code{generateDomainBaseline}, \code{generateMeasurementReport}}
