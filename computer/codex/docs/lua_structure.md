# CC Codex live source and integration guide

Read this before inspecting or changing Lua. It describes the running CC
program and its integration boundaries. It is not the system prompt and is
not sent to the provider automatically.

All paths below are relative to the ComputerCraft computer root - the
directory containing `codex.lua` and `codex/`.

The repository path for these deployed docs is `computer/codex/docs/`; the live
computer sees it as `codex/docs/`. Root-repository `docs/` files are host-side
unless their relevant content is copied here. This guide is the concise
runtime-facing copy.

## Source ownership

The repository's `computer/codex/` directory is the shared source tree. On the live
computer:

- `startup/cc_codex.lua` starts `codex/service.lua` as the headless service.
- `codex.lua` is the manual terminal client launcher; it opens
  `codex/clients/terminal.lua`.
- `codex/clients/` contains user-facing clients. A future monitor client can
  live beside the terminal client without becoming part of the service.
- `codex/service.lua` is the service supervisor. It loads the API key from CC settings, starts
  the managed application, and repeats it when `.codex-restart` exists.
- `codex/core/` contains provider-independent conversation and scheduling
  policy.
- `codex/platform/cc/` contains the ComputerCraft composition root and its
  environment adapters.
- `codex/providers/` contains provider-specific HTTP integrations.
- `codex/storage/` and `codex/tools/` contain persistence and model-visible
  capabilities.
- `codex/image/` contains image decoding, monitor rendering, and the
  standalone `img2mon.lua` command.
- `codex/docs/lua_structure.md` is this guide.
- `codex/docs/system_prompt.md` is the provider instruction document. Keep it
  separate from implementation docs and do not edit it as part of source work.
- `codex/docs/deferred-ideas.md` is the requested-work backlog. It is valid
  implementation context when the user explicitly asks for an idea.
- `codex/setup/set_api_key.lua` stores `cc_codex.api_key` in local CC settings.

The links are intentional. The current development computer's `startup.lua`
and `codex.lua` point to repository launchers, and its `codex/` points to
`computer/codex`. New installations use the `startup/cc_codex.lua` hook.
Editing a source
file through the live computer therefore edits the repository source too. The
host agent sees that change in its workspace; Git history, branches, commits,
and deployment are still host-side responsibilities.

Do not rename, delete, or replace the linked `codex/` directory or the public
`codex.lua` launcher during ordinary source edits. Preserve the current
development links and junction. Edit the contents of the target source files
instead.

## Lua layout

- `codex/platform/cc/bootstrap.lua` is the CC composition root. It wires CC globals,
  files, HTTP, peripherals, storage, tools, and adapters.
- `codex/core/app.lua`, `runtime.lua`, `events.lua`, and `turn_queue.lua` own
  scheduling, input queues, worker lifecycle, and cooperative task execution.
- `codex/core/commands.lua` handles local bang commands. They do not become
  provider input.
- `codex/core/chat_engine.lua` owns one provider turn: instruction loading,
  retries, tool rounds, steering, compaction, continuation, and delivery.
- `codex/core/session.lua` owns provider cursor, checkpoint, refresh, and active
  turn state. `codex/storage/` owns local state, preferences, diagnostics,
  conversation catalog, usage records, and image artifacts.
- `codex/providers/responses/` contains the HTTP client, request builder, and response
  reader. It does not own CC or presentation behavior.
- `codex/tools/` contains fixed model-visible tools. `execute_lua.lua` is
  `execute_cc_lua`; `maintenance.lua` provides compaction and restart;
  `remote_exec.lua` provides optional Rednet execution.
- `codex/platform/cc/adapters/` contains terminal, client-mailbox, Chat Box,
  host-mailbox, and image-rendering adapters. Clients use those adapters to submit and receive
  turns from the one service-owned conversation engine.

Keep policy in portable modules and CC effects at the supervisor, bootstrap,
and adapter boundaries. Add a module only for a distinct lifecycle, reusable
policy, or effect boundary. Prefer a smaller method or deleted branch to a new
service.

## Local runtime files

These are per-computer state, not shared source:

- `codex/data/preferences.md` - mutable local preferences.
- `codex/data/codex-state.json` - provider cursor and restart continuation.
- `codex/data/conversations.json` and `codex/data/conversations/` - conversation catalog
  and plaintext diagnostic JSONL logs.
