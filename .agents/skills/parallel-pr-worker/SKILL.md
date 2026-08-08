---
name: parallel-pr-worker
description: Implement repository changes in an isolated Codex worktree, create a unique codex/* branch, validate the change, commit and push it, and open or update a GitHub pull request. Use for feature work, bug fixes, refactors, tests, documentation changes tied to code, and review-feedback fixes. Do not use for read-only analysis, explicitly uncommitted experiments, or PR coordinator work.
---

# Parallel PR Worker

## Objective

Complete one coherent user task in the current isolated checkout and leave it
as a reviewable GitHub pull request. Do not merge it, poll it, or create a
scheduled follow-up.

## Preflight

1. Confirm the current directory is inside the intended Git repository.
2. Read the root `AGENTS.md` and any more-specific applicable instructions.
3. Run `git status --short --branch` and `git worktree list`.
4. Determine the default branch from `origin/HEAD`, falling back to the
   documented repository convention.
5. Confirm the connected GitHub app can access the repository. If the app is
   unavailable and publication is required, use `gh --version` and
   `gh auth status` as the fallback.
6. Run `git fetch --prune origin` when network access is available.

If the checkout is the default branch, do not edit it. Report that the task
must be started or handed off into Codex **Worktree** mode. A detached HEAD in
a Codex-created worktree is valid.

If the current branch starts with `codex/`, keep it. Otherwise create a unique
branch from the current HEAD before the first edit. Use
`codex/<short-task-slug>-<unique-suffix>` and verify the resulting branch.

## Establish scope and implement

- Translate the request into concrete acceptance criteria.
- Inspect only relevant code, tests, configuration, and documentation.
- Preserve unrelated changes and existing architectural boundaries.
- Proceed on a safe conventional interpretation when possible and disclose the
  assumption. Ask only when a missing decision materially changes behavior or
  safety.
- Make the smallest coherent change and match existing naming, error handling,
  logging, and test conventions.
- Add or update tests when there is a practical seam.
- Avoid unrelated formatting, broad rewrites, dependency upgrades, and
  speculative cleanup.
- Do not modify another worktree or weaken safeguards to make validation pass.

## Validate and review

Run validation in increasing scope: focused coverage, the relevant component
suite, then repository-wide checks when practical. Prefer the commands in
`AGENTS.md`. Record each material command and distinguish pre-existing failures
from failures introduced by the branch.

Compare the branch against its intended base. Check the diff and status for
accidental files, secrets, generated output, debug code, commented-out
experiments, and unrelated edits.

## Commit, push, and open the pull request

Create cohesive commits with imperative messages. Push with upstream tracking,
normally `git push -u origin HEAD`. Never overwrite an unexpectedly existing or
diverged remote branch.

Use the connected GitHub app to find an existing pull request for the branch or
open a new non-draft pull request targeting the intended base. Fall back to
`gh pr` only when the app is unavailable. Use this body structure:

```markdown
## Summary

- What changed
- What behavior is now different

## Rationale

Why this approach was selected and any important design constraint.

## Validation

- `exact command` — passed/failed/skipped

## Risks and notes

- Compatibility, migration, rollout, known limitation, or `None identified`
```

Do not immediately post `@codex review`; the initial ready pull request should
receive automatic review, and the coordinator owns deduplicated review requests.

When addressing review feedback, load the current PR, review summary, inline
comments, discussion, and checks. Evaluate findings, fix legitimate issues with
minimal scope, rerun validation, commit, push, and let the coordinator request
re-review. Do not poll after publication.

## Final report

Report the branch, latest commit SHA, pull-request number and URL, concise
summary, validation outcomes, and any skipped check, risk, conflict, CI failure,
or unresolved review item. Never claim a merge unless GitHub confirms it.
