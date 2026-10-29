\name{generateCountTracer}
\alias{generateCountTracer}
\title{Generate a Synthetic PostgreSQL Count Tracer}
\usage{
generateCountTracer(connectionDetails, cdmSchema, sourceId, outputDir,
                    request, declaredCdmVersion)
}
\arguments{
\item{connectionDetails}{PostgreSQL connection details from DatabaseConnector. Keep credentials outside results and source control.}
\item{cdmSchema}{A marked tiny fixture schema, for example \code{cdm_tiny_a_55}.}
\item{sourceId}{Explicit source identity, also present in the request.}
\item{outputDir}{New directory under an existing parent. Existing paths are refused.}
\item{request}{A named list matching the fixed alpha request. Concept IDs must be an unnamed list of integers. Only the synthetic disclosure policy is accepted.}
\item{declaredCdmVersion}{Declared fixture version: \code{5.3}, \code{5.4}, or \code{5.5}.}
}
\description{Reads PERSON using DatabaseConnector in a read-only repeatable-read transaction, requires unique non-null person IDs, and preserves the exact count as text. Only the marked synthetic fixture database and tiny schemas are allowed.}
\value{Invisibly, the output directory. Files use contract 1.0.0 and the frozen alpha profile. The passport and person count are computed; all other partitions are explicitly unsupported.}
\details{This development tracer never publishes a complete alpha bundle, applies a disclosure policy, or establishes a reusable source snapshot. Validate the generated files with the repository contract command. It does not include a production runner, recovery, viewer opener or institutional service.}
