\name{planCharacterizationBatch}
\alias{planCharacterizationBatch}
\title{Plan set-based batches for the complete core characterization profile}
\usage{
planCharacterizationBatch(cdmSchema, sourceId, declaredCdmVersion,
  window = NULL, strategy = "reference")
}
\arguments{
\item{cdmSchema}{Source schema identifier.}
\item{sourceId}{Institution-controlled source identifier.}
\item{declaredCdmVersion}{Declared CDM version: 5.3, 5.4 or 5.5.}
\item{window}{Optional inclusive observed window with start/end DATE strings;
NULL means source-derived full history. All-recorded metrics retain all rows.}
\item{strategy}{Reference recomputation or shared intermediate evaluation.}
}
\description{Returns a deterministic module DAG, exact output grains and explicit
materialization choices for all 142 core results. Does not connect to the source,
execute domain reports or publish a release. Shared materialization is an explicit
evaluation candidate, not a measured speedup or automatic optimizer decision.}
\value{A list containing profile/definition identity, scope, ordered modules,
reuse rules and a plan SHA-256 identity.}