- `codex/data/usage.jsonl` - aggregate turn metrics.
- `codex/data/host-command-request.json`, `codex/data/host-command-result.json`,
  `codex/data/client-request.json`, and `codex/data/client-result.json` - transient
  control and client mailbox files.
- `codex/artifacts/images/` - generated image files.
- `.settings` - CC settings, including the API key.

Do not put credentials or runtime data into source. Do not treat local logs or
the mailbox as provider history. Runtime files stay local when source is
copied or linked to another computer.

## Inspecting and editing source from CC

Use the `execute_cc_lua` tool for short, self-contained CC operations. It has
normal CC APIs such as `fs`, `shell`, `peripheral`, `redstone`, `turtle`, and
`commands` when available. Printed output and returned values are captured and
bounded. Avoid interactive input, endless loops, and long-running scripts.

For a bounded read:

```lua
local path = "codex/core/chat_engine.lua"
local handle, openError = fs.open(path, "r")
if not handle then return openError end
local content = handle.readAll()
handle.close()
return content
```

Before editing, read the current file from the live computer. Do not rely on
an earlier turn, a summary, or a claimed previous write. For a substantial
change, keep a copy in local `codex/data/` or another recoverable local location,
write the intended complete file, close it, read it back, and syntax-check it
with `loadfile(path)`. Never use `fs.move` or `fs.delete` on the linked entry
points or on the deployed source directories themselves.

After changing loaded Lua, call the model-visible `restart_codex` tool. It
validates `codex/service.lua` and the deployed Lua source trees, saves the continuation before
requesting the restart, and lets the supervisor reload the source. If source
validation or checkpointing fails, the old process continues and the tool
reports the failure. Do not claim a restart happened without the tool result.

## Integration directions

There are four separate paths. Do not confuse them:

1. **Host repository -> CC runtime.** The host agent edits `computer/codex/`. The
   linked development computer sees those source changes immediately; loaded Lua still
   needs a CC Codex restart.
2. **CC runtime -> host repository.** The CC agent can edit shared source via
   `fs`, and the host agent will see the file change. The CC agent does not own
   Git branching, commits, merges, or deployment. Report the changed paths and
   let the host handle repository history and handoff.
3. **Host -> CC runtime control.** The host-side `host/commands/cc-command.ps1` writes one
   request to `codex/data` and waits for the correlated result. `-Code`
   executes a short Lua chunk; `-Restart` requests an idle restart. Requests
   are plaintext, unauthenticated beyond filesystem access, and must not carry
   secrets. This is administrative control, not a model conversation.
4. **CC -> another CC computer.** `execute_remote_lua` uses a wireless or ender
   modem and Rednet with a unique `codex_execution:<timestamp>-<counter>`
   protocol. It sends only the supplied Lua source and waits for that computer's
   response. The target must have a compatible Rednet listener; this feature
   does not synchronize source, conversation state, or agent identity.

The CC agent cannot directly invoke the host agent's Git or deployment logic.
Use the shared source files for code handoff, the host mailbox for host-initiated
runtime control, and explicit host-side review before committing or deploying.

## Validation

Run the complete fake-boundary suite on the computer:

```text
lua codex/tests/run.lua
```

The suite covers portable policy, composition, CC-facing service/setup
boundaries, and image decoding/rendering without contacting a model or changing
the world. Run the host-side LuaLS check from the repository root with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File host/checks/check-lua.ps1
```

These checks do not replace live CC, peripheral, mailbox, Rednet, HTTP, or
model checks.

## Requested future work

When the user asks for a deferred idea, read `codex/docs/deferred-ideas.md` and
then inspect the current source and tests before choosing an implementation
slice. The ideas are allowed work, not instructions to implement themselves.
Preserve the current source, provider, CC, and adapter boundaries while doing
so.

## Safety and authority boundaries

`execute_cc_lua` and the mailbox can execute arbitrary Lua with the normal CC
authority of the computer. Rednet execution can affect the selected remote
computer. Inspect current state before changing files or the world. Keep world
changes, external model calls, remote execution, and mailbox requests separate
from ordinary offline source inspection.

When a task depends on current implementation, inspect this guide first and
then read only the relevant module. Keep reads bounded and verify every write
and restart from actual tool output.
