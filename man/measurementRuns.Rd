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
\details{Only marked synthetic fixtures are accepted. The plan records physical operation dependencies separately from the profile's logical metric dependencies. Compatible observation aggregates feed multiple denominators; SQL CTEs share intervals, classified measurements and frequencies within their statements, leaving the reference strategy's single-consumer frequency CTE foldable, without exporting row-level data. Operation failures and dependency skips are distinct from analytical empty/zero states. The executor now produces all fifteen typed partitions using contract 1.1, including capability probes and execution status/timing. Staging is validated before recording successful requested outputs, but remains partial until a separate explicit \code{publishMeasurementRun} call. Unsupported or failed requested outputs fail the run. Unmeasured telemetry phases remain NULL with a reason; shared compute durations must not be summed as independent work. No input reuse is authorized. Same-directory rename commits each local revision; a hard kill leaves its last persisted state and lock, without asserting process liveness. Use \code{cancelMeasurementRun} to request cooperative/targeted PostgreSQL cancellation and \code{resumeMeasurementRun} to recover into an isolated recomputed attempt. Stale-lock takeover, in-place resumption, input reuse and power-loss durability are not provided. Read only trusted local run directories; hashes detect discontinuity but do not authenticate hostile edits.}
\value{Planning invisibly returns the new directory. Execution invisibly returns the inspection list, including plan, state and history. Inspection returns that list visibly. Execution failures are recorded in the returned state; persistence/preflight errors may raise an R error.}
\seealso{\code{generateMeasurementReport}, \code{publishMeasurementRun}, \code{viewResults}}
