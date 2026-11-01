\name{generateDomainBaseline}
\alias{generateDomainBaseline}
\title{Precompute the eight-domain baseline in a restricted aggregate store}
\usage{
generateDomainBaseline(connectionDetails, cdmSchema, sourceId, resultsSchema,
  declaredCdmVersion, maxStageBytes = 64 * 1024^2, check = NULL,
  statementTimeoutMs = 30000L)
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
}
\description{Generates population/observation dependencies plus condition, drug,
procedure, visit, device, observation, death, specimen and domain density reports
in one repeatable-read transaction. Source access is read-only. Counts, exact
nonnegative scalar and numeric summaries, eligibility, source/type, integrity,
first-age, histograms, concept/ALL and calendar counts are precomputed and saved.
No chart-time CDM queries, source text or patient identifiers are exported.}
\details{Uses full recorded history. Summaries and histograms are whole-scope;
month/year capture is separately computed. Optional schema fields have explicit
unsupported states. A missing or inaccessible required source blocks generation.
Exact numeric/integer source columns are supported; floating-point adapters need
a separate precision contract and are rejected. All failures roll back the new
release. No source freshness/reuse, approval or current pointer is inferred.}
\value{Restricted building release identity with 119 of 142 frozen outputs
accounted for, including schema-conditional unsupported outputs. Measurement's
19 outputs and four metadata outputs remain not requested; the full-profile
publication gate remains closed.}
\seealso{\code{initializeResultStore}, \code{readDomainBaseline},
\code{listDomainConcepts}, \code{generatePopulationObservationBaseline}}
