\name{generatePopulationObservationBaseline}
\alias{generatePopulationObservationBaseline}
\title{Generate and persist population and observation baseline aggregates}
\usage{
generatePopulationObservationBaseline(connectionDetails, cdmSchema, sourceId,
  resultsSchema, declaredCdmVersion, window = NULL,
  maxStageBytes = 64 * 1024^2, check = NULL, statementTimeoutMs = 30000L)
}
\arguments{
\item{connectionDetails}{PostgreSQL worker credentials with SELECT-only CDM,
TEMPORARY and write privileges on the initialized restricted result store.}
\item{cdmSchema}{Source schema identifier.}
\item{sourceId}{Source identifier, at most 256 UTF-8 bytes.}
\item{resultsSchema}{Existing restricted results schema, distinct from source.}
\item{declaredCdmVersion}{Declared CDM version: 5.3, 5.4 or 5.5.}
\item{window}{Optional inclusive observed date window; NULL derives full history.}
\item{maxStageBytes}{Total temporary relation/index bytes checked after each stage;
this is not a hard peak-allocation or spill limit.}
\item{check}{Optional cooperative cancellation callback; signal to roll back.}
\item{statementTimeoutMs}{Positive integer per-statement timeout in milliseconds,
at most 2147483647. JDBC timeout is aligned above the PostgreSQL limit.}
}
\description{Computes seven PERSON and twelve observation-period results in a
single writable repeatable-read worker transaction. Source remains SELECT-only;
temporary staging is transaction-private. Exact counts and summaries are persisted
in the typed store; any failure rolls back all new results. Other core metrics
remain explicitly not generated. No publication, approval or current pointer changes.}
\value{Identity of a building core release with 19 generated of 142 required
metrics. It is not a complete or publishable full-profile release.}
\seealso{\code{initializeResultStore}, \code{readPopulationObservationBaseline}}
