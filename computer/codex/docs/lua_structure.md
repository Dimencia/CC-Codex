# CC Codex live source and integration guide

Read this before inspecting or changing Lua. It describes the running CC
program and its integration boundaries. It is not the system prompt and is
not sent to the provider automatically.

All paths below are relative to the ComputerCraft computer root - the
directory containing `codex.lua` and `codex/`.

The repository path for these deployed docs is `computer/codex/docs/`; the
installer copies it to `codex/docs/`. Root-repository `docs/` files are
host-side unless their relevant content is copied here. This guide is the
concise runtime-facing copy.

## Source ownership

The repository's `computer/codex/` directory is the application source tree.
The installer copies it to the installed computer, where:

- `startup/cc_codex.lua` assumes multishell, starts `codex/service.lua` as a
  background process, keeps the ordinary CraftOS shell in the main tab, and
  leaves the `codex` terminal client as a manual command.
- `codex.lua` is the manual terminal client launcher; it opens
  `codex/clients/terminal.lua`.
- `codex/clients/` contains user-facing clients. A future monitor client can
  live beside the terminal client without becoming part of the service.
- `codex/service.lua` is the service supervisor. It loads the API key from CC settings, starts
  the managed application, and repeats it when `.codex-restart` exists.
- `codex/core/` contains provider-independent conversation and scheduling
  policy, text/component conversion, and usage metrics.
- `codex/platform/cc/` contains the ComputerCraft composition root and its
  environment adapters.
- `codex/providers/` contains provider-specific HTTP integrations.
- `codex/storage/` and `codex/tools/` contain persistence and model-visible
  capabilities.
- `codex/formatters/` contains the optional reloadable Chat Box formatter.
- `codex/image/` contains image decoding, monitor rendering, and the
  standalone `img2mon.lua` command.
- `codex/docs/lua_structure.md` is this guide.
- `codex/docs/system_prompt.md` is the provider instruction document. Keep it
  separate from implementation docs and do not edit it as part of source work.
- `codex/docs/deferred-ideas.md` is the requested-work backlog. It is valid
  implementation context when the user explicitly asks for an idea.
- `codex/setup/set_api_key.lua` stores `cc_codex.api_key` in local CC settings.

The installer normally downloads the latest release's uncompressed USTAR
package, validates it, and creates ordinary files in the computer root. Use
`install --archive-url URL` for an exact release or CI package. If no compatible
release package is available, it falls back to the GitHub source tree. The
installed `codex/` directory and `codex.lua` are not symlinks or junctions.
Updating the repository therefore requires copying the changed source tree
again; Git history, branches, and commits remain host-side responsibilities.

Do not delete the deployed source directories during ordinary source edits.
Edit the repository files under `computer/`, then use the installer or an
explicit source-copy workflow to update the computer.

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
- `codex/tools/` contains fixed model-visible tools: `execute_cc_lua`,
  `write_preferences`, conversation listing/naming, compaction/restart,
  `render_image_on_monitor`, `create_worker`, and optional
  `execute_remote_lua` Rednet execution.
- `codex/platform/cc/remote_bootstrap.lua` is a standalone worker program. The
  `create_worker` tool copies it to `startup/` and writes the per-target
  authority file at the disk root on an attached writable data disk.
- `codex/platform/cc/adapters/` contains terminal, client-mailbox, Chat Box,
  and image-rendering adapters. Clients use those adapters to submit and receive
  turns from the one service-owned conversation engine.

Keep policy in portable modules and CC effects at the supervisor, bootstrap,
and adapter boundaries. Add a module only for a distinct lifecycle, reusable
policy, or effect boundary. Prefer a smaller method or deleted branch to a new
service.

Every implementation change includes a simplification and documentation audit.
Check whether the change makes a branch, setting, helper, file, or duplicated
responsibility obsolete. Keep cleanup within the same behavioral boundary so
the patch remains easy to verify and merge. Re-read the documentation for every
changed behavior, path, command, setting, test, safety boundary, install, or
deployment step. Update this deployed guide or the roadmap when the CC agent
needs the information; do not copy host-only process detail into runtime docs.

## Local runtime files

These are per-computer state, not shared source:

- `codex/data/preferences.md` - mutable local preferences.
- `codex/data/codex-state.json` - provider cursor and restart continuation.
- `codex/data/remote_workers.json` - local parent capabilities for workers
  created by this computer. It is not provider input and must not be committed.
