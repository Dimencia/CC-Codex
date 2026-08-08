# Parallel agent workflow

This workflow lets multiple autonomous workers operate without sharing a
checkout or claiming the same roadmap item. The canonical priorities and stable
IDs are in
[`computer/codex/docs/deferred-ideas.md`](../computer/codex/docs/deferred-ideas.md).

## Roles

- The roadmap steward owns priorities and work-item definitions, splits work,
  and periodically reviews status and stale claims.
- The PR coordinator requests automated reviews and fixes and merges completed
  branches, escalating failed automation to the owner. This is a separate role
  from the roadmap steward.
- A feature worker claims one ready work-item ID and owns its branch, worktree,
  and PR until merge or explicit handoff.
- Feature workers update behavior documentation affected by their patch, but
  they do not reorder the roadmap or claim a second item opportunistically.

## Agent identity

Every long-running task chooses one stable, human-readable callsign. Puck may
suggest it; the task may choose another. Prefix the task title with the name,
prefix internal and GitHub messages with `[<callsign>]`, and add
`Agent: <callsign> (<role>)` to roadmap claims, PR bodies, reviews, fix or
escalation comments, merge notes, and handoffs. Keep the branch, PR number,
work-item ID, and head SHA where relevant: the name helps humans distinguish
workers but is not an authorization or lock. Do not alter required branch names
to include the callsign.

## Ready-to-Active update is the lock

The short Ready and Active entries in the canonical roadmap are the shared work
queue. Detailed task specifications never move or disappear when claimed; QA
and reviewers need those contracts while implementation is active.

1. Run `git fetch --prune origin` and read the latest roadmap from
   `origin/master`.
2. Choose only an ID in Ready. Create a fresh roadmap-only branch from
   `origin/master` and move only that short entry into Active with the intended
   feature branch and owning agent name.
3. Commit only the queue update and push it directly to `master` without force.
   The first fast-forward push wins.
4. If rejected, fetch the winning `master`, do not retry the same item, and
   choose a different Ready ID.
5. Only after the claim is visible on `master`, create the feature branch
   `codex/cc-NNN-short-slug` from the new `origin/master` in its own worktree.

Branch names and worktree branch locks are supporting evidence, not claims:
different workers can choose different slugs for the same ID. Never force-push
a claim or include product code, tests, CI, installer, or runtime changes in the
direct roadmap commit.

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
has authorized one, but the accepted Ready-to-Active update is the claim and a
pull request is not required to begin local work.

## Pull-request follow-up ownership

Publishing does not complete the worker's assignment. On every resumed turn,
the feature worker checks its own open PR before starting anything new. It owns
legitimate review fixes, branch-caused CI failures, and conflicts, and it does
not claim another roadmap item while owner action is pending.

The coordinator may issue one deduplicated GitHub Codex fix request per head
SHA. If that attempt finishes or fails without a new commit, the coordinator
posts one `owner-action` escalation and reports it; it does not keep asking the
same automation. The roadmap steward records the PR as blocked in Active and
either wakes the original worker or explicitly assigns a replacement to the
same branch. No other worker edits that branch without this handoff, and no one
starts a duplicate implementation.

When the PR queue backs up, the roadmap steward sets the canonical queue to
Stabilization mode. Ready priorities stay visible but are temporarily
unclaimable. Feature workers finish owned PRs, QA refreshes current-head review
evidence, and the coordinator triages and merges. The steward clears the mode
only after owner-action blockers are resolved or explicitly reassigned and the
remaining queue is green, reviewed, and mergeable.

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

The PR coordinator triages current evidence, requests review or fixes once per
head, escalates stalled fixes to the owner, and merges only a fully ready PR.
The feature worker updates its branch, resolves conflicts deliberately, and
reruns the required gates. Merge one architectural boundary at a time.
Deployment, ComputerCraft restart, live model requests, and Minecraft
interaction remain separate explicitly authorized actions.

After merge, the PR coordinator may delete the remote branch and remove its
worktree. Workers never delete a branch merely because it looks stale. A stale
claim is a roadmap decision: the roadmap steward inspects activity and handoff
state, then asks the user or PR coordinator to release the branch when
necessary.

## Protected roadmap publication

Roadmap-only queue and agent-instruction updates bypass feature review, but
they do not bypass the protected `test` check. Publish the documentation branch,
dispatch CI for that branch, and record its exact commit:

```powershell
$roadmapBranch = (git branch --show-current).Trim()
$validatedSha = (git rev-parse HEAD).Trim()
git push -u origin $roadmapBranch
gh workflow run ci.yml --repo Dimencia/CC-Codex --ref $roadmapBranch
gh run list --repo Dimencia/CC-Codex --workflow CI --branch $roadmapBranch --event workflow_dispatch --json databaseId,headSha,status,conclusion --limit 10
```

Select the run whose `headSha` exactly equals `$validatedSha`, then require it
to finish successfully:

```powershell
gh run watch <RUN_ID> --repo Dimencia/CC-Codex --exit-status
```

Before publishing, verify that neither the branch nor `master` invalidated the
result. If `HEAD` changed, or if `origin/master` is no longer an ancestor of the
validated commit, update the documentation branch and repeat the dispatch for
its new SHA.

```powershell
if ((git rev-parse HEAD).Trim() -ne $validatedSha) { throw "Roadmap HEAD changed after validation" }
git fetch origin master
git merge-base --is-ancestor origin/master $validatedSha
if ($LASTEXITCODE -ne 0) { throw "Roadmap branch must be refreshed and revalidated" }
git push origin "${validatedSha}:refs/heads/master"
```

Never substitute a newer unvalidated commit, force-push `master`, open a
roadmap PR, or use this path for product code, tests, CI, installer, or runtime
changes.

## Periodic roadmap pass

On each check-in:

1. Fetch/prune and list `codex/cc-*` claims.
2. Compare branch activity and review state with the roadmap.
3. Mark PRs with unresolved owner-action escalations as blocked and wake the
   original worker or explicitly reassign the same branch.
4. Verify completed work from commits, diffs, tests, and live evidence rather
   than worker summaries alone.
5. Split or block items whose prerequisites changed.
6. Re-rank the ready queue and keep the number of active architecture changes
   small.
7. Update the canonical roadmap through the roadmap steward's branch only.
