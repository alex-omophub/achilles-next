\name{publishResultRelease}
\alias{publishResultRelease}
\alias{validateResultRelease}
\alias{validateResultArtifact}
\title{Validate and publish saved aggregate results}
\usage{
validateResultRelease(connectionDetails, resultsSchema, releaseId)
validateResultArtifact(bundleDir)
publishResultRelease(connectionDetails, resultsSchema, releaseId,
  exportDir, accessScopeId, approvalId, policy, institutionalPolicy,
  expectedRevision = NULL)
}
\arguments{
\item{connectionDetails}{PostgreSQL DatabaseConnector connection details for a trusted validator/publisher.}
\item{resultsSchema}{Installed aggregate schema.}
\item{releaseId}{UUID of a sealed release using the installed core profile.}
\item{bundleDir}{Directory containing publication.json and content-addressed objects.}
\item{exportDir}{New approved artifact directory; its parent must exist.}
\item{accessScopeId}{Institution-controlled audience identifier.}
\item{approvalId}{Institution-controlled approval record identifier.}
\item{policy}{Closed list with id, revision, scope_kind (restricted or distributable), and allow_metrics as a list of registered IDs. Outputs with omitted denominators are also omitted.}
\item{institutionalPolicy}{Function receiving the candidate root descriptor, identities and policy; must return TRUE to approve those exact bytes. It receives no credentials.}
\item{expectedRevision}{Canonical integer string for compare-and-swap, or NULL to prepare without changing current.}
}
\description{Native validation of immutable aggregate releases and bounded content-addressed exports. Publication builds an explicit approved projection, validates all exported objects and writes identical database page bytes. It never queries the CDM.}
\value{Validation invisibly returns context or TRUE. Publication returns publication_id, root descriptor, revision (NULL when not promoted) and export_dir.}
\details{These development APIs do not generate the core domain analyses. The caller supplies an already populated complete dataset inventory and institutional approval. No synthetic policy is automatically applied. Failure rolls back database publication and preserves prior current. Directory validation verifies integrity and structure; institutional access control and the trusted pointer remain host responsibilities.}
