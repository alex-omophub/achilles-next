\name{generateCharacterizationCandidate}
\alias{generateCharacterizationCandidate}
\title{Precompute all core characterization outputs in a restricted candidate}
\usage{
generateCharacterizationCandidate(connectionDetails, cdmSchema, sourceId,
  resultsSchema, declaredCdmVersion, maxStageBytes = 64 * 1024^2,
  check = NULL, statementTimeoutMs = 30000L, numericStrategy = "weighted",
  maxAggregateRows = 1000000L)
}
\arguments{
\item{connectionDetails}{PostgreSQL worker credentials with SELECT-only source,
TEMPORARY and writes to an initialized restricted result store, including SELECT
on its storage-version marker.}
\item{cdmSchema}{Source schema identifier.}
\item{sourceId}{Source identifier, at most 256 UTF-8 bytes.}
\item{resultsSchema}{Restricted result schema distinct from source.}
\item{declaredCdmVersion}{Declared CDM version: 5.3, 5.4 or 5.5. Actual columns are probed.}
\item{maxStageBytes}{Total temporary relation/index bytes checked after stages;
not a hard allocation or sort-spill limit.}
\item{check}{Optional cancellation function; signal an error to roll back.}
\item{statementTimeoutMs}{Positive integral PostgreSQL statement timeout in ms.}
\item{numericStrategy}{Exact measurement summary operator: weighted or reference.}
\item{maxAggregateRows}{Integer from 1 through 1000000; all numeric and metadata
rows count towards this limit. Exceeding it rolls back instead of truncating.}
}
\description{Generates all 142 frozen outputs, including the 138 numeric baseline
outputs and real source passport, capabilities, output-status and timing records,
in one repeatable-read transaction. Does not publish or change a current pointer.}
\details{Checks the existing storage-version marker before generation. Source and
vocabulary release identities remain unknown without verified immutable-release
evidence, even if descriptive metadata tables exist. Timing covers measured stages
and numeric generation through reconciliation, ending at metadata assembly; it
excludes writing the metadata itself and transaction commit. Validation, projection,
export and publication are not yet executed at this point. Physical-work telemetry
is NULL when not measured. Output integrity is recorded as pending at generation;
a separate validation receipt subsequently binds the sealed content. No circular
self-hash or premature validated claim is written into the output ledger.
The existing seal, native validation and institution-controlled approval APIs are
separate operations. This is a candidate generator, not a refresh-plan executor,
scheduler, reuse mechanism, migration tool or production-scale qualification.}
\value{A building release identity with all 142 outputs accounted for,
\code{profile_complete = TRUE} and \code{publishable = FALSE}.}
\seealso{\code{generateMeasurementBaseline}, \code{sealResultRelease},
\code{validateResultRelease}, \code{planCharacterizationRefresh}}
