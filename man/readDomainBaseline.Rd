\name{readDomainBaseline}
\alias{readDomainBaseline}
\title{Stream exact saved domain baseline rows without source access}
\usage{
readDomainBaseline(connectionDetails, resultsSchema, releaseId, visit,
  metricIds = NULL, conceptTag = NULL, period = NULL)
}
\arguments{
\item{connectionDetails}{PostgreSQL credentials with SELECT on restricted results.}
\item{resultsSchema}{Restricted result schema.}
\item{releaseId}{UUID returned by \code{generateDomainBaseline}.}
\item{visit}{Function called with a metric identifier and each saved exact row.}
\item{metricIds}{Optional nonempty character subset of generated metric IDs.}
\item{conceptTag}{Optional typed concept selector, e.g. \code{list(kind="all")},
\code{list(kind="null")} or \code{list(kind="id", value="123")}.}
\item{period}{Optional exact saved selector with string fields period_kind,
period_start and period_end. Full-history boundaries use the literal "null".
Calendar periods use inclusive ISO dates; arbitrary ranges require generation.
Every explicitly selected metric must support the requested period.}
}
\description{Validates all 119 saved dataset inventories and rows before streaming
selected rows, in one read-only saved-results snapshot. Selecting a concept or
period never queries CDM tables or computes new statistics. Whole-scope summaries
cannot be converted into monthly summaries. A period not precomputed raises an
explicit generation-required error before any visitor output. Named metric vectors
return the same array-shaped selection metadata as unnamed vectors.}
\value{Source/profile/inventory/scope and selection metadata, with
\code{profile_complete=FALSE} and \code{publishable=FALSE}. This restricted
building-release reader is not an approved publication or UI provider.}
\seealso{\code{generateDomainBaseline}, \code{listDomainConcepts}}
