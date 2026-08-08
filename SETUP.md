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

### Windows Codex sandbox identity

Codex commands can run as a sandbox account such as `codexsandboxonline` while
environment paths still point at the interactive user's profile. Windows
Credential Manager encrypts the GitHub CLI token for the interactive identity,
so the sandbox cannot retrieve it. This can make `gh auth status` report an
invalid token even though the same command succeeds in the user's terminal.

Check `whoami` before asking the user to authenticate again. Prefer the
connected GitHub app for repository and pull-request operations. For local Git
pushes or CLI-only operations, run only the required command outside the
sandbox with a narrowly scoped approval. Do not copy the token into the
sandbox, store it through `GH_TOKEN` or `--insecure-storage`, print it, or switch
to SSH merely to work around the identity boundary.

## Native Codex review

Enable **Code review** and **Automatic reviews** in the Codex settings for the
GitHub repository. The initial ready pull request should receive an automatic
review. The coordinator requests a review only when one is missing or when the
head SHA changes after fixes.

## Worker tasks

For each coding task:

1. Create a new Codex task.
2. Select **Worktree** beneath the composer.
3. Fetch/prune `origin`, then select the intended base branch, normally the
   refreshed `origin/master` rather than a possibly stale local `master`.
4. For roadmap work, claim only a Ready ID by atomically moving it to Active on
   `master` as documented in `AGENTS.md`; a rejected push must choose again.
5. Create the feature branch from the winning claim commit and ask for the
   change normally.

`AGENTS.md` directs write tasks to the `parallel-pr-worker` skill. To force it
explicitly, mention:

```text
Use $parallel-pr-worker and implement <task>.
```

The worker creates a unique branch, validates, commits, pushes, and opens or
updates a pull request. Roadmap workers first reserve the stable item branch as
documented in `docs/parallel-workflow.md`. After publishing, the worker reviews
every other open pull-request head that lacks an adequate current independent
review, then stops; it does not poll.

## Coordinator task

Open one dedicated Codex task on the normal local checkout and paste
`COORDINATOR_PROMPT.md` into it. Keep that task for coordination only. Run it on
demand with:

```text
Run one coordination pass.
```

This consumes no idle usage between passes.

## Optional scheduling

Only schedule the single PR coordinator task, never each worker. Use
`SCHEDULED_COORDINATOR_PROMPT.md`, a low-cost model, low reasoning, and an
hourly cadence. End the schedule when the `codex/*` PR queue is empty.

## Recommended GitHub protections

Configure branch protection or repository rules for `master` so direct pushes
are rejected and required CI checks must pass. Keep the PR coordinator as the
only process instructed to merge Codex worker pull requests. The roadmap
steward remains a separate task and owns priorities, not merges.

## Operational notes

- Hidden SHA markers in coordinator comments prevent duplicate review and fix
  jobs.
- A new commit has a new SHA, allowing exactly one new review request.
- The coordinator merges only one pull request per pass so later decisions use
  the updated base.
- Deleting the remote branch after merge is safe. Clean up local branches and
  worktrees later through Codex or normal worktree management.
