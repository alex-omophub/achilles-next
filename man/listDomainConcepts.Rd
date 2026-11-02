\name{listDomainConcepts}
\alias{listDomainConcepts}
\title{Page saved raw concept identities from a domain baseline}
\usage{
listDomainConcepts(connectionDetails, resultsSchema, releaseId, domain,
  pageSize = 64L, cursor = NULL)
}
\arguments{
\item{connectionDetails}{PostgreSQL credentials with SELECT on restricted results.}
\item{resultsSchema}{Restricted result schema.}
\item{releaseId}{UUID of a saved building domain baseline release.}
\item{domain}{One of condition, drug, procedure, visit, device, observation,
death, specimen or measurement.}
\item{pageSize}{Integer from 1 to 128.}
\item{cursor}{NULL for the first page or the returned next_cursor. Bound to the
release, content revision, profile and domain.}
}
\description{Reads a bounded ordered page from full-scope saved capture rows.
Raw NULL, zero, unknown and known concepts retain identity. ALL is a separate
selector and is omitted from the catalogue. Empty domains have empty catalogues.
No CDM lookup, live labels, patient or source strings are returned.}
\value{List with release_id, domain, concepts and next_cursor (NULL at the end).
The cursor is a pagination position, not an authorization token. Restricted
result-store access is required.}
\seealso{\code{generateDomainBaseline}, \code{readDomainBaseline}}
