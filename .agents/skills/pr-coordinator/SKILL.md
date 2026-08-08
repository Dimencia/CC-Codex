---
name: pr-coordinator
description: Perform one low-usage coordination pass over open GitHub pull requests whose head branches start with codex/. Deduplicate Codex review and fix requests per head commit, delegate fixes through GitHub only when needed, and merge at most one fully ready pull request. Use only in a dedicated coordinator task or when explicitly asked to coordinate, triage, manage review state, or merge Codex PRs. Do not use for feature implementation.
---

# PR Coordinator

## Objective

Use GitHub as the source of truth and perform exactly one bounded coordination
pass. Do not poll, sleep, schedule another run, or modify feature code locally.
The coordinator alone owns explicit `@codex review` requests, `@codex fix`
delegations, and merge decisions for `codex/*` pull requests.

## Cost controls

- Use the connected GitHub app for queue and PR operations.
- When `gh` is installed and authenticated, the bundled
  `scripts/Get-CodexPrQueue.ps1` is an optional compact queue fast path.
- Do not scan source or load diffs during the initial queue pass.
- Deep-inspect only a PR with a new failure, conflict, review result, or
  merge-ready state.
- Never repeat a review or fix request for the same head SHA.
- Perform at most one external action per PR per pass.
- Merge at most one PR, then stop so the next pass uses the updated base.

## Durable deduplication markers

Search the PR discussion before posting an action:

- Review: `<!-- codex-coordinator:review:<HEAD_SHA> -->`
- Review fix: `<!-- codex-coordinator:fix-review:<HEAD_SHA> -->`
- CI fix: `<!-- codex-coordinator:fix-ci:<HEAD_SHA> -->`
- Conflict fix: `<!-- codex-coordinator:fix-conflict:<HEAD_SHA> -->`

A marker applies only to its exact head SHA.

## One-pass workflow

Load open PRs whose head branch begins with `codex/`. Initially collect only
number, title, URL, head branch and SHA, base, draft state, updated time,
mergeability, review decision, and aggregate checks. Stop if the queue is empty.

Evaluate each PR in this order:

1. Leave drafts alone unless they need user attention.
2. For a conflict, post one `@codex` conflict-resolution task with its marker;
   if already marked for this SHA, report it blocked.
3. For a branch-caused required-check failure, post one scoped `@codex` CI-fix
   task with its marker. Do not delegate infrastructure, credential, cancelled,
   flaky, or unrelated base failures.
4. Take no action while required checks are pending.
5. If no completed Codex review applies to the latest SHA and no marker exists,
   post `@codex review` with the review marker.
6. For unresolved legitimate P0 or P1 findings, post one scoped `@codex` review
   fix task with its marker.
7. A PR is merge-ready only when it is non-draft, mergeable, required checks
   pass, a completed Codex review applies to the latest SHA with no unresolved
   actionable P0/P1 findings, and no required approval is missing.

Use these exact action templates:

```text
@codex update this pull-request branch from its base branch, resolve the merge conflicts without changing the intended feature scope, run the relevant tests, and push the resolution to this pull request. Do not merge it.

<!-- codex-coordinator:fix-conflict:<HEAD_SHA> -->
```

```text
@codex investigate the failing required checks on this pull request. Fix only failures caused by this branch, keep the change in scope, run the relevant tests, and push the fix to this pull request. Do not merge it.

<!-- codex-coordinator:fix-ci:<HEAD_SHA> -->
```

```text
@codex review

<!-- codex-coordinator:review:<HEAD_SHA> -->
```

```text
@codex evaluate every actionable P0 and P1 finding in the latest Codex review. Fix the legitimate findings with minimal scope, add or update regression tests where appropriate, run relevant validation, and push the fixes to this pull request. Do not merge it.

<!-- codex-coordinator:fix-review:<HEAD_SHA> -->
```

Choose the oldest merge-ready PR unless dependency ordering or risk clearly
favors another. Use the repository merge method, defaulting to squash when none
is documented, and delete the remote branch when permitted. Never delete a
local branch still checked out in a worker worktree.

## Final report

Report only the action taken, merged PR if any, PRs awaiting review/checks/fixes,
blockers, and whether the queue is empty.
