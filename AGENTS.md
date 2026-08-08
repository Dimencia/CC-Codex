# CC Codex agent workflow

The repository is the source of truth. The installer copies ordinary files and
directories from `computer/` into a ComputerCraft computer:

- `computer/startup/cc_codex.lua` assumes multishell and starts the service in a
  separate tab, leaving the main tab as the ordinary CraftOS shell.
- `computer/codex.lua` is the manual terminal-client launcher.
- `computer/codex/` contains the service, clients, core, platform adapters,
  providers, storage, tools, image code, docs, and tests.
- `codex/data/`, `codex/artifacts/`, `.settings`, and client request/result files
  stay local to the computer and are not repository source.

The CC-facing documentation under `computer/codex/docs/` is also implementation
context for the agent running inside the computer. On the installed computer
this same directory is `codex/docs/`. Read `codex/docs/lua_structure.md` before
inspecting or changing individual modules. It includes the source map,
self-edit/restart workflow, and CC/remote integration boundaries.
The service is started by `startup/cc_codex.lua` when the CC runtime launches.
The root `docs/` directory is host-side documentation and navigation. The
CC-facing `computer/codex/docs/deferred-ideas.md` is also valid implementation
context: the CC agent may implement one of those ideas when the user asks it
to. If a host-side design or workflow changes behavior visible to the CC agent,
put the concise relevant part in `computer/codex/docs/` as well.
`computer/codex/docs/system_prompt.md` is a separate provider instruction
document; do not change its behavioral instructions unless explicitly asked.

When changing Lua that is already loaded, restart the CC Codex process on the
target ComputerCraft computer. This means the program running in CC, not the
Codex desktop application or this agent session.

The portable native Lua 5.2.4 interpreter is stored at
`.tools/lua52/lua52.exe`. Do not rely on a bare `lua` PATH lookup or substitute
another runner when this interpreter is present.

## Required change hygiene

Simplicity is a product requirement. Before handing back every source, test, or
runtime-composition change:

- inspect the diff for obsolete code, duplicate responsibilities, unnecessary
  configuration, and avoidable files introduced or exposed by the change;
- prefer deleting or shortening existing code to adding an abstraction; add a
  module only for a distinct lifecycle, reusable policy, or effect boundary;
- keep cleanup local to the requested change so parallel branches remain easy
  to review and merge;
- audit all documentation that describes the changed behavior, path, command,
  setting, test, safety boundary, installation, or deployment step;
- update the concise CC-facing documentation as well when the running CC agent
  needs the changed information; and
- report which documentation was checked and which live boundaries were not
  validated.

Always run the native offline Lua suite from the repository root after changing
Lua source, tests, or runtime composition. This is a required validation gate
before handing work back:

```powershell
& ".\.tools\lua52\lua52.exe" -v
& ".\.tools\lua52\lua52.exe" computer\codex\tests\run.lua
```

The same suite can also run on the ComputerCraft computer after an in-game
source edit:

```text
lua codex/tests/run.lua
```

