\name{planAnalysisProfile}
\alias{planAnalysisProfile}
\title{Plan an installed registered analysis profile}
\usage{planAnalysisProfile(profileId, cdmSchema, sourceId, declaredCdmVersion)}
\arguments{
\item{profileId}{ID of a separately installed profile.}
\item{cdmSchema}{Source schema identifier.}
\item{sourceId}{Institution-controlled source identifier, 1 to 256 UTF-8 bytes.}
\item{declaredCdmVersion}{Declared CDM version: 5.3, 5.4 or 5.5.}
}
\value{A deterministic source-free plan binding metric dependencies and installed definition identities.}
\description{Plans an installed registered profile. Unknown profiles fail explicitly; no caller-supplied code or schemas are loaded. The core characterization profile uses its own planner.}
