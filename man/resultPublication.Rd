\name{publishResultRelease}
\alias{publishResultRelease}
\alias{validateResultRelease}
\alias{validateResultArtifact}
\title{Validate and publish saved aggregate results}
\usage{
validateResultRelease(connectionDetails, resultsSchema, releaseId)
validateResultArtifact(bundleDir, maxScratchBytes = 1024^3,
  cancel = function() FALSE)
publishResultRelease(connectionDetails, resultsSchema, releaseId,
  exportDir, accessScopeId, approvalId, policy, institutionalPolicy,
  expectedRevision = NULL, savedTerminology = NULL, cancel = function() FALSE,
  maxScratchBytes = 1024^3)
}
\arguments{
\item{connectionDetails}{PostgreSQL DatabaseConnector connection details for a trusted validator/publisher.}
\item{resultsSchema}{Installed aggregate schema.}
\item{releaseId}{UUID of a sealed release using an installed registered profile.}
\item{bundleDir}{Directory containing publication.json and content-addressed objects.}
\item{exportDir}{New approved artifact directory; its parent must exist.}
\item{accessScopeId}{Institution-controlled audience identifier.}
\item{approvalId}{Institution-controlled approval record identifier.}
\item{policy}{Closed list with id, revision, scope_kind (restricted or distributable), and allow_metrics as a list of registered IDs. Outputs with omitted denominators are also omitted.}
\item{institutionalPolicy}{Function receiving the candidate root descriptor, identities and policy; must return TRUE to approve those exact bytes. It receives no credentials.}
\item{expectedRevision}{Canonical integer string for compare-and-swap, or NULL to prepare without changing current.}
\item{savedTerminology}{Optional restricted snapshot list containing path, sha256 and optional exact rows, as returned by captureConceptSnapshot. Requires explicit enableSavedTerminology; opts into artifact format 2.1.0. NULL preserves format 2.0.0.}
\item{maxScratchBytes}{Finite nonnegative integer limit for total logical file bytes in each validation admission, default 1 GiB. Shared by row/concept indexes and values and reconciliation group files; simultaneous old and replacement indexes count during rehash. Validation also permits at most 1,000,000 scratch files, including zero-byte page marks. These configured limits do not reserve physical disk blocks, directory metadata or inodes. Export page staging and the terminology snapshot copy are outside this validation-only limit.}
\item{cancel}{Boolean cancellation predicate checked before validation, between publication SQL operations and streamed rows, during page emission, snapshot loading, admission and publication. Cancellation is cooperative and preserves the prior publication.}
}
\description{Native validation of immutable aggregate releases and bounded content-addressed exports. Publication builds an explicit approved projection, validates all exported objects and writes identical database page bytes. It never queries the CDM.}
\value{Validation invisibly returns context or TRUE. Publication returns publication_id, root descriptor, revision (NULL when not promoted) and export_dir.}
\details{These development APIs do not generate the core domain analyses. The caller supplies an already populated complete dataset inventory and institutional approval. No synthetic policy is automatically applied. Optional saved terminology is projected to retained non-suppressed IDs, with an approved prefix-search index. The approval candidate exposes contract_version and saved_terminology for this opt-in format. Snapshots must match source/release and hash; known vocabulary identities must agree with a saved passport when both are known. No source access occurs during publication. Failure rolls back database publication and preserves prior current. Scratch budget exhaustion raises an error of class \code{achillesnext_scratch_error} with \code{code} \code{byte_limit} or \code{file_limit}; scratch allocation/write/flush/close failures use \code{io_failure}, without exposing local paths. Artifact validation cancellation raises \code{achillesnext_read_error} with code \code{aborted}. Scratch cleanup runs on ordinary R error/cancellation unwinding; no cleanup on process termination is promised. Directory validation verifies integrity and structure; institutional access control and the trusted pointer remain host responsibilities.}
