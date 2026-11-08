# Internal saved-selection model

The current internal model describes equality selections over the frozen
`core-characterization-v2` report inventory. It is not an exported provider API.
It performs no source/store reads, emits no result rows, accepts no credentials
and submits no generation jobs. Existing v1 viewer contracts, v2 approved pages
and storage versions are unchanged.

`.saved_capabilities()` describes all 142 reports from integrity-checked installed
definitions and row schemas. Each entry carries the metric version, fixed
population, grain, row kinds and their jointly saved dimensions. The selectors
use semantic dimensions; callers do not supply page paths, sort keys or SQL.

## Selection boundaries

| Saved report example | Concept | Population | Time | Unit/operator | Summary |
|---|---|---|---|---|---|
| PERSON count | None | PERSON table | Whole source | None | Count only |
| PERSON gender count | None; gender is its own typed dimension | PERSON table | Whole source; no year filter | None | Count only |
| Core domain capture | Exact raw standard-concept tag | All recorded rows | Exact full scope, calendar month/year or undated bucket | Not a capture-report dimension | Separate record/person counts |
| Observed domain capture | Exact raw standard-concept tag | Recorded observation union | Full scope and calendar month/year; no undated bucket | Not a capture-report dimension | Separate record/person counts |
| Observation coverage / continuous-person count | None | Observed people | Saved bounded full scope and clipped/complete calendar periods; no undated bucket | None | Counts with the saved full-calendar indicator where applicable |
| Observation year/gender/age count | None | Observed people | Saved year, jointly with gender/age | None | Count only |
| Measurement numeric summary | Exact tag | All recorded rows | Full source; no monthly summary | Exact saved unit/operator tags | Saved summary and separate eligibility rows |
| Measurement range-status count | Exact tag | All recorded rows | Full source | Exact saved unit/operator tags | Reason partition only |

This table gives examples. The complete machine-readable matrix is derived from
the installed 142 definitions, rather than a second manually edited report list.
Run the contributor test to optionally save it:

```sh
Rscript --vanilla tests/tracer/saved-selection.R /path/to/capabilities.json
```

`.saved_selection()` checks a metric, optional fixed-population identity and row
kind, and up to 16 exact typed equality selectors. Additional dimensions belonging
to only one row kind require that row kind explicitly; for example,
`eligibility_reason` selects eligibility rows, not summary rows. Large/signed IDs
remain strings. NULL, zero, all and schema absence retain distinct typed tags.

Every supplied period tuple has a kind, start and end. `period_kinds` and
`period_bounds` in the capability entry follow that metric's declared producer
family. All-recorded capture saves an undated bucket; observed capture does not.
Capture uses NULL endpoints for full scope and complete calendar months/years.
Observation coverage/continuous-person reports retain their saved full-scope
bounds and clipped calendar boundaries as well as complete periods. A structurally
valid clipped tuple still needs an exact saved-row match later; it is not an
arbitrary-window computation. A valid custom interval outside the metric's saved
grains requires additional operator work. Invalid dates and incomplete tuples
fail validation. A month or year selector cannot be applied to a report lacking
that dimension. Selecting several saved months does not authorize summing distinct
people, averaging percentiles or pooling units.

Explicit numeric `summary` requests apply the installed summary-specific rules:
supplied units must be positive IDs, and measurement numeric summaries accept
only NULL or zero operators. Eligibility-row requests can still select ineligible
groups. Omitted unit/operator filters remain wildcards, without adding default
selectors to the request or inventing result values. Full row eligibility and
denominator validation remain required at readback.

The internal response has two structural states:

- `selection_shape_supported`: the requested dimensions are jointly saved by
  that report/row kind. Availability still requires an approved catalogue and
  actual saved rows; this does not mean that a result exists, is zero, or is
  authorized for a caller.
- `additional_batch_job_required`: the population, row kind, joint dimensions
  or period grain is not saved by this report. `generation_requested` remains
  false. Any future job is an explicit authorized operator action with its own
  definition, validation and publication; this model does not schedule it.

Requests default to 100 rows and 1 MiB, with hard maxima of 1,000 rows, 8 MiB and
16 KiB of encoded request metadata. The pure model checks request shape; the [native semantic provider](semantic-results.md)
now enforces complete response and shared read budgets separately. Malformed/duplicate selectors,
numeric rather than string IDs, recursive payloads and invalid budgets fail.
The trusted cancellation callback runs before and after construction; cancellation
propagates without returning a plan. The deterministic request hash identifies
only the request shape, never authorization, source immutability, a cursor or
cache permission.

## Provider implementation and remaining work

The [representation comparison](../benchmark/saved-representation.md) retained
canonical v2 pages. [Verified native transports](saved-transports.md) and the
[semantic providers](semantic-results.md) now implement approved catalogue
selection, exact saved-row matching, summary-first output, relevant denominator/
eligibility checks, response/read budgets and context-bound cursors in both modes.
The model itself remains structural and performs no I/O or job submission.

Saved concept lookup and optional name discovery use the approved
[saved terminology extension](saved-concepts.md). Original 2.0.0 retains explicit
unavailable labels; 2.1.0 adds declared prefix matching without CDM/vocabulary
fallbacks. The [synthetic walkthrough](saved-walkthrough.md) exports this complete
filter matrix and demonstrates saved/unsaved filter outcomes. Browser/ATLAS views
and representative-scale qualification remain separate work.

Structural selector/schema ownership uses the installed contract. Numerical
arithmetic, eligibility, denominators and summary semantics stay with the
independent native validators/oracles; no percentile arithmetic or data
reaggregation is introduced here. Contributor checks require neither a database
connection nor an end-user Node installation.
