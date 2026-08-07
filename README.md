# CC Codex

CC Codex is a Lua agent interface for CC:Tweaked. It accepts player input from
the ComputerCraft terminal and Minecraft chat, lets the model use explicitly
registered tools, and can render generated images on a monitor.

The replacement exists only under [`refactored/`](refactored/). The live CC
computer remains untouched; it must not be edited, migrated, or replaced until
the isolated implementation passes its remaining gates and deployment is
explicitly approved.

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
contains no usable secret; after deployment root `codex.lua` reads the API key
from CC-local settings.

The editable system prompt and mutable preferences are separate files. The full
pair is sent on first use and after compaction; a later preferences change sends
only the replacement preferences. The obsolete `codex_monitor.lua` launcher is
not part of the replacement.

The deployed `data/lua_structure.md` is a compact implementation map for the
model. It can read that guide, then inspect source modules with
`execute_cc_lua` when a request depends on the Lua layout. `deploy.ps1` requires
and verifies the guide alongside the rest of `refactored/live`.

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

## Deployment helper and API key

`deploy.ps1` copies `refactored/live` into a CC computer directory. Its exact
base directory is:

`C:\Users\Dimen\curseforge\minecraft\Instances\All the Mons - ATMons (1)\saves\CC Test\computercraft\computer`

Computer `3` is the default target:

```powershell
.\deploy.ps1 -DryRun
.\deploy.ps1
```

Use `-ComputerNumber` to select another computer, and combine it with `-DryRun`
to inspect that target without writing:

```powershell
.\deploy.ps1 -ComputerNumber 0 -DryRun
.\deploy.ps1 -ComputerNumber 0
```

The copy is non-destructive: it updates staged paths but does not mirror or
delete target-only files. In particular, the target's `/.settings`,
`data/preferences.md`, and `data/codex-state.json` remain in place. A real copy
verifies every written file against its staged SHA-256 hash and saves an
immutable pre-deployment source snapshot under `.codex/deployments/` for a
later return merge.

## Returning computer edits

`merge-from-computer.ps1` is the controlled reverse path. With no `-Apply` it
only reads the repository, computer, and deployment baseline and prints a
classification; `-ReportPath` can save the same report as JSON. When a baseline
exists, unchanged-side edits are taken automatically and overlapping text edits
are reported as conflicts. Runtime data, logs, artifacts, settings, and mailbox
files are excluded.

```powershell
.\merge-from-computer.ps1
.\merge-from-computer.ps1 -ReportPath .codex\computer-3-merge.json
.\merge-from-computer.ps1 -Apply
```

`-Apply` is the separate final write action. It refuses to write when the
deployment baseline is missing or any conflict remains, and backs up replaced
repository files under `.codex/merge-backups/`. Computer 3's current session
predates baseline recording, so its preview is intentionally advisory and must
not be applied until an immutable pre-edit base is supplied with `-BaseRoot` or
a future deployment records one automatically.

## Git-backed computer workflow

Once computer 3 is idle, initialize it once and record its current source tree
on a work branch. The initializer ignores CC credentials and runtime data:

```powershell
.\git-computer.ps1 -Action Status
.\git-computer.ps1 -Action Initialize
```

After the repository's desired code is committed to a local branch, Git-backed
deployment is a fast-forward only operation:

```powershell
.\deploy.ps1 -GitBranch master -DryRun
.\deploy.ps1 -GitBranch master
```

To bring the computer branch into this repository later, fetch it without
changing the working tree, create a new task branch, and merge the computer
branch into that new branch:

```powershell
.\git-computer.ps1 -Action FetchToRepository
git switch -c codex/<task-slug>
git merge computer-3/codex/computer-3-work
```

The fetch helper does not merge or overwrite files. Do not merge computer 3
directly into `master`; resolve any conflicts on the new task branch first.

When a task is complete, commit that task branch, preview and perform the Git
handoff, then restart Codex through the host bridge:

```powershell
.\deploy.ps1 -GitBranch codex/<task-slug> -DryRun
.\deploy.ps1 -GitBranch codex/<task-slug>
.\cc-command.ps1 -Restart -ComputerNumber 3 -TimeoutSeconds 60 -WhatIf
.\cc-command.ps1 -Restart -ComputerNumber 3 -TimeoutSeconds 60
```

Both non-dry-run commands require explicit approval because they mutate the
live computer. Computer 3 must be idle and clean before the handoff.

After an approved copy, run `set_api_key` on the CC computer and enter the key
there. It stores `cc_codex.api_key` in CC's local settings; root `codex.lua` owns
loading that value at startup. `set_api_key.lua` is only the thin interactive CC
entrypoint. No Windows environment variable participates in credential loading.
CC settings are plaintext, so the computer directory and world/save backup are
inside the credential trust boundary and must not be shared as harmless data.

## Administrative command mailbox

`cc-command.ps1` is the host-side client for one outstanding administrative
request. It uses the same computer base directory as `deploy.ps1`, defaults to
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

Running `deploy.ps1` without `-DryRun`, changing a live CC tree, and making a live
model request remain separate explicit actions. Publishing a command without
`-WhatIf` is also a live-tree mutation and requires its own explicit approval.
This documentation does not authorize any of them.

Live model calls, edits to the live CC tree, data migration, and deployment
remain out of scope without later explicit approval.

## Authoritative documents

- [`REFACTOR_PLAN.md`](REFACTOR_PLAN.md) defines the remaining work and gates.
- [`ARCHITECTURE_CONTRACTS.md`](ARCHITECTURE_CONTRACTS.md) fixes ownership and
  every intended public method name.
- [`DEFERRED_IDEAS.md`](DEFERRED_IDEAS.md) records possible later capabilities;
  it is not current implementation scope.