Run the host-only LuaLS check from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File host/checks/check-lua.ps1
```

Live model requests, Minecraft interaction, and remote execution are separate
actions. Do not invoke them while doing offline source work unless the user
explicitly asks for that live action.

API keys belong in ComputerCraft settings and must not be committed. The
repository ignores local runtime state; do not put secrets in source, test
fixtures, or runtime request files.

## Parallel pull-request workflow

This repository may be modified by several Codex tasks at the same time.
Write-capable tasks are isolated in Git worktrees and shipped through GitHub
pull requests.

The roadmap steward owns roadmap priorities, work-item definitions, and stale
claim decisions. The PR coordinator is a separate role that owns deduplicated
`@codex review` and `@codex fix` requests, escalation, and final merges. The
feature worker owns its claimed item, branch, and pull request until merge or
an explicit handoff; publishing a PR does not end that ownership.

Every long-running agent task chooses one stable callsign, prefixes its task
title and internal or GitHub messages with that name, and includes
`Agent: <callsign> (<role>)` in roadmap claims, PR bodies, reviews, fix comments,
merge notes, reports, and handoffs. Names make concurrent agents distinguishable
but never replace work-item IDs, branches, PR numbers, or head SHAs. Keep the
required `codex/*` branch format unchanged.

- For every task that changes tracked files, use the repository-local
  `parallel-pr-worker` skill unless the user explicitly asks for read-only
  analysis, an uncommitted experiment, or coordinator work.
- A task explicitly designated as the PR coordinator must use the
  `pr-coordinator` skill and must not implement feature work.
- Start write-capable tasks in **Worktree** mode from the intended base branch,
  normally the latest `origin/master` after `git fetch --prune origin`.
- Never make feature changes directly on `master`. A detached HEAD in a new
  Codex worktree is expected. For a roadmap item, acquire the Ready-to-Active
  claim on `master` before creating `codex/cc-NNN-short-slug`; for other work,
  create a unique `codex/<task-slug>-<unique-suffix>` branch before committing.
- Work only in the current checkout. Never edit, reset, clean, remove, or
  repurpose another worktree, and never discard changes you did not create.
- Do not use destructive Git operations or force-push unless the user
  explicitly authorizes the exact operation.
- Workers do not merge into `master` or delete worktrees or branches owned by
  other tasks.

Keep each change coherent and minimal. Preserve public APIs, serialized
formats, configuration keys, command-line behavior, and network protocols
unless the request explicitly requires a breaking change. Do not add a
production dependency when the current stack can reasonably solve the problem.

Before publishing, review the complete diff against the intended base and
check for accidental files, secrets, generated output, debug code, or unrelated
edits. Use the repository validation commands above and record any skipped or
failed checks accurately.

Worker branches use the `codex/` prefix and are pushed to `origin`. Completed
worker changes are submitted as GitHub pull requests unless the user explicitly
says not to publish them. Pull requests target `master` unless the user chooses
another base, and their descriptions include a summary, rationale, validation,
and notable risks or limitations. On every later turn for that task, the worker
checks its open pull request before starting new work and addresses actionable
review findings, branch-caused CI failures, and conflicts. It must not claim a
new roadmap item while its existing PR still needs owner action. After
publishing, the worker lists every
other open pull request and directly reviews each current head that lacks an
adequate independent review. This peer review does not transfer the other
item's claim. Workers do not merge their own pull requests or issue automated
`@codex review`/`@codex fix` requests; the PR coordinator owns those requests
and merging.

The coordinator may try one GitHub Codex fix delegation for a head commit, but
that delegation does not transfer ownership or prove that a fix happened. If it
finishes or fails without a new commit, the coordinator marks the PR as needing
owner action and reports it to the roadmap steward or user. The roadmap steward
records the blocked state in Active and either wakes the original worker or
explicitly reassigns the same branch; it does not create duplicate feature work.

On Windows, Codex shell commands may run as a sandbox account such as
`codexsandboxonline` while `USERPROFILE` still points at the interactive user's
profile. That sandbox identity cannot decrypt the user's Windows Credential
Manager entries, so `gh auth status` can incorrectly report an invalid token
even when GitHub CLI works for the user. Compare `whoami` before diagnosing an
authentication failure. Prefer the connected GitHub app, or run only the
required authenticated `git`/`gh` command outside the sandbox with a narrowly
scoped approval. Do not copy a token into the sandbox, use `GH_TOKEN` or
`--insecure-storage` as a workaround, print a token, or switch to SSH merely to
bypass this identity boundary.

During review, flag unintended compatibility breaks, blocking waits in
asynchronous paths, unowned background work, lost exceptions, unsafe shared
state, missing server-side authorization, untrusted path or command handling,
injection risks, secret exposure, and consequential behavior changes without a
practical regression test.

### Atomic roadmap claims

For roadmap work, a remote feature branch is not the lock: different slugs can
create multiple branches for one ID. A worker may select only an ID listed in
the Ready queue in `computer/codex/docs/deferred-ideas.md`.

Before any feature edit, create a fresh roadmap-only branch from the latest
fetched `origin/master`, move the ID from Ready to Active with the intended
feature branch name, commit only that roadmap file, and push the commit directly
to `master` without force. Move only the queue entry; never remove or relocate
the detailed task specification, which QA and reviewers still need. The first
fast-forward push owns the item. If the
push is rejected, fetch the winning `master`, do not retry the same claim, and
choose another Ready ID. Create the feature branch from the updated
`origin/master` only after the claim is visible there.

The roadmap steward uses the same documentation-only direct-to-`master` path
for reprioritization, completion, abandonment, stale-claim cleanup, and the
repository agent instructions needed to operate that queue safely. Feature pull
requests do not edit the queue. This exception never permits direct product
source, tests, CI workflows, installer behavior, or runtime changes on
`master`.
