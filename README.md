# CC Codex

CC Codex is a Lua agent interface for CC:Tweaked. It accepts player input from
the ComputerCraft terminal and Minecraft chat, lets the model use explicitly
registered tools, and can render generated images on a monitor.

The shared ComputerCraft source lives under [`computer/`](computer/). Computer
3 links its two root entrypoints to that directory and junctions its `lib/`
directory to the repository. Runtime data, artifacts, and settings remain
local to each computer.

## Active refactor

The target is intentionally small:

- portable Lua owns conversation, queue, response, tool, and state policy;
- the root supervisor and bootstrap own CC globals and concrete adapters;
- terminal, Minecraft chat, and monitor rendering remain separate adapters;
- final provider output is model-authored Minecraft component JSON;
- Chat Box preserves its rich styles and actions, while terminal extracts the
  component tree's `text` fields for a textual display and shows the raw payload
  if flattening fails;
- files and methods stay small by simplifying behavior, not by adding layers;
- comments explain reasons and invariants, and public contracts have LuaLS types.

Offline tests and LuaLS verify the staged implementation with fake boundaries;
they are not evidence of a live CC, Chat Box peripheral, or model run. The latest
verification result should be reported with the current change rather than kept
as a soon-stale count here.

Responses keeps model-visible conversation history server-side. Staging retains
only the latest response cursor and, during restart, the next provider input
checkpoint; it never reconstructs or resends a reasoning-item chain. A separate
plaintext diagnostic transcript is written locally as described below. Staging
contains no usable secret; root `codex.lua` reads the API key from CC-local
settings.

The editable system prompt and mutable preferences are separate files. The full
pair is sent on first use and after compaction; a later preferences change sends
only the replacement preferences. The obsolete `codex_monitor.lua` launcher is
not part of the replacement.

The shared `computer/lib/docs/lua_structure.md` is a compact implementation map
for the model. It can read that guide, then inspect source modules with
`execute_cc_lua` when a request depends on the Lua layout.

The model authors one rich Minecraft text component for each assistant final. The
Chat Box adds the outer `<Codex>` label and sends components within the installed
1,024-character cap without imposing terminal limitations on them. Oversized
components are flattened into sequential visible-text chunks to avoid a peripheral
`Message is too long` rejection; rich actions and styling cannot survive that
fallback. A Chat Box rejection receives bounded provider correction attempts
(three by default) before plain-message fallback. Commentary
and tool-status messages remain concise plain text and never start that correction
flow. Terminal conversation I/O and Chat Box both default on. Terminal flattening
failure displays the raw payload locally and never triggers provider correction;
the monitor remains a separate image renderer.

Responses requests retry only bounded transient failures. The client retries a
connection/no-response failure, HTTP 408 or 409, eligible 429, and 5xx at most
twice, with at most 60 seconds of scheduled retry delay. It honors
`Retry-After`/`retry-after-ms`, otherwise uses capped exponential backoff with a
small jitter, and reuses the same encoded request. Other 4xx responses and known
billing, quota, credit, and spend-limit 429 codes fail immediately.

## Local commands and conversation diagnostics

Host commands use a leading bang only: `!exit`, `!clear`, `!model`, `!verbose`,
`!usage`, `!compact`, and `!conversation`. The bang prefix is reserved even for
an unknown command; slash-prefixed text is ordinary conversation input.
Conversation commands include `!conversation list`, `new [name]`,
`rename <name>`, and `switch <name or id>`. Commands are handled by the
application and are never sent as initial provider input or steering. For
example, `!model luna max fast` selects `gpt-5.6-luna`, max reasoning, and fast
service for later requests in the current process.

`!verbose on` shows each tool's full raw input and encoded output as bounded plain
progress chunks on every active reply route; `!verbose off` restores name-only
tool progress. This setting defaults off, is runtime-only, and can expose secrets
or sensitive world data to terminal and Minecraft chat recipients.

Every server-side conversation also has one local JSONL diagnostic stream under
`data/conversations`. It records lifecycle, player/terminal input, steering,
assistant commentary and finals, errors, per-turn metrics, and full tool input
and output. Restart resumes the ID stored in `data/codex-state.json`; compaction
does not change it. `!clear` marks the old stream cleared, starts a new stream,
and saves the new ID before another model turn. Retention keeps the current and
two newest older `conversation-*.jsonl` files and preserves unrelated files.
`data/usage.jsonl` remains the aggregate turn-metrics log; there is no separate
global tool log.

