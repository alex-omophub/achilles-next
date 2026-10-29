\name{generateObservationTracer}
\alias{generateObservationTracer}
\title{Generate Synthetic Observation Opportunity Results}
\usage{
generateObservationTracer(connectionDetails, cdmSchema, sourceId, outputDir,
                          request, declaredCdmVersion)
}
\arguments{
\item{connectionDetails}{PostgreSQL DatabaseConnector connection details for marked synthetic fixtures.}
\item{cdmSchema}{Marked tiny fixture schema.}
\item{sourceId}{Explicit source identifier matching the request.}
\item{outputDir}{New bundle folder under an existing parent.}
\item{request}{Bounded alpha-measurement-v1 request with inclusive DATE endpoints.}
\item{declaredCdmVersion}{Fixture CDM version: 5.3, 5.4 or 5.5.}
}
\description{Generates an all-source person count, passport and three observation metrics using a read-only repeatable-read transaction. Per-person overlapping and adjacent intervals are merged before clipping to the request window. Monthly people are deduplicated within each touched month; person-days are counted from interval lengths without daily expansion. Counts are exact strings.}
\details{The 15-output bundle remains partial, with ten outputs unsupported and no disclosure approval or reusable snapshot assertion. Missing, inaccessible or malformed observation prerequisites retain explicit states without numeric rows, while the valid all-source person count remains available. This function accepts only marked synthetic fixtures and is not a production analysis engine.}
\value{Invisibly, the generated bundle directory. Use \code{viewResults()} to inspect it after validation.}
