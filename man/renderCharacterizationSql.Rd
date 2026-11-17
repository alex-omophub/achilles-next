\name{renderCharacterizationSql}
\alias{renderCharacterizationSql}
\title{Compile the complete core PostgreSQL characterization program offline}
\usage{
renderCharacterizationSql(cdmSchema, sourceId, declaredCdmVersion,
  sourceColumns, numericStrategy = "weighted",
  dialect = "postgresql", stagePrefix = "achillesnext_render")
}
\arguments{
\item{cdmSchema}{Lowercase source schema identifier.}
\item{sourceId}{Source identifier of at most 256 UTF-8 bytes.}
\item{declaredCdmVersion}{Declared CDM version: 5.3, 5.4 or 5.5.}
\item{sourceColumns}{Data frame with character \code{table}, \code{column},
\code{type} (PostgreSQL \code{typname}, such as int4, numeric, date or varchar)
and logical \code{readable} columns. At most 4096 unique table/column pairs.
Only referenced core probes affect compilation. This is a declaration, not an
observed-schema receipt. Include optional fields and aliases that actually exist.}
\item{numericStrategy}{Exact weighted (default) or reference measurement summaries.}
\item{dialect}{Currently only postgresql is implemented.}
\item{stagePrefix}{Session-private identifier starting with achillesnext_, at most
32 characters; choose a fresh prefix/session when executing multiple programs.}
}
\description{Compiles SQL for all 142 frozen core outputs without connecting,
loading Java, executing queries, creating results or publishing. Shares the
existing population, domain and measurement SQL builders with the producers.}
\details{The ordered steps include session settings, assertions and temporary
materializations. Assertions must return the declared scalar before continuing.
Use one repeatable-read transaction and SELECT-only source privileges. The emitted
materialized-CTE syntax requires PostgreSQL 12 or newer; native fixtures target17.11.
Compilation
does not enforce execution time, engine temporary bytes or aggregate-transfer
budgets; the separate \code{executeCharacterizationSql()} executor supplies these controls.

Numerical output queries return restricted intermediate metric ID, row kind,
dimensions, exact values, state and reason. Dataset state/coverage comes from
inventory_sql (also parameterized by runtime_facts for the metadata row counts).
These are not approved wire pages: exact normalization, row identity, denominators,
validation, disclosure and publication remain separate responsibilities.

Four metadata queries each have one positional JSONB parameter (\code{?}), named
runtime_facts: actual observed schema hash, capabilities, generation start/end
and timing observations. Compilation leaves these unfilled. The source declaration
assertion must be checked before source work, and runtime observations must be
validated and bound by the caller. Unknown release identities and pending output
validation remain explicit; no static input is labelled as a measured result.
The program is a compile artifact, not a self-contained SQL publication script. Its separate executor emits restricted
intermediates and does not persist, validate or publish them. Other engines and large-source qualification remain open.}
\value{A deterministic program with a version/hash, declared source/profile,
ordered steps, assertions, complete inventory SQL, 142 output query descriptors
and runtime metadata parameter requirements. Its execution state is not_executed
and publication is unchanged.}
\seealso{\code{planCharacterizationBatch}, \code{executeCharacterizationSql},
\code{generateCharacterizationCandidate}}