- `codex/data/conversations.json` and `codex/data/conversations/` - conversation catalog
  and plaintext diagnostic JSONL logs.
- `codex/data/usage.jsonl` - aggregate turn metrics.
- `codex/data/client-requests/<request-id>.json` and
  `codex/data/client-results/<request-id>.json` - request-scoped client mailbox
  files. A terminal acknowledges each result by deleting it after reading. The
  service retains at most 32 unread scoped result files and never evicts an
  unread file: when capacity is full, a new request ID's result is rejected
  until an existing client acknowledges its result. Replacing the same
  request ID remains allowed for progress and final delivery. This bounds
  abandoned files while applying backpressure when clients do not acknowledge.
  The service reads the older singular `client-request.json` and writes
  `client-result.json` during rollout so an older terminal client can finish.
- `codex/artifacts/images/` - generated image files.
- `codex/.codex-restart` - transient supervisor marker used for a validated
  managed restart.
- `.settings` - CC settings, including the API key.

Do not put credentials or runtime data into source. Do not treat local logs or
client request/result files as provider history. Runtime files stay local when
source is copied to another computer.

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
with `loadfile(path)`. Do not use `fs.delete` on deployed source directories
as part of an ordinary source edit.

After changing loaded Lua, call the model-visible `restart_codex` tool. It
validates `codex/service.lua` and the application source trees before saving the
continuation and requesting the restart; the supervisor then reloads the
validated source. If source validation or checkpointing fails, the old process
continues and the tool reports the failure. Do not claim a restart happened
without the tool result.

## Integration directions

There are three separate paths. Do not confuse them:

1. **Host repository -> CC runtime.** The host agent edits `computer/`. The
   installer copies those ordinary files to the computer; loaded Lua still
   needs a CC Codex restart.
2. **CC runtime -> host repository.** Files edited through CC are local to the
   installed computer. Copy the intended changes back to the repository before
   committing; the CC agent does not own Git branching, commits, or merges.
3. **CC -> another CC computer.** `create_worker` prepares a disk; after the
   target is restarted with that disk attached, `execute_remote_lua` sends an
   authenticated request over a wireless modem using a unique
   `rednet_worker:<timestamp>-<counter>` protocol. The target worker accepts
   only its configured parent capability and never starts a local shell. This
   feature does not synchronize source, conversation state, or agent identity.

The CC agent cannot directly invoke the host agent's Git logic. Use the shared
source files for code handoff and explicit host-side review before committing.

## In-game test runner

The shared Lua test suite can be run on this computer after an in-game source
edit:

```text
lua codex/tests/run.lua
```

It covers portable policy, composition, CC-facing service/setup boundaries, and
image decoding/rendering with fake boundaries. It does not contact a model or
change the world. The same suite is also expected to run offline on the host;
the repository-root testing guide documents the native host interpreter and
the host-only LuaLS check. Those host tools are not part of the deployed CC
runtime.

## Requested future work

When the user asks for a deferred idea, read `codex/docs/deferred-ideas.md` and
then inspect the current source and tests before choosing an implementation
slice. The ideas are allowed work, not instructions to implement themselves.
Preserve the current source, provider, CC, and adapter boundaries while doing
so.

## Safety and authority boundaries

`execute_cc_lua` can execute arbitrary Lua with the normal CC authority of the
computer. Rednet execution can affect the selected remote computer. The Codex
computer is the authority root: it listens for no worker protocol, so workers
cannot call it back. A worker may be controlled only by its configured parent
capability and can be used by that parent to prepare descendants.

Rednet is not a cryptographic or player-authentication boundary. A player who
can edit a worker disk/computer, spoof the server's computer identity, or gain
server-level ComputerCraft access can bypass this scheme. Multiplayer worlds
still need protected computer blocks, controlled disk access, and server-side
permissions for a hard player boundary. Inspect current state before changing
files or the world. Keep world changes, external model calls, and remote
execution separate from ordinary offline source inspection.

Do not copy one root capability to every descendant. Child propagation must use
new per-edge capabilities and an explicit parent hop; this slice does not
silently copy itself to every disk.

When a task depends on current implementation, inspect this guide first and
then read only the relevant module. Keep reads bounded and verify every write
and restart from actual tool output.
