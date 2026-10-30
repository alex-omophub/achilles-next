\name{generateMeasurementReport}
\alias{generateMeasurementReport}
\title{Generate a Synthetic Measurement Reference Report}
\usage{
generateMeasurementReport(connectionDetails, cdmSchema, sourceId, outputDir,
                          request, declaredCdmVersion, numericStrategy = "reference")
}
\arguments{
\item{connectionDetails}{PostgreSQL DatabaseConnector connection details for marked synthetic fixtures.}
\item{cdmSchema}{Marked tiny fixture schema.}
\item{sourceId}{Explicit source identifier matching the request.}
\item{outputDir}{New bundle folder under an existing parent.}
\item{request}{Bounded alpha-measurement-v1 request: 1--10 explicit concepts and an inclusive DATE window of at most 120 touched months.}
\item{numericStrategy}{Exact numeric strategy: \code{"reference"} (default) sorts physical values; \code{"weighted"} uses cumulative frequencies over distinct values. Choose explicitly; no automatic selection.}
\item{declaredCdmVersion}{Fixture CDM version: 5.3, 5.4 or 5.5.}
}
\description{Generates seven measurement metrics alongside the passport, all-source count and observation opportunity. Counts preserve physical duplicates and use observation membership once per row. Representations, raw units, raw operators and numeric exclusion reasons remain separate. Numeric summaries use exact NUMERIC text, weighted sums and discrete order statistics over physical values; means retain exact sum/n.}
\details{Only marked synthetic PostgreSQL sources are accepted. Generation uses its own read-only repeatable-read transaction. Known Unit-domain strata with raw operator NULL or 0 are summarized separately. Non-finite values, nonzero operators, missing/unmapped/invalid units and missing numeric values retain explicit exclusion counts. Local CONCEPT labels and declared CDM_SOURCE vocabulary metadata require no external service. Missing, denied or invalid measurement prerequisites produce explicit states without numeric payloads. The 15-output bundle remains partial: capability and execution reports are unsupported, disclosure is unapplied and no durable snapshot identity is asserted. The default reference sorts physical values. The optional weighted strategy accumulates grouped frequencies and selects the first value crossing each exact integer rank; metric semantics are identical. Strategy identity is recorded in the generator name. Both are development implementations, not a production engine.}
\value{Invisibly, the new bundle directory. Validate before opening with \code{viewResults(outputDir)}.}
\seealso{\code{generateObservationTracer}, \code{viewResults}}
