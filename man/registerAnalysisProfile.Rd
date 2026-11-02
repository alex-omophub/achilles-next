\name{registerAnalysisProfile}
\alias{registerAnalysisProfile}
\title{Register an installed analysis definition in an existing result store}
\usage{registerAnalysisProfile(connectionDetails, resultsSchema, profileId)}
\arguments{
\item{connectionDetails}{PostgreSQL store-owner DatabaseConnector details.}
\item{resultsSchema}{Existing initialized aggregate schema.}
\item{profileId}{ID of an installed registered profile.}
}
\value{Invisibly, the registered profile hash.}
\description{Adds the hash-bound installed definition to an existing profile registry. Registration is idempotent and does not alter existing releases, tables or publications. It requires INSERT privileges on the registry and does not load caller-supplied definitions.}
