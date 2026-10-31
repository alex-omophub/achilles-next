\name{readResultObject}
\alias{readResultObject}
\title{Read one pinned approved database object}
\usage{
readResultObject(connectionDetails, servingSchema, sourceId, publicationId,
  accessScopeId, rootSha256, descriptor = NULL)
}
\arguments{
\item{connectionDetails}{PostgreSQL serving-principal connection details.}
\item{servingSchema}{Schema containing approved_pages.}
\item{sourceId}{Expected source identity.}
\item{publicationId}{Pinned publication UUID.}
\item{accessScopeId}{Expected institution-controlled audience.}
\item{rootSha256}{Root hash anchored in a trusted pointer.}
\item{descriptor}{Expected child descriptor from a verified index, or NULL for root.}
}
\description{Reads exact immutable JSON bytes from approved_pages with bounded allocation, hash and context checks. No CDM, staging or aggregate-table query is made.}
\value{A raw vector containing the exact saved bytes.}
\details{The trusted host authorizes requests and supplies complete pinned context. An enabled audience grant and SELECT on the serving view are required; this function neither grants access nor follows current during reads.}
