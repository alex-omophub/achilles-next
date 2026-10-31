\name{resultStoreLifecycle}
\alias{sealResultRelease}
\alias{promoteResultPublication}
\title{Seal aggregate inventory and select an approved publication}
\usage{
sealResultRelease(connectionDetails, resultsSchema, releaseId)
promoteResultPublication(connectionDetails, resultsSchema, publicationId,
  expectedRevision = "0")
}
\arguments{
\item{connectionDetails}{PostgreSQL DatabaseConnector connection details.}
\item{resultsSchema}{Installed results schema.}
\item{releaseId}{UUID of a building release.}
\item{publicationId}{UUID of a ready publication.}
\item{expectedRevision}{Canonical integer string, at most 18 digits; zero for no current publication.}
}
\description{Seals a complete registered metric inventory or atomically selects a previously validated and approved publication.}
\value{The content or pointer revision as an exact character string.}
\details{Sealing is structural validation, not statistical or disclosure validation.
Promotion requires an existing matching validation receipt, ready approved root
and source/profile/scope context. It does not issue validation or approval.
A stale expected pointer revision fails without replacing current. Repeating
promotion of the already current publication returns its existing revision.
The complete validator and projection pipeline are still under development.}
