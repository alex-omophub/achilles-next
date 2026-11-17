# Contributing to AchillesNext

Keep changes focused and include the resulting package behavior, relevant validation and limitations in the review description. Source, tests, build configuration and documentation explaining package usage and behavior belong here.

## Branch names

Use one of these formats:

- `feature/{ticket-id}-{branch-name}`
- `fix/{ticket-id}-{branch-name}`

Use the existing ticket identifier and a descriptive lowercase, hyphen-separated suffix. Examples: `feature/123-measurement-summary` and `fix/456-observation-boundary`. Do not invent a ticket or make implementation commits directly on main.

## Commits and pull requests

All commits must use the user's Git account identity. Automated assistance must not substitute an agent/bot author or committer, override authorship, or add AI co-author trailers.

Prepare reviewable changes and run the relevant checks. Committing, amending, pushing or merging requires explicit user approval after review. Only the user initiates pull requests; automated assistance must not create PRs through a CLI, API, tool or browser. Local PR-description drafts may be prepared for review.

Before an authorized merge:

1. Fetch and integrate the latest base and PR-branch state, then record the resulting exact PR head commit. Never force-push.
2. Verify the review and CI gate on that commit. [Cubic](https://www.cubic.dev/) is the installed AI code-review app; its GitHub check is named `cubic · AI code reviewer`. It is separate from this repository's Actions workflow. Confirm that check completed successfully and address every active review thread. The `Synthetic PostgreSQL count tracer` workflow must also succeed, including `integration (compatibility)`, `integration (domain)`, `integration (measurement)` and the final `tracer` job. Verify the commit and results in the PR Checks tab or with `gh pr view <number> --json headRefOid,statusCheckRollup` and `gh pr checks <number>`. A result on an earlier commit does not qualify a newer head.
3. Recheck the remote PR head immediately before merging. If integration, a push or another writer changes it after verification, repeat the integration and review/CI verification for the new commit. Bind the authorized merge to the verified commit, for example with `gh pr merge <number> --match-head-commit <verified-sha>`. A head-mismatch refusal requires fresh verification; never bypass checks.

Pause for necessary clarification, while continuing independent work where possible. Keep each PR focused and omit private delivery/planning material from commits and hosted discussions.

## Validation and documentation

Test observable numerical and interface behavior against independent fixtures where relevant. Preserve populations, denominators, units, precision, provenance and distinct unavailable/suppressed states. Document intentional semantic corrections and applicable compatibility limits.

Use synthetic or approved public fixtures. Keep credentials, patient data and restricted outputs out of Git. Keep private planning, delivery records, decision logs, research and confidential integration material outside the checkout; package builds and tests must not depend on them.

Preserve applicable licenses, copyright and NOTICE material when incorporating third-party code. Do not claim runtime, database or clinical validation that has not occurred.
