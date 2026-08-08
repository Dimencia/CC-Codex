# Parallel PR workflow setup

## Repository files

The workflow is installed at the repository root:

```text
AGENTS.md
.agents/
  skills/
    parallel-pr-worker/
      SKILL.md
    pr-coordinator/
      SKILL.md
      scripts/
        Get-CodexPrQueue.ps1
COORDINATOR_PROMPT.md
SCHEDULED_COORDINATOR_PROMPT.md
```

Codex discovers repository skills under `.agents/skills`.

## GitHub access

The connected GitHub app is the preferred interface for pull-request reads and
writes. Local Git still fetches and pushes branches through `origin`.

The bundled compact queue script is an optional fast path for machines with the
GitHub CLI. To use it, install and authenticate `gh` once:

```powershell
gh auth login
gh auth status
```

The GitHub identity needs permission to push branches, create pull requests,
comment on pull requests, and merge according to repository rules.

## Native Codex review

Enable **Code review** and **Automatic reviews** in the Codex settings for the
GitHub repository. The initial ready pull request should receive an automatic
review. The coordinator requests a review only when one is missing or when the
head SHA changes after fixes.

## Worker tasks

For each coding task:

1. Create a new Codex task.
2. Select **Worktree** beneath the composer.
3. Select the intended base branch, normally `master`.
4. Ask for the change normally.

`AGENTS.md` directs write tasks to the `parallel-pr-worker` skill. To force it
explicitly, mention:

```text
Use $parallel-pr-worker and implement <task>.
```

The worker creates a unique branch, validates, commits, pushes, and opens or
updates a pull request. It then stops; it does not poll.

## Coordinator task

Open one dedicated Codex task on the normal local checkout and paste
`COORDINATOR_PROMPT.md` into it. Keep that task for coordination only. Run it on
demand with:

```text
Run one coordination pass.
```

This consumes no idle usage between passes.

## Optional scheduling

Only schedule the single coordinator task, never each worker. Use
`SCHEDULED_COORDINATOR_PROMPT.md`, a low-cost model, low reasoning, and an
hourly cadence. End the schedule when the `codex/*` PR queue is empty.

## Recommended GitHub protections

Configure branch protection or repository rules for `master` so direct pushes
are rejected and required CI checks must pass. Keep the coordinator as the only
process instructed to merge Codex worker pull requests.

## Operational notes

- Hidden SHA markers in coordinator comments prevent duplicate review and fix
  jobs.
- A new commit has a new SHA, allowing exactly one new review request.
- The coordinator merges only one pull request per pass so later decisions use
  the updated base.
- Deleting the remote branch after merge is safe. Clean up local branches and
  worktrees later through Codex or normal worktree management.
