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
- A QA worker independently validates current PR heads and adds focused
  regression coverage without taking over the feature branch.
- A benchmark worker establishes reproducible performance and cost baselines,
  then proposes measured optimizations. Read-only measurement does not claim a
  roadmap item; benchmark harness or product changes still require an explicit
  assignment and the normal claim workflow.
- Feature workers update behavior documentation affected by their patch, but
  they do not reorder the roadmap or claim a second item opportunistically.

## Agent identity

Every agent identity keeps one stable, human-readable callsign across tasks and
branches. Puck may suggest an unused name for a genuinely new worker; existing
workers retain their established identities. Prefix the task title with the
name, prefix internal and GitHub messages with `[<callsign>]`, and add
`Agent: <callsign> (<role>)` to roadmap claims, PR bodies, reviews, fix or
escalation comments, merge notes, and handoffs. Keep the branch, PR number,
work-item ID, and head SHA where relevant: the name helps humans distinguish
workers but is not an authorization or lock. Never use a callsign as a temporary
task or PR label, reuse it for another agent, or rename a worker during handoff.
Do not alter required branch names to include the callsign.

## Event-driven task resumption

An idle or completed Codex task is resumable. When new owner action becomes
concrete, send a follow-up to the existing named task instead of creating a
replacement worker or requiring every worker to poll forever. A bounded task
should finish its assignment, leave an exact handoff, and stop cleanly; the
roadmap steward or coordinator resumes it when a review finding, merge, base
change, or next assignment actually exists.

Routine GitHub snapshots are not coordination deliverables. Report only an
actionable finding, ownership or handoff change, failed gate, unsafe collision,
decision needed, or completed milestone. Waiting tasks do not announce that
they are still waiting or that nothing changed. If the current environment
cannot resume an existing task, record that limitation explicitly and use one
bounded user-approved follow-up mechanism rather than a busy loop.

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
- the user process in plain language, including what success and failure look
  like to the player and model;
- exact behavior changed;
- files and contracts affected;
- tests and checks run, with results;
- local Docker/CC fixture result and exact-head `Runtime Integration` result;
- genuinely external boundaries not tested, separate from routine integration;
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
either resumes the original named task with a concrete follow-up or explicitly
assigns a replacement to the same branch. No other worker edits that branch
without this handoff, and no one starts a duplicate implementation.

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

Normalize findings by user-visible risk, affected contract/path, and root cause.
Keep one owner-action item for each distinct cause; later reviewers may mark it
independently confirmed or add new evidence, but should not open another item
for the same behavior. Describe the player/model consequence before internal
mechanics so the owner can distinguish a real blocker from compatibility polish.

For a merge-only base refresh, compare the old and new heads first. Reuse the
existing feature review when the implementation blobs and relevant contract are
unchanged; review only the incoming base delta and interaction risks. Required
CI and Runtime Integration still run on the exact new head. Repeat a full review
only when the feature behavior, its dependencies, or the prior finding's cause
changed.

Opening a pull request authorizes this review pass, not merging, deploying,
restarting ComputerCraft, making a live model request, or changing the other
worker's branch. Follow the repository's normal GitHub approval rules for
submitting comments or approval.

## PR coordination and release

The PR coordinator triages current evidence, requests review or fixes once per
head, escalates stalled fixes to the owner, and merges only a fully ready PR.
The feature worker updates its branch, resolves conflicts deliberately, and
reruns the required gates. A PR is not merge-ready without a successful
`Runtime Integration` check on its exact current head. Changes that can affect
shipped CC behavior should also carry a local real-server Docker fixture result
when Docker is available. This fixture is routine validation; deployment or
restart of a persistent ComputerCraft target, live model requests, and
real-player/world interaction remain separate explicitly authorized actions.
Merge one architectural boundary at a time.

After merge, the PR coordinator may delete the remote branch and remove its
worktree. Workers never delete a branch merely because it looks stale. A stale
claim is a roadmap decision: the roadmap steward inspects activity and handoff
state, then asks the user or PR coordinator to release the branch when
necessary.

## Protected roadmap publication

Roadmap-only queue and agent-instruction updates bypass feature review, but
they do not bypass the protected `test` check. Use a
`codex/roadmap-<unique-suffix>` branch, record its exact commit, and push it.
That push triggers the required CI check:

The current `Main protection` ruleset requires the GitHub Actions check-run
context `test`, which is the `test` job in the `CI` workflow. Pull requests also
produce the `integration` job from `Runtime Integration`; the coordinator treats
that exact-head check as a merge gate by project policy. Do not infer either
context from a workflow title alone, and do not rename or alias jobs to work
around a missing check. If protection should require `integration` too, change
the ruleset explicitly as a repository-policy operation, then revalidate the
exact current head.

```powershell
$roadmapBranch = (git branch --show-current).Trim()
$validatedSha = (git rev-parse HEAD).Trim()
git push -u origin $roadmapBranch
gh run list --repo Dimencia/CC-Codex --workflow CI --branch $roadmapBranch --event push --json databaseId,headSha,status,conclusion --limit 10
```

Select the run whose `headSha` exactly equals `$validatedSha`, then require it
to finish successfully:

```powershell
gh run watch <RUN_ID> --repo Dimencia/CC-Codex --exit-status
```

Before publishing, verify that neither the branch nor `master` invalidated the
result. If `HEAD` changed, or if `origin/master` is no longer an ancestor of the
validated commit, update and push the documentation branch, then validate the
new push-event run for its new SHA.

```powershell
if ((git rev-parse HEAD).Trim() -ne $validatedSha) { throw "Roadmap HEAD changed after validation" }
git fetch origin master
git merge-base --is-ancestor origin/master $validatedSha
if ($LASTEXITCODE -ne 0) { throw "Roadmap branch must be refreshed and revalidated" }
git push origin "${validatedSha}:refs/heads/master"
```

Never substitute a newer unvalidated commit, force-push `master`, open a
roadmap PR, or use this path for product code, tests, CI, installer, or runtime
changes. `workflow_dispatch` remains available for diagnostics, but its manual
run did not satisfy this repository's protected direct-push rule and is not a
roadmap publication gate.

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
8. Resume only the named tasks that now have concrete work; let bounded tasks
   stop instead of keeping them alive with status polling.
