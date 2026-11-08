\name{captureConceptSnapshot}
\alias{captureConceptSnapshot}
\alias{enableSavedTerminology}
\title{Prepare approved saved terminology for concept lookup and prefix search}
\usage{
captureConceptSnapshot(connectionDetails, vocabularySchema, outputFile,
  sourceId, releaseId, labelSource, vocabularyRelease,
  cancel = function() FALSE, queryTimeoutSeconds = 900L)
enableSavedTerminology(connectionDetails, resultsSchema)
}
\arguments{
\item{connectionDetails}{Explicit PostgreSQL vocabulary-read credentials for capture, or store-owner credentials for enabling the extension. Never passed to the consumer provider.}
\item{vocabularySchema}{Local vocabulary schema with concept_id, concept_name, domain_id and vocabulary_id in concept.}
\item{outputFile}{New restricted canonical JSONL snapshot path; parent directory must exist.}
\item{sourceId}{Expected dataset source identity, later checked against the aggregate release.}
\item{releaseId}{Exact aggregate release UUID to which the snapshot is bound.}
\item{labelSource, vocabularyRelease}{Explicit identity lists: state, value, basis, assertion_id and reason_code. Known requires value/basis/assertion_id and NULL reason; unknown requires NULL values/basis/assertion_id and an explicit reason. Known identities are operator assertions, not inferred evidence.}
\item{cancel}{Boolean cancellation predicate, checked throughout capture. Cooperative under synchronous JDBC.}
\item{queryTimeoutSeconds}{Positive JDBC statement timeout for the batch vocabulary capture; default 900 seconds.}
\item{resultsSchema}{Existing initialized base 2.0.0 aggregate store, owned by the caller.}
}
\description{Captures local reference terminology once during explicit batch work, then allows opt-in physical 2.1.0 publication using the saved snapshot. Providers read only approved saved pages.}
\value{Capture invisibly returns path, SHA-256 and exact row count. Enablement returns TRUE when installed or FALSE when already enabled with the expected definition.}
\details{
Capture reads only the local concept table in one read-only repeatable-read transaction.
It preserves exact IDs/display names and streams bounded rows to a private new file.
Duplicate IDs, malformed metadata, labels over 1,024 UTF-8 bytes, control characters
or failed/cancelled capture fail without a finalized output. NULL/ASCII-space-only
names become explicit unavailable labels. No patient/event text is read.
The capture is separate from aggregate generation: consistency with the aggregate
release is explicitly not_asserted. Source/release IDs bind the input but do not
prove a simultaneous snapshot. Operators supply honest vocabulary/source evidence.

Enablement is explicit, transactional and owner-only through PostgreSQL privileges.
It locks before reading store state and uses read-committed isolation for concurrent
first-call idempotence. It verifies the installed base version, exact publication
guard body and its enabled unconditional row-level BEFORE INSERT/UPDATE trigger
binding. It holds a publication-table lock against trigger DDL and reapplies the
guard's existing COST with owner-permitted ALTER FUNCTION before reading its body.
The resulting catalog tuple write lock protects body validation/replacement and
the already-enabled check until commit, without requiring catalog UPDATE grants.
Committed customizations are refused and concurrent catalog conflicts abort
without repair. Enablement adds extension marker saved-terminology/1.0.0 and
support for roots 2.0.0/2.1.0.
A modified guard or incompatible marker is refused; no automatic repair occurs.
Existing pages, releases, current pointers and the base storage version are unchanged.
No source access occurs during enablement. It is not an in-place artifact migration.

Pass the captured list as savedTerminology to publishResultRelease. Names and the
search index are projected only for retained non-suppressed IDs and receive normal
native admission, institutional approval and atomic publication. Old snapshots are
not silently rebound to new releases. See the package saved-concepts guide.
}
