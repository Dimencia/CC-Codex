# Parallel agent workflow

This workflow lets multiple autonomous workers operate without sharing a
checkout or claiming the same roadmap item. The canonical priorities and stable
IDs are in
[`computer/codex/docs/deferred-ideas.md`](../computer/codex/docs/deferred-ideas.md).

## Roles

- The roadmap steward owns priorities and work-item definitions, splits work,
  and periodically reviews status and stale claims.
- The PR coordinator requests automated reviews and fixes and merges completed
  branches. This is a separate role from the roadmap steward.
- A feature worker claims one ready work-item ID and owns one branch and one
  worktree until handoff.
- Feature workers update behavior documentation affected by their patch, but
  they do not reorder the roadmap or claim a second item opportunistically.

## Branch claim is the lock

Use the exact branch pattern `codex/cc-NNN-short-slug`. The remote branch is the
shared claim. A worker must reserve it before editing source.

1. Run `git fetch --prune origin`, read the roadmap, and inspect local and
   remote `codex/cc-*` branches.
2. Create a dedicated worktree and the exact item branch from the current
   integration base, normally the refreshed `origin/master` rather than a
   possibly stale local `master`.
3. Before source edits, make a unique empty commit named `Claim CC-NNN` and push
   the branch without force.
4. Start work only if that push creates the remote branch. If it is rejected or
   the remote branch already exists, another worker owns the item. Do not pull
   their branch and continue; choose an unclaimed item.

The unique claim commit matters. Two workers pushing an unchanged base could
both appear successful because they would push the same commit. Unique commits
make concurrent claims diverge, so Git accepts one branch creation and rejects
the other as a non-fast-forward update. Never force-push a claim branch.

Workers on the same host also benefit from Git's rule that one branch cannot be
checked out in two worktrees, but the remote reservation is still required for
workers in other clones or machines.

## GitHub authentication boundary

On managed Windows agent runs, the sandbox may not be able to read credentials
stored for the user's ordinary Windows session. A sandboxed `gh auth status` or
Git command can therefore report an invalid or missing token even when the user
is already authenticated outside the sandbox.

Before asking the user to authenticate again, request approved elevated
execution for the smallest specific `gh` or Git command and retry it with access
to the normal credential store. Never use `gh auth token`, display a credential,
copy it into an environment variable manually, or write it into the workspace,
logs, source, or chat. A connected GitHub app and local `gh`/Git credentials are
separate access paths; success in one does not prove or repair the other.

## Ownership and overlap

- One work-item ID has one owner. Subtasks that need parallel implementation
  receive new IDs and explicit file/boundary ownership from the roadmap steward.
- Prefer read-heavy parallel audits. Avoid simultaneous architecture changes in
  `core/chat_engine.lua`, `platform/cc/bootstrap.lua`, shared test runners, the
  installer, or this roadmap unless the roadmap steward has split the boundaries.
- Do not edit another worker's branch or ComputerCraft-local source copy.
- If an unexpected dependency or overlapping file appears, stop that slice and
  report it to the roadmap steward. Do not silently merge the other in-progress
  branch.

## Worker handoff

Each handoff states:

- work-item ID and branch;
- exact behavior changed;
- files and contracts affected;
- tests and checks run, with results;
- live boundaries not tested;
- documentation audited or updated;
- simplification performed, or why no safe simplification was available;
- remaining risks and follow-up IDs.

Keep commits reviewable. A draft pull request can expose progress when the user
has authorized one, but branch creation is the claim and a pull request is not
required to begin local work.

## Peer review rotation

After a worker opens its own pull request, it must list all other open pull
requests and review each one that has not been reviewed at its current head
commit. Review overlapping or blocking changes first, then the oldest
unreviewed heads. If a previously reviewed pull request has new commits, review
the new head rather than assuming the earlier verdict still applies.

Do not self-review. A review is read-only work and does not claim the other
item: inspect its stated contract, diff, tests, simplification, documentation,
and untested live boundaries without editing its branch. Report prioritized,
actionable findings with file/line evidence. Skip a current head that already
has an adequate independent review instead of posting duplicate feedback.

Opening a pull request authorizes this review pass, not merging, deploying,
restarting ComputerCraft, making a live model request, or changing the other
worker's branch. Follow the repository's normal GitHub approval rules for
submitting comments or approval.

## PR coordination and release

The PR coordinator reviews the diff and evidence, updates the branch from the
current integration base, resolves conflicts deliberately, and reruns the
required gates. Merge one architectural boundary at a time. Deployment,
ComputerCraft restart, live model requests, and Minecraft interaction remain
separate explicitly authorized actions.

After merge, the PR coordinator may delete the remote branch and remove its
worktree. Workers never delete a branch merely because it looks stale. A stale
claim is a roadmap decision: the roadmap steward inspects activity and handoff
state, then asks the user or PR coordinator to release the branch when
necessary.

## Periodic roadmap pass

On each check-in:

1. Fetch/prune and list `codex/cc-*` claims.
2. Compare branch activity and review state with the roadmap.
3. Verify completed work from commits, diffs, tests, and live evidence rather
   than worker summaries alone.
4. Split or block items whose prerequisites changed.
5. Re-rank the ready queue and keep the number of active architecture changes
   small.
6. Update the canonical roadmap through the roadmap steward's branch only.
