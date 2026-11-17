# Repository instructions

Product: AchillesNext. Repository: achilles-next. R package: AchillesNext.

## Repository boundary

- Track package source, tests, build configuration and package-facing documentation only.
- Keep planning, decision logs, delivery records, research and confidential integration material outside this Git checkout.
- Never copy private material or links to private local files into tracked content.
- Local guidance may be configured in `.git/info/local-guidance`; it is not a package dependency or tracked content.
- Do not claim functionality, supported engines or validation that has not been implemented and verified.
- Preserve numerical semantics, explicit missing/suppressed states and applicable source attribution.

## Autonomous development and review

- The user grants standing authorization to develop planned tasks, commit/amend/push with their account, create PRs, address review and CI findings, and merge when the review gate passes. Continue to the next planned task without requesting routine approval. A later explicit instruction to leave work uncommitted or pause overrides this authorization.
- Prepare reviewable changes and run relevant checks before committing. Keep each PR focused and omit private delivery/planning material from commits and hosted discussions.
- Use the user's configured Git author and committer identity and authenticated GitHub account. Verify both before publishing. Do not substitute an agent/bot identity, override authorship or add AI co-author trailers.
- Use `feature/{ticket-id}-{branch-name}` or `fix/{ticket-id}-{branch-name}` with an existing ticket ID and a descriptive lowercase, hyphen-separated suffix. Do not invent tickets or commit implementation directly on main.
- Follow the [review and CI gate](CONTRIBUTING.md#commits-and-pull-requests): integrate the latest remote base and PR branch first; verify the resulting exact head, the `cubic · AI code reviewer` check, all required CI and every active review finding. Fix valid findings, explain rejected findings, and resolve addressed threads. Repeat after each push.
- Recheck both remote base and head before merging. If either changed after verification, integrate and repeat the gate. Bind the merge to the verified head commit; never force-push, bypass checks or substitute an earlier commit's results.
- While waiting for review or CI, prepare independent work in isolated branches/worktrees. Preserve tested source identities, keep native fixture drivers from overlapping, and merge dependencies before publishing dependent changes.
- Pause only for missing information, conflicting intent, or destructive/irreversible work outside the authorized scope. Continue independent work while clarification is pending. Never invent dataset access, validation results or accepted product gates.
