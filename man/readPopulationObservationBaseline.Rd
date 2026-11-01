\name{readPopulationObservationBaseline}
\alias{readPopulationObservationBaseline}
\title{Stream saved restricted population and observation aggregates}
\usage{
readPopulationObservationBaseline(connectionDetails, resultsSchema, releaseId, visit)
}
\arguments{
\item{connectionDetails}{PostgreSQL credentials with SELECT on restricted results;
no CDM permission is needed.}
\item{resultsSchema}{Restricted results schema.}
\item{releaseId}{UUID returned by the population/observation generator.}
\item{visit}{Function called with metric ID and each exact saved row.}
}
\description{Checks the generated baseline inventory and numerical rows, then
streams saved aggregates in one read-only repeatable-read snapshot. It queries no
CDM tables. Building data are restricted and are not an approved UI publication.
The complete 142-result validation/publication gate remains unchanged.}
\value{Source/profile, complete/incomplete inventory, requested/effective scope
and generation metadata. The full profile remains explicitly incomplete.}