`data/conversations.json` stores conversation names, active selection, and the
latest provider cursor needed to switch between conversations. The model can
query names and title the active conversation through bounded local tools. Topic
changes are suggested with clickable `suggest_command` links; creating or
switching still requires player approval.

Conversation logs are sensitive plaintext with no redaction. Treat them like CC
settings and mailbox data: do not share the computer directory or save backup as
harmless diagnostics.

## Shared source and local runtime

Install or repair the source links for any exact ComputerCraft computer path with:

```powershell
.\install.ps1 -TargetPath 'C:\Minecraft\saves\My World\computercraft\computer\3'
.\install.ps1 -TargetPath 'C:\Minecraft\saves\My World\computercraft\computer\3' -WhatIf
```

The installer creates only `startup.lua`, `codex.lua`, and `lib`. It preserves
local runtime data, artifacts, and settings. Use `-Force` only when replacing
existing source entries; conflicting entries are backed up next to the target.

Computer 3 is wired directly to the repository at:

`C:\Users\Dimen\curseforge\minecraft\Instances\All the Mons - ATMons (1)\saves\CC Test\computercraft\computer\3`

Its `startup.lua` and `codex.lua` are file symlinks to `computer/`, while its
`lib/` directory is a junction to `computer/lib`. Editing either side edits the
same source. Restart Codex after changing Lua that was already loaded.

Only source is shared. Each computer keeps its own `data/`, `artifacts/`, and
`.settings`; these contain conversation logs, runtime state, generated images,
the administrative mailbox, and the plaintext `cc_codex.api_key` setting.
Run `lib/set_api_key.lua` from inside CC to configure that local setting.

## Administrative command mailbox

`cc-command.ps1` is the host-side client for one outstanding administrative
request. It targets a selected ComputerCraft computer directory, defaults to
computer `3`, and accepts exactly one of `-Code` or `-Restart`:

```powershell
.\cc-command.ps1 -Code 'return peripheral.getNames()' -WhatIf
.\cc-command.ps1 -Code 'return peripheral.getNames()'
.\cc-command.ps1 -Restart -ComputerNumber 0 -TimeoutSeconds 60 -WhatIf
.\cc-command.ps1 -Restart -ComputerNumber 0 -TimeoutSeconds 60
```

`-ComputerNumber` defaults to `3`, `-TimeoutSeconds` defaults to `30`, and
`-WhatIf` describes the target/action without publishing a request. Without
`-WhatIf`, the sender atomically publishes `data/host-command-request.json` and
waits for the correlated `data/host-command-result.json`. Restart requests that
receive `error_code = "busy"` are retried until the timeout.

The CC adapter reads, closes, and deletes each request before execution, so
consumption is at-most-once. It atomically publishes results through
`data/host-command-result.json.tmp`. A crash after request deletion can therefore
end in a host timeout, but it does not repeat arbitrary Lua. The noncritical
adapter polls every fixed 0.25 seconds; that interval is not configurable.

The request actions are deliberately small: `{id, action="lua", code}` uses the
same Lua execution, output capture, returned-value handling, and truncation rules
as `execute_cc_lua`; `{id, action="restart"}` requests an idle restart. Restart is
accepted only when no conversation turn is active and the turn queue is empty.

This is an unauthenticated administrative channel. Anyone who can write the CC
computer/save directory can execute arbitrary Lua with normal CC authority or
restart Codex. Requests, results, and Lua source are plaintext. Never send API
keys or other secrets through the mailbox.

Publishing a command without `-WhatIf` is a live-tree mutation and requires
explicit approval. Live model calls and Minecraft interaction remain separate
from source editing.

## Authoritative documents

- [`REFACTOR_PLAN.md`](REFACTOR_PLAN.md) defines the remaining work and gates.
- [`ARCHITECTURE_CONTRACTS.md`](ARCHITECTURE_CONTRACTS.md) fixes ownership and
  every intended public method name.
- [`DEFERRED_IDEAS.md`](DEFERRED_IDEAS.md) records possible later capabilities;
  it is not current implementation scope.
