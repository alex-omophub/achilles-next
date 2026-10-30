\name{measurementRuns}
\alias{planMeasurementRun}
\alias{executeMeasurementRun}
\alias{inspectMeasurementRun}
\title{Persist and Inspect Synthetic Measurement Execution}
\usage{
planMeasurementRun(runDir, cdmSchema, sourceId, request, declaredCdmVersion,
                   numericStrategy = "reference", maxConcurrency = 1L)
executeMeasurementRun(runDir, connectionDetails)
inspectMeasurementRun(runDir)
}
\arguments{
\item{runDir}{New local run directory under an existing parent when planning; existing trusted run directory when executing or inspecting.}
\item{cdmSchema}{Marked tiny synthetic PostgreSQL fixture schema.}
\item{sourceId}{Explicit source identifier matching the request.}
\item{request}{Bounded alpha-measurement-v1 request, as for \code{generateMeasurementReport}. All fifteen profile outputs are recorded as requested.}
\item{declaredCdmVersion}{Fixture version: 5.3, 5.4 or 5.5.}
\item{numericStrategy}{Exact numeric strategy: reference or weighted.}
\item{maxConcurrency}{Only 1 is supported. Limit is per run, not global across processes.}
\item{connectionDetails}{PostgreSQL DatabaseConnector connection details, supplied only for execution and never persisted.}
}
\description{Planning persists a fixed dependency graph and requested-output set without connecting. Execution runs a new plan once with a single writer, preserving operation transitions, attempts, timings, query hashes and explicit unavailable query identifiers. Inspection reopens the committed history without connecting or resuming.}
\details{Only marked synthetic fixtures are accepted. The plan records physical operation dependencies separately from the profile's logical metric dependencies. Compatible observation aggregates feed multiple denominators; SQL CTEs materialize shared intervals, classified measurements and frequencies within their statements, without exporting row-level data. Operation failures and dependency skips are distinct from analytical empty/zero states. The staging bundle remains partial and unvalidated. A run with any unsupported or failed requested output is failed with an incomplete-request cause, even if all implemented computations succeeded. The three capability/execution result partitions remain unsupported; this local ledger does not replace those wire contracts. No complete publication or reuse is authorized. Same-directory rename commits each local revision; a hard kill leaves its last persisted state and lock, without asserting process liveness. Automatic stale-lock takeover, retry/resume, database cancellation and power-loss durability are not provided. Read only trusted local run directories; hashes detect discontinuity but do not authenticate hostile edits.}
\value{Planning invisibly returns the new directory. Execution invisibly returns the inspection list, including plan, state and history. Inspection returns that list visibly. Execution failures are recorded in the returned state; persistence/preflight errors may raise an R error.}
\seealso{\code{generateMeasurementReport}, \code{viewResults}}
