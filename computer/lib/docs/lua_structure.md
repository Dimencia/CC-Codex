# CC Codex Lua layout

This is a short implementation map for the model running inside CC:Tweaked.
It describes the live program, not player preferences or higher-priority
system instructions. Read it with `execute_cc_lua` when a task depends on the
implementation.

All paths below are relative to the CC computer root. The live program is
under the directory containing `codex.lua`.

## Entry points

- `codex.lua` is the supervisor and composition entry point. It loads the API
  key from CC settings, builds the application, and restarts a managed child
  when a restart marker is requested.
- `lib/set_api_key.lua` is a one-purpose interactive setup program. It stores the
  API key as the CC setting `cc_codex.api_key`; it is not part of the agent
  runtime.
- `lib/img2mon.lua` is the standalone image-to-monitor command used by the image
  renderer. It is not the main chat loop.

## Source tree

- `lib/codex/cc_bootstrap.lua` is the CC composition root. It connects CC
  globals and peripherals to the portable application modules and registers
  the local tools.
- `lib/codex/app.lua`, `runtime.lua`, `events.lua`, `turn_queue.lua`, and
  `commands.lua` own the event loop, input queue, worker lifecycle, and local
  bang commands.
- `lib/codex/chat_engine.lua` owns one model turn: instruction loading,
  provider requests, tool rounds, compaction, continuation, and reply delivery.
- `lib/codex/session.lua` owns in-memory turn and provider cursor state;
  `turn_metrics.lua` records per-turn measurements.
- `lib/codex/responses/` contains the Responses HTTP client, request builder,
  and response reader. It does not own terminal or peripheral behavior.
- `lib/codex/tools/` contains the model-visible local tools, their schemas, and
  dispatch. `execute_lua.lua` implements `execute_cc_lua`; it can use the
  normal CC APIs available to the running computer.
- `lib/codex/plugins/` contains concrete I/O adapters: terminal, Chat Box,
  and the host command mailbox.
- `lib/codex/storage/` contains JSON/JSONL state, conversation logs and
  catalog, preferences/system-prompt loading, usage records, and image
  artifacts.
- `lib/codex/adapters/` bridges generated image requests to `img2mon.lua`.
- `lib/image/` contains image decoding, palettes, rendering modes, and monitor
  rendering. It is separate from the chat engine.

## Data and runtime files

- `lib/docs/system_prompt.md` is the shared host instruction document sent to
  the provider as a system instruction.
- `lib/docs/lua_structure.md` is this reference map. It is read-only documentation
  and is not automatically sent to the provider.
- `lib/chat_messages.lua` formats local terminal/chat messages.
- `data/preferences.md` is mutable local preference text. The application
  creates it on first run and each computer keeps its own copy.
- `data/codex-state.json` stores restart continuation state. Each computer
  keeps its own copy.
- `data/conversations.json` stores conversation names, selection, and provider
  cursors. `data/conversations/` contains diagnostic JSONL logs.
- `data/usage.jsonl` contains aggregate turn metrics.
- `data/host-command-request.json` and `data/host-command-result.json` are the
  plaintext administrative mailbox files; they are transient and should not
  contain secrets.
- `artifacts/images/` stores generated image files. The application creates
  the directory when needed.
- `.settings` is outside the staged source tree and holds CC settings,
  including the API key. Do not copy it from the host or expose it in output.

## Change and inspection rules

The computer's `startup.lua` and `codex.lua` are file links into the repository,
and its `lib/` directory is a directory junction into the repository. Source
changes are therefore immediately visible; restart Codex after changing loaded
Lua. Runtime state, logs, mailbox files, artifacts, and settings remain local
to each computer. Do not edit or delete source, state, logs, mailbox files, or
settings unless the player explicitly asks for that operation.

For a small inspection, use `execute_cc_lua` with code like:

```lua
local handle, openError = fs.open("lib/docs/lua_structure.md", "r")
if not handle then return openError end
local content = handle.readAll()
handle.close()
return content
```

The same pattern reads a source module such as
`lib/codex/chat_engine.lua`. Keep reads bounded and do not start interactive
programs or long-running loops through the tool.
