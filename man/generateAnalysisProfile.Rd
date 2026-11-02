\name{generateAnalysisProfile}
\alias{generateAnalysisProfile}
\title{Generate exact aggregates for an installed registered analysis profile}
\usage{generateAnalysisProfile(connectionDetails, cdmSchema, sourceId,
  resultsSchema, declaredCdmVersion, profileId, maxRows = 10000L,
  queryTimeoutSeconds = 60L)}
\arguments{
\item{connectionDetails}{PostgreSQL DatabaseConnector connection details.}
\item{cdmSchema}{Source schema identifier.}
\item{sourceId}{Institution-controlled source identifier, 1 to 256 UTF-8 bytes.}
\item{resultsSchema}{Initialized writable aggregate schema, separate from source.}
\item{declaredCdmVersion}{Declared CDM version: 5.3, 5.4 or 5.5.}
\item{profileId}{ID of a separately installed profile.}
\item{maxRows}{Maximum aggregate rows, from 1 to 1000000; patient rows are not fetched.}
\item{queryTimeoutSeconds}{Per-statement timeout, including source aggregation.}
}
\value{A complete building release. Seal, validate and explicitly approve it separately before serving.}
\description{Runs registered SQL in a repeatable-read PostgreSQL transaction and persists typed exact aggregates. The initial contribution seam supports PERSON counts and partitions. Unknown profiles and unsupported source types fail explicitly. No chart action invokes generation.}
