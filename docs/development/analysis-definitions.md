# Executable analysis definitions

The installed `analysis/core-analysis-definitions-v1.json` registry supplies typed
denominator rules for the core characterization profile. It is separate from the
frozen mathematical descriptions in `core-characterization-v2.json`: explanatory
text is not parsed to decide joins, denominator references or output dependencies.
The existing profile, row schemas and saved-result formats retain their versions
and identities.

Every metric has an explicit population and either no denominator or a reference
to a registered rule and target metric. Rules declare:

- The applicable row kind and optional full-scope period condition.
- Source-to-target dimension copies and constant target dimensions.
- Numerator and denominator measure names.
- Exact dimension matching, or the existing subset matching for qualification
  targets whose full-scope date bounds may differ between saved scopes.
- Default date dimensions used to identify generated full-recorded-scope targets.

For example, an observed capture count links its person measure to observation
coverage with the same period kind, start and end. A core capture count links to
the entire PERSON population only for its full-scope row. Record and person
qualification measures link separately to their concept's full-scope capture.
Histogram person counts also retain their all-person denominator.

Loading validates inventory, populations, target metrics, row kinds, dimensions,
measure fields and acyclic dependencies. Unsupported conditions and rule fields
fail explicitly. The definition file has an independent SHA-256 lock, references
the frozen profile hash and participates in batch/run planning identity. Updating
executable definitions invalidates old execution plans; saved results continue to
use their declared frozen profile and row contracts.

The core registry is installed package data. A separate
[registered contribution example](registered-analyses.md) demonstrates a bounded
PERSON-count extension. Neither registry provides remote schema/code loading,
measurement generation or a new engine adapter. Changes to the registry require package code review and compatibility
checks, rather than editing installed files.

After installing the package from the checkout, run the focused offline checks:

```sh
Rscript --vanilla tests/tracer/analysis-definitions.R
Rscript --vanilla tests/tracer/domain-review-offline.R
Rscript --vanilla tests/tracer/batch-plan.R
```

The fixtures independently specify target scopes and exact large counts. They
also replace explanatory prose in an in-memory fixture and prove the generated
joins, reference validation and policy dependency closure remain identical.
