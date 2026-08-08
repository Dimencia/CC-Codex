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

- For every task that changes tracked files, use the repository-local
  `parallel-pr-worker` skill unless the user explicitly asks for read-only
  analysis, an uncommitted experiment, or coordinator work.
- A task explicitly designated as the PR coordinator must use the
  `pr-coordinator` skill and must not implement feature work.
- Start write-capable tasks in **Worktree** mode from the intended base branch,
  normally `master`.
- Never make feature changes directly on `master`. A detached HEAD in a new
  Codex worktree is expected; create a unique
  `codex/<task-slug>-<unique-suffix>` branch before committing.
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
and notable risks or limitations. Workers do not merge their own pull requests,
poll for review status, or create recurring tasks. The dedicated coordinator
owns explicit `@codex review` requests, `@codex fix` delegation, and merging.

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
