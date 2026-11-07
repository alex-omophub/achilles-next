\name{openResultProvider}
\alias{openArtifactResultProvider}
\alias{openDatabaseResultProvider}
\title{Open semantic access to approved saved results}
\usage{
openArtifactResultProvider(bundleDir, context, authorize, readBudget = list())
openDatabaseResultProvider(connectionDetails, servingSchema, context,
  authorize, readBudget = list())
}
\arguments{
\item{bundleDir}{Institution-managed immutable directory containing approved v2 objects.}
\item{connectionDetails}{PostgreSQL serving-principal connection details, separate from source credentials.}
\item{servingSchema}{Schema exposing the approved serving views.}
\item{context}{Trusted pinned list containing contract_version, publication_id, release_id, source_id, profile_id, profile_revision, profile_sha256, access_scope_id, the exact root descriptor, authorization_epoch and instance_id.}
\item{authorize}{Trusted function of context returning exactly TRUE only while the complete release/root/scope is admitted, approved and accessible to this instance and epoch.}
\item{readBudget}{Optional named overrides for cacheBytes, maxObjects, maxBytes and maxRows of the internal reader. Defaults are 4 MiB raw cache, 64 distinct objects, 8 MiB distinct verified bytes and 8,192 distinct verified leaf rows per operation. Database caching is disabled.}
}
\description{Provides metric discovery and exact equality selection of typed precomputed rows through the same native interface for artifact and database modes. Does not query CDM tables, aggregate results again, or schedule jobs.}
\value{A provider list with listMetrics, selectSavedRows, lookupConcepts, searchConcepts, inspect and idempotent close methods. Data responses are serializable lists with pinned context, explicit state/reason, opaque cursor, complete flag and bounded read counters.}
\details{
The experimental native R interface uses installed integrity-checked definitions.
Physical filenames, page descriptors, index keys and SQL are absent from method requests.
The caller must supply independent institutional admission and authority; a ready flag
or an artifact hash alone cannot establish approval.

\code{listMetrics(limit = 25L, cursor = NULL, maxBytes = 1048576L, cancel = function() FALSE)}
returns up to 100 approved catalogue entries with structural filter capabilities.

\code{selectSavedRows(metricId, filters = list(), rowKind = NULL, population = NULL,
maxRows = 100L, maxBytes = 1048576L, cursor = NULL, cancel = function() FALSE)}
returns exact saved rows and relevant verified denominator/summary-eligibility dependencies.
Filters are up to 16 named exact strings or typed tag lists. Default rowKind is summary
when saved by the metric, otherwise the first declared kind. Summary units/operators
remain separate strata. Limits are 1,000 primary rows and 8 MiB for the complete response,
including dependencies, context, cursor and counters. Row and metric pages stop
at the byte boundary with a continuation cursor. A single unit with its required
response envelope/evidence/continuation that cannot fit raises resource_limit. All catalogue, selected-row and dependency
reads share the operation's bounded read budget. No count, mean or percentile is recomputed.

State available preserves individual row states and exact string values. Missing selections
are not_saved, independently of saved zero or empty_source/empty_population rows.
Whole-output suppression and unsupported states return no rows. Unsupported populations,
grains or joint filters return additional_batch_job_required with generation_requested FALSE.
Sparse scans exceeding a read budget fail with resource_limit rather than claiming absence.

Cursors bind operation/selection, limits, complete pinned context, instance, epoch and reader
generation. Reuse them with the same method arguments. They are not permissions and do not
follow current. Cancellation is cooperative; errors invalidate cursors and clear raw caches.
The synchronous JDBC query timeout remains 60 seconds; immediate statement interruption,
browser integration, available concept-name search and production-scale qualification are separate.
\code{lookupConcepts(conceptIds, limit = 25L, cursor = NULL, maxBytes = 1048576L,
cancel = function() FALSE)} accepts 1--100 unique canonical signed integer strings,
with at most 512 digits per ID. Zero and large/negative IDs retain their exact values.
Returns up to 100 saved catalogue entries or individual not_saved states, in signed
numeric order, with count/byte pagination. Request order is normalized; no numeric
coercion or vocabulary fallback is used. Current v2 labels remain NULL/unavailable.

\code{searchConcepts(query, limit = 25L, cursor = NULL, maxBytes = 1048576L,
cancel = function() FALSE)} validates a nonblank UTF-8 query of at most 256 bytes,
without control characters. On contract 2.0.0 it reads only the pinned root and
returns unavailable, reason terminology.name_index_not_saved, searched FALSE and
no concepts/cursor. This is not a completed empty search. Query bytes are retained;
no name matching or normalization is performed. A non-NULL cursor is invalid.
Terminology label-source and vocabulary-release identities are explicitly unavailable
in this terminology contract, independently of the dataset source_id in context.
These methods share authority, cancellation, read/response budgets and lifecycle rules.

Close the provider when finished. Already returned approved bytes cannot be recalled by closing.
}
