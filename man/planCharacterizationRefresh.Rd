\name{planCharacterizationRefresh}
\alias{planCharacterizationRefresh}
\title{Plan a complete characterization refresh without source access}
\usage{
planCharacterizationRefresh(cdmSchema, sourceId, resultsSchema, servingSchema,
  declaredCdmVersion, numericStrategy = "weighted")
}
\arguments{
\item{cdmSchema}{Source schema identifier.}
\item{sourceId}{Institution-controlled identifier, 1 to 256 UTF-8 bytes.}
\item{resultsSchema}{Restricted results schema, distinct from source/serving.}
\item{servingSchema}{Approved-page schema, distinct from source/results.}
\item{declaredCdmVersion}{Declared CDM version: 5.3, 5.4 or 5.5.}
\item{numericStrategy}{Exact measurement summary operator: weighted or reference.}
}
\description{Builds a deterministic planning-only request for all 142 frozen core
outputs, including the batch definitions and storage target. No database connection,
source query, candidate release, checkpoint, approval or publication is created.}
\details{Refresh requires full recomputation. Matching request hashes and unknown
or operator-declared release identities never imply reusable source data. The plan
retains the previous approved publication until complete validation and explicit
institutional approval permit promotion. The planner does not execute these steps.
Use \code{executeCharacterizationRefresh} for fresh complete candidate generation;
sealing, validation, approval and promotion remain explicit. Changed definitions
require a fresh plan. The older measurement-baseline entry point remains partial.}
\value{A request list with format, batch/profile/definition identities, target,
full-recompute/publication requirements, planning-only state and plan SHA-256.}
\seealso{\code{planCharacterizationBatch}, \code{inspectResultStore},
\code{executeCharacterizationRefresh}}
