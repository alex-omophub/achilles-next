# Repository instructions

Product: AchillesNext. Repository: achilles-next. R package: AchillesNext.

## Repository boundary

- Track package source, tests, build configuration and package-facing documentation only.
- Keep planning, decision logs, delivery records, research and confidential integration material outside this Git checkout.
- Never copy private material or links to private local files into tracked content.
- Local guidance may be configured in `.git/info/local-guidance`; it is not a package dependency or tracked content.
- Do not claim functionality, supported engines or validation that has not been implemented and verified.
- Preserve numerical semantics, explicit missing/suppressed states and applicable source attribution.

## Git operations and review

- Prepare reviewable changes and run relevant checks. Never commit, amend, push or merge without explicit user approval after review.
- Only the user initiates PRs. Never create one through a CLI, API, tool or browser. Local PR-description drafts may be prepared for review.
- Authorized commits must use the user's configured Git author and committer identity. Do not substitute an agent/bot identity, override authorship or add AI co-author trailers.
- Before an authorized merge, verify the [review and CI gate](CONTRIBUTING.md#commits-and-pull-requests) on the current head: the `cubic · AI code reviewer` check completed successfully, all required CI passed, all active review findings are addressed and the latest remote state is integrated. Never bypass checks or force-push.
- Use `feature/{ticket-id}-{branch-name}` for feature branches.
- Use `fix/{ticket-id}-{branch-name}` for fixes.
- Use an existing ticket ID and a descriptive lowercase, hyphen-separated branch name. Do not invent tickets or commit directly on main.
- Follow CONTRIBUTING.md. Keep each PR focused, describe resulting behavior and validation, and keep private delivery/planning material out of commits and hosted discussions.
