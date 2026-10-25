# Repository instructions

Product: AchillesNext. Repository: achilles-next. R package: AchillesNext.

## Repository boundary

- Track package source, tests, build configuration and package-facing documentation only.
- Keep planning, decision logs, delivery records, research and confidential integration material outside this Git checkout.
- Never copy private material or links to private local files into tracked content.
- Local guidance may be configured in `.git/info/local-guidance`; it is not a package dependency or tracked content.
- Do not claim functionality, supported engines or validation that has not been implemented and verified.
- Preserve numerical semantics, explicit missing/suppressed states and applicable source attribution.

## User-controlled Git operations

- Prepare changes for user review. Do not commit, amend, push or merge without explicit user approval after review.
- Authorized commits must use the user's configured Git author and committer identity. Do not substitute an agent/bot identity, override authorship or add AI co-author trailers.
- Only the user may initiate pull requests. Never create a PR through a CLI, API, tool or browser. Local draft text is permitted when requested.
- Use `feature/{ticket-id}-{branch-name}` for feature branches.
- Use `fix/{ticket-id}-{branch-name}` for fixes.
- Use an existing ticket ID and a descriptive lowercase, hyphen-separated branch name. Do not invent tickets or commit directly on main.
- Follow CONTRIBUTING.md and leave prepared work uncommitted until the user approves it.
