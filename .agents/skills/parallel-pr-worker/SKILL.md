---
name: parallel-pr-worker
description: Implement repository changes in an isolated Codex worktree, create a unique codex/* branch, validate the change, commit and push it, and open or update a GitHub pull request. Use for feature work, bug fixes, refactors, tests, documentation changes tied to code, and review-feedback fixes. Do not use for read-only analysis, explicitly uncommitted experiments, or PR coordinator work.
---

# Parallel PR Worker

## Objective

Complete one coherent user task in the current isolated checkout, leave it as a
reviewable GitHub pull request, and review unreviewed peer pull-request heads.
Own that branch and pull request until merge or explicit handoff. Do not merge
it, busy-poll it, or create a scheduled follow-up.

## Preflight

1. Confirm the current directory is inside the intended Git repository.
2. Read the root `AGENTS.md` and any more-specific applicable instructions.
3. Confirm the agent's persistent callsign; choose an unused name only for a
   genuinely new worker. Keep it across tasks and branches, prefix the task
   title and messages with it, and use `Agent: <callsign> (<role>)` in authored
   GitHub artifacts. Never use it as a temporary PR label or rename another
   worker during handoff.
4. Run `git status --short --branch` and `git worktree list`.
5. Determine the default branch from `origin/HEAD`, falling back to the
   documented repository convention.
6. Confirm the connected GitHub app can access the repository. If the app is
   unavailable and publication is required, use `gh --version` and
   `gh auth status` as the fallback.
7. Run `git fetch --prune origin` when network access is available, then use
   the refreshed `origin/master` as the normal task base instead of trusting a
   possibly stale local `master`.
8. For roadmap work, stop if the canonical queue declares Stabilization mode.
   Otherwise select only an ID in Ready. Before
   feature edits, create a fresh roadmap-only branch from `origin/master`, move
   that ID to Active with the intended feature branch, commit only the roadmap
   file, and run `git push origin HEAD:master` without force. Move only the
   queue entry; keep the detailed task specification in place for QA and review.
   Do not push the roadmap branch as a pull request. A rejected push lost the
   claim race: fetch and choose another Ready ID instead of retrying the same
   claim. If repository protection rejects all direct roadmap pushes, stop
   without feature edits and report that the claim could not be acquired.
9. Look for an existing open pull request owned by this task. If it has
   actionable review feedback, a branch-caused CI failure, or a conflict,
   resolve that before claiming or starting another roadmap item.

On Windows, compare `whoami` with the interactive user's identity before
diagnosing failed CLI authentication. A Codex sandbox account cannot decrypt
another user's Windows Credential Manager entry even when `USERPROFILE` points
at that user's files. If `gh` works for the user but fails in the sandbox,
prefer the GitHub app and run only the necessary authenticated `git` or `gh`
command outside the sandbox with a narrow approval. Do not repeatedly ask the
user to log in, expose the token through `GH_TOKEN`, use
`gh auth login --insecure-storage`, print the token, or switch to SSH as a
credential workaround.

If the checkout is the default branch, do not edit it. Report that the task
must be started or handed off into Codex **Worktree** mode. A detached HEAD in
a Codex-created worktree is valid.

After a roadmap claim is visible on `origin/master`, create its feature branch
from that commit. For non-roadmap work, if the current branch starts with
`codex/`, keep it; otherwise create `codex/<short-task-slug>-<unique-suffix>`
from the intended base before the first edit and verify the resulting branch.

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

Every PR must have a successful `Runtime Integration` check on its exact
current head before merge. For changes that can affect shipped ComputerCraft
behavior, run `& .\tests\runtime\run.ps1` locally when Docker is available;
do not substitute the native Lua suite for the real headless Minecraft fixture.
If the branch changes after either result, rerun the affected gate. Report the
Docker/CC result as routine integration evidence. Reserve "not exercised" for
external boundaries such as a live model, persistent deployed computer,
real-player/world interaction, or remote target.

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
Agent: <callsign> (<role>)

## Summary

- What changed
- What behavior is now different

## Rationale

Why this approach was selected and any important design constraint.

## Validation

- `exact command` — passed/failed/skipped

## Runtime integration

- Local Docker/CC fixture — passed/failed/skipped with reason
- Exact-head `Runtime Integration` check — passed/pending/failed

## External boundaries not exercised

- Live model, persistent deployment/restart, real-player/world interaction, or
  remote target; do not list the Docker/CC fixture here

## Risks and notes

- Compatibility, migration, rollout, known limitation, or `None identified`
```

Do not immediately post `@codex review`; the initial ready pull request should
receive automatic review, and the coordinator owns deduplicated review requests.

After opening or updating the pull request, list every other open pull request.
Review each current head that lacks an adequate independent review, prioritizing
overlapping or blocking changes and then the oldest unreviewed head. Inspect its
contract, diff, tests, documentation, simplification, and untested live
boundaries. Submit actionable file/line findings or an approval directly; do
not post `@codex review`, edit the other branch, or treat review as a claim.
Prefix the review body with `[<callsign>]` and include the Agent identity line.

When addressing review feedback, load the current PR, review summary, inline
comments, discussion, and checks. Evaluate findings, fix legitimate issues with
minimal scope, rerun validation, commit, push, and let the coordinator request
re-review. A worker resumed on an owned PR performs this follow-up before any
new feature work. Do not busy-poll after publication; wait for a coordinator,
user, or review notification to resume the task.

## Final report

Report the branch, latest commit SHA, pull-request number and URL, concise
summary, validation outcomes, peer-review pass, and any skipped check, risk,
conflict, CI failure, or unresolved review item. Never claim a merge unless
GitHub confirms it.
