\name{inspectResultStore}
\alias{inspectResultStore}
\title{Read the restricted result store's version marker}
\usage{inspectResultStore(connectionDetails, resultsSchema)}
\arguments{
\item{connectionDetails}{PostgreSQL DatabaseConnector connection details.}
\item{resultsSchema}{Restricted results schema with a readable
achillesnext_storage_version table.}
}
\description{Uses an owned read-only transaction to inspect the bounded version
marker. Exactly one 2.0.0 marker is required; missing, denied, multiple or unsupported
markers fail without attempting a repair or migration. No CDM tables are queried.}
\details{A matching marker is only a compatibility precondition, not proof of store
structure, valid result contents, worker write privileges or supported upgrades.
Existing generation/publication APIs do not automatically call this diagnostic.
Approved-page reader roles do not require access to the marker.}
\value{Version-match diagnostics with result-data validation, write-privilege
verification and upgrade-performed flags all FALSE.}
\seealso{\code{initializeResultStore}, \code{planCharacterizationRefresh},
\code{validateResultRelease}}
